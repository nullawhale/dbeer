// Package datacomparisonjob owns two read-only capture workers and one R17 result.
package datacomparisonjob

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/comparisonjob"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/resultcompare"
	tc "dbeer/helper/internal/tablecapture"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

type Options struct {
	Root           string
	QuotaBytes     int64
	CaptureTimeout time.Duration
}
type status struct {
	state, phase, code, message string
	descriptors                 *protocol.DataDescriptors
	summary                     *protocol.DataComparisonSummary
}
type job struct {
	id, dir        string
	ctx            context.Context
	cancel         context.CancelFunc
	done           chan struct{}
	state          atomic.Pointer[status]
	mu             sync.Mutex
	result         *resultcompare.Result
	source, target resultcompare.Source
}
type Manager struct {
	mu        sync.Mutex
	jobs      map[string]*job
	root      string
	open      adapter.OpenFunc
	options   Options
	closed    bool
	workers   sync.WaitGroup
	closeDone chan struct{}
}

func New(open adapter.OpenFunc, o Options) (*Manager, error) {
	if open == nil {
		return nil, tc.ErrInvalid
	}
	root, e := os.MkdirTemp(o.Root, "dbeer-data-")
	if e != nil {
		return nil, e
	}
	if o.QuotaBytes <= 0 {
		o.QuotaBytes = tc.QuotaBytes
	}
	if o.QuotaBytes > tc.QuotaBytes {
		o.QuotaBytes = tc.QuotaBytes
	}
	if o.CaptureTimeout <= 0 {
		o.CaptureTimeout = 30 * time.Second
	}
	return &Manager{jobs: map[string]*job{}, root: root, open: open, options: o, closeDone: make(chan struct{})}, nil
}
func (m *Manager) Close() {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		<-m.closeDone
		return
	}
	m.closed = true
	for _, j := range m.jobs {
		j.cancel()
		j.state.Store(&status{state: "closed"})
	}
	m.mu.Unlock()
	m.workers.Wait()
	for _, j := range m.jobs {
		j.cleanup()
	}
	_ = os.RemoveAll(m.root)
	close(m.closeDone)
}
func (j *job) cleanup() {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.result != nil {
		_ = j.result.Close()
		j.result = nil
	}
	if j.source != nil {
		_ = j.source.Close()
		j.source = nil
	}
	if j.target != nil {
		_ = j.target.Close()
		j.target = nil
	}
	_ = os.RemoveAll(j.dir)
}
func response(c protocol.Command, j *job) protocol.Response {
	s := j.state.Load()
	return protocol.Response{Type: c.Type + ".result", RequestID: c.RequestID, DataComparison: &protocol.DataComparisonResponse{JobID: j.id, State: s.state, Phase: s.phase, Code: s.code, Message: s.message, Descriptors: s.descriptors, Summary: s.summary}}
}
func fail(c protocol.Command) protocol.Response {
	return protocol.ErrorResponse(c, "dataComparison", "Table comparison data is unavailable or the request is invalid.")
}
func (m *Manager) Handle(c protocol.Command) protocol.Response {
	r := c.DataComparison
	if r == nil {
		return fail(c)
	}
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return fail(c)
	}
	if c.Type == "data.start" || c.Type == "data.describe" {
		if len(m.jobs) > 0 || r.Source == nil || r.Target == nil || r.Source.Connection.DatabaseEngine() != r.Target.Connection.DatabaseEngine() || (r.Source.Connection.DatabaseEngine() != "postgresql" && r.Source.Connection.DatabaseEngine() != "mysql") {
			m.mu.Unlock()
			return protocol.ErrorResponse(c, "busy", "Close the current data comparison before starting another.")
		}
		var b [16]byte
		if _, e := rand.Read(b[:]); e != nil {
			m.mu.Unlock()
			return fail(c)
		}
		id := hex.EncodeToString(b[:])
		ctx, cancel := context.WithCancel(context.Background())
		j := &job{id: id, dir: filepath.Join(m.root, id), ctx: ctx, cancel: cancel, done: make(chan struct{})}
		if e := os.Mkdir(j.dir, 0700); e != nil {
			cancel()
			m.mu.Unlock()
			return fail(c)
		}
		j.state.Store(&status{state: "pending"})
		m.jobs[id] = j
		m.workers.Add(1)
		out := response(c, j)
		go m.run(j, *r, c.Type == "data.describe")
		m.mu.Unlock()
		return out
	}
	j := m.jobs[r.JobID]
	if j == nil {
		m.mu.Unlock()
		return fail(c)
	}
	if c.Type == "data.close" || c.Type == "data.cancel" {
		j.cancel()
		state := "cancelled"
		if c.Type == "data.close" {
			state = "closed"
		}
		j.state.Store(&status{state: state})
		out := response(c, j)
		m.workers.Add(1)
		go func() {
			defer m.workers.Done()
			<-j.done
			j.cleanup()
			if state == "closed" {
				m.mu.Lock()
				delete(m.jobs, j.id)
				m.mu.Unlock()
			}
		}()
		m.mu.Unlock()
		return out
	}
	m.mu.Unlock()
	if c.Type == "data.status" {
		return response(c, j)
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.state.Load().state != "completed" || j.result == nil {
		return fail(c)
	}
	out := protocol.Response{Type: c.Type + ".result", RequestID: c.RequestID, DataComparison: &protocol.DataComparisonResponse{JobID: j.id, State: "completed"}}
	switch c.Type {
	case "data.page":
		limit, maxBytes := r.Limit, r.MaxBytes
		if limit == 0 {
			limit = 100
		}
		if maxBytes == 0 {
			maxBytes = 262144
		}
		page, e := j.result.Page(j.ctx, r.Offset, limit, maxBytes, r.CellOffset)
		if e != nil {
			return fail(c)
		}
		out.DataComparison.Page = &page
	case "data.value":
		maxBytes := r.MaxBytes
		if maxBytes == 0 {
			maxBytes = 65536
		}
		v, e := j.result.Value(j.ctx, r.ValueRef, r.Offset, maxBytes)
		if e != nil {
			return fail(c)
		}
		out.DataComparison.Value = &v
	default:
		return fail(c)
	}
	return out
}

type captureResult struct {
	descriptor tc.Descriptor
	outcome    tc.Outcome
	writer     *tc.Writer
	side       string
	err        error
}
type captureSink struct {
	writer  *tc.Writer
	limited *atomic.Bool
	cancel  context.CancelFunc
}

func (s captureSink) Row(row []*string) error {
	e := s.writer.Row(row)
	if errors.Is(e, tc.ErrQuota) {
		s.limited.Store(true)
		s.cancel()
	}
	return e
}
func (m *Manager) run(j *job, r protocol.DataComparisonRequest, describe bool) {
	defer m.workers.Done()
	defer close(j.done)
	pending := j.state.Load()
	running := &status{state: "running", phase: "capturing"}
	if pending.state != "pending" || !j.state.CompareAndSwap(pending, running) {
		j.cleanup()
		return
	}
	captureCtx, cancel := context.WithCancel(j.ctx)
	defer cancel()
	budget := &tc.Budget{Limit: m.options.QuotaBytes / 2}
	inputs := filepath.Join(j.dir, "inputs")
	if e := os.Mkdir(inputs, 0700); e != nil {
		j.state.CompareAndSwap(running, &status{state: "failed", code: "storage", message: "Private capture storage could not be created."})
		j.cleanup()
		return
	}
	var limited atomic.Bool
	results := make(chan captureResult, 2)
	for index, side := range []*protocol.DataReadSide{r.Source, r.Target} {
		name := "source"
		if index == 1 {
			name = "target"
		}
		go func(side *protocol.DataReadSide, name string) {
			out := captureResult{side: name}
			out.err = func() error {
				duration := 5 * time.Second
				if side.Connection.SSH != nil {
					duration = 30 * time.Second
				}
				if side.Connection.PasswordCommand != nil {
					duration += 15 * time.Second
				}
				opening, stop := context.WithTimeout(captureCtx, duration)
				session, e := m.open(opening, side.Connection)
				stop()
				if session != nil {
					defer session.Close()
				}
				if e != nil {
					return e
				}
				if e = captureCtx.Err(); e != nil {
					return e
				}
				// Connection/credential preparation has its own budget. Start the
				// bounded metadata/read interval only after that physical open.
				readCtx, stopRead := context.WithTimeout(captureCtx, m.options.CaptureTimeout)
				defer stopRead()
				reader, ok := session.(adapter.TableDataReader)
				if !ok {
					return tc.ErrUnsupported
				}
				readonly, ok := session.(adapter.ReadOnlySession)
				if !ok {
					return tc.ErrUnsupported
				}
				if e = readonly.SetReadOnly(readCtx, true); e != nil {
					return e
				}
				out.descriptor, e = reader.DescribeTable(readCtx, side.Table)
				if e != nil || describe {
					return e
				}
				if out.descriptor.Digest != side.DescriptorDigest {
					return tc.ErrChanged
				}
				spec, columns, e := captureSpec(out.descriptor, *side, r.Columns, r.Originals, name == "source")
				if e != nil {
					return e
				}
				out.writer, e = tc.NewWriter(inputs, columns, out.descriptor.Engine, budget)
				if e != nil {
					return e
				}
				defer out.writer.Close()
				_, out.outcome, e = reader.CaptureTable(readCtx, spec, captureSink{out.writer, &limited, cancel})
				return e
			}()
			results <- out
		}(side, name)
	}
	var source, target captureResult
	var failure *status
	for range 2 {
		result := <-results
		if result.side == "source" {
			source = result
		} else {
			target = result
		}
		if result.err != nil && !(limited.Load() && (errors.Is(result.err, tc.ErrQuota) || errors.Is(result.err, context.Canceled))) {
			cancel()
			if failure == nil {
				code, message := "captureUnavailable", "Table capture failed. Check metadata, SELECT permissions and supported table types."
				if errors.Is(result.err, tc.ErrChanged) {
					code = "descriptorChanged"
					message = "Table metadata changed. Read table metadata again before comparing."
				}
				if errors.Is(result.err, tc.ErrUnsupported) {
					code = "unsupported"
					message = "The selected table, type or representation is unsupported."
				}
				failure = &status{state: "failed", code: result.side + "." + code, message: message}
			}
		}
	}
	if j.ctx.Err() != nil {
		j.cleanup()
		return
	}
	if failure != nil {
		j.state.CompareAndSwap(running, failure)
		j.cleanup()
		return
	}
	if describe {
		descriptors := &protocol.DataDescriptors{Source: source.descriptor, Target: target.descriptor}
		j.state.CompareAndSwap(running, &status{state: "completed", descriptors: descriptors})
		_ = os.RemoveAll(j.dir)
		return
	}
	if source.writer == nil || target.writer == nil {
		j.state.CompareAndSwap(running, &status{state: "failed", code: "captureLimit", message: "The capture limit was reached before both inputs were available."})
		j.cleanup()
		return
	}
	for _, side := range []*captureResult{&source, &target} {
		o := &side.outcome
		o.StoredRows = side.writer.Rows()
		o.ObservedAtLeast = max(o.ObservedAtLeast, o.StoredRows)
		o.DescriptorDigest = side.descriptor.Digest
		o.CaptureDigest = side.writer.Digest()
		o.FullOriginals = r.Originals == "allColumns"
		o.Table = side.descriptor.Table
		o.Engine = side.descriptor.Engine
		o.ExcludedColumns = len(side.descriptor.Columns) - len(r.Columns)
		if limited.Load() {
			o.PartialReasons = append(o.PartialReasons, "storageLimit")
		}
		if o.FinishedAt == "" {
			o.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano)
		}
	}
	var err error
	artifactA, err := source.writer.Publish(j.ctx, source.outcome)
	if err == nil {
		j.source = comparisonjob.FromArtifact(artifactA)
	}
	if err == nil {
		artifactB, e := target.writer.Publish(j.ctx, target.outcome)
		err = e
		if e == nil {
			j.target = comparisonjob.FromArtifact(artifactB)
		}
	}
	// The private handoff retains complete originals and the trusted descriptors,
	// filters and mapping. Settings/credentials and generated SQL never enter it.
	provenance := struct {
		Version        int `json:"version"`
		Source, Target captureProvenance
		Mappings       []tc.Mapping `json:"mappings"`
		Originals      string       `json:"originals"`
	}{1, captureProvenance{source.descriptor, source.outcome, *r.Source.Filters}, captureProvenance{target.descriptor, target.outcome, *r.Target.Filters}, r.Columns, r.Originals}
	if err == nil {
		b, e := json.Marshal(provenance)
		err = e
		if err == nil {
			err = budget.Reserve(int64(len(b)), true)
		}
		if err == nil {
			err = os.WriteFile(filepath.Join(j.dir, "capture.json"), b, 0600)
		}
	}
	if err == nil {
		mappings, e := resolveMappings(j.source.Metadata(), j.target.Metadata(), r.Columns)
		err = e
		if err == nil {
			comparing := &status{state: "running", phase: "comparing"}
			if !j.state.CompareAndSwap(running, comparing) {
				j.cleanup()
				return
			}
			running = comparing
			j.result, err = resultcompare.Compare(j.ctx, j.source, j.target, resultcompare.Options{Mode: "key", Columns: mappings, ScratchDir: filepath.Join(j.dir, "compare"), QuotaBytes: m.options.QuotaBytes - budget.Bytes(), MemoryBytes: 32 << 20})
		}
	}
	if err != nil || j.ctx.Err() != nil {
		if j.ctx.Err() == nil {
			j.state.CompareAndSwap(running, &status{state: "failed", code: "comparisonLimitOrStorage", message: "Comparison storage or sort limits were exceeded, or capture data became unavailable."})
		}
		j.cleanup()
		return
	}
	sum := j.result.Summary()
	if source.outcome.ExcludedColumns > 0 || target.outcome.ExcludedColumns > 0 || !source.outcome.FullOriginals || !target.outcome.FullOriginals {
		sum.FullEquality = false
	}
	encoded, _ := json.Marshal(provenance)
	digest := sha256.Sum256(encoded)
	keyCount := 0
	for _, c := range r.Columns {
		if c.Key {
			keyCount++
		}
	}
	summary := &protocol.DataComparisonSummary{FormatVersion: 1, Comparison: sum, Source: source.outcome, Target: target.outcome, MappedColumns: len(r.Columns), KeyColumns: keyCount, ModelDigest: hex.EncodeToString(digest[:])}
	if !j.state.CompareAndSwap(running, &status{state: "completed", summary: summary}) {
		j.cleanup()
	}
}

type captureProvenance struct {
	Descriptor tc.Descriptor `json:"descriptor"`
	Outcome    tc.Outcome    `json:"outcome"`
	Filters    []tc.Filter   `json:"filters"`
}

func captureSpec(d tc.Descriptor, side protocol.DataReadSide, mappings []tc.Mapping, originals string, source bool) (tc.Spec, []tc.Column, error) {
	spec := tc.Spec{Table: side.Table, DescriptorDigest: side.DescriptorDigest, ReadLimit: side.ReadLimit}
	if side.Filters == nil {
		return spec, nil, tc.ErrInvalid
	}
	spec.Filters = *side.Filters
	selected := map[string]bool{}
	for _, m := range mappings {
		name := m.Source
		if !source {
			name = m.Target
		}
		if !tc.Name(name) || selected[name] {
			return spec, nil, tc.ErrInvalid
		}
		selected[name] = true
		if m.Key {
			spec.Keys = append(spec.Keys, name)
		}
	}
	columns := []tc.Column{}
	for _, c := range d.Columns {
		if originals == "allColumns" || selected[c.Name] {
			spec.Columns = append(spec.Columns, c.Name)
			c.Index = len(columns)
			columns = append(columns, c)
		}
	}
	if len(selected) != len(mappings) {
		return spec, nil, tc.ErrInvalid
	}
	known := map[string]bool{}
	for _, c := range d.Columns {
		known[c.Name] = true
	}
	for name := range selected {
		if !known[name] {
			return spec, nil, tc.ErrChanged
		}
	}
	return spec, columns, tc.Validate(d, spec)
}
func resolveMappings(left, right resultcompare.Metadata, columns []tc.Mapping) ([]resultcompare.Mapping, error) {
	a, b := map[string]int{}, map[string]int{}
	for i, c := range left.Columns {
		a[c.Name] = i
	}
	for i, c := range right.Columns {
		b[c.Name] = i
	}
	out := []resultcompare.Mapping{}
	for _, c := range columns {
		x, ok := a[c.Source]
		y, yes := b[c.Target]
		if !ok || !yes {
			return nil, tc.ErrChanged
		}
		out = append(out, resultcompare.Mapping{Left: x, Right: y, Key: c.Key})
	}
	return out, nil
}
