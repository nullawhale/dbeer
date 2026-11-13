// Package schemajob owns dedicated, read-only sessions and private transient reports.
package schemajob

import (
	"context"
	"crypto/rand"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/schemabundle"
	"dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/schemaimport"
	"dbeer/helper/internal/syncplan"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type SourceReader func(context.Context, schemabundle.Source, string, schemacompare.DefinitionRenderer) (schemaimport.Imported, error)

type Options struct {
	ReadSource       SourceReader
	Root             string
	Deadline         time.Duration
	RenderDefinition schemacompare.DefinitionRenderer
	RenderPlan       func(context.Context, schemacompare.Report) (syncplan.Plan, error)
}
type status struct {
	state, code, message string
	summary              *schemacompare.Summary
	bundleSummary        *schemabundle.Summary
	importSummary        *schemabundle.ImportedSource
}
type job struct {
	id, dir   string
	ctx       context.Context
	cancel    context.CancelFunc
	done      chan struct{}
	status    atomic.Pointer[status]
	mu        sync.Mutex
	result    *schemacompare.Result
	bundle    *schemabundle.Result
	bundleJob bool
	importJob bool
}
type Manager struct {
	mu      sync.Mutex
	jobs    map[string]*job
	root    string
	open    adapter.OpenFunc
	options Options
	closed  bool
	workers sync.WaitGroup
}

func New(open adapter.OpenFunc, o Options) (*Manager, error) {
	if open == nil {
		return nil, schemacompare.ErrInvalid
	}
	root, e := os.MkdirTemp(o.Root, "dbeer-schema-")
	if e != nil {
		return nil, e
	}
	if o.Deadline <= 0 {
		o.Deadline = 2 * time.Minute
	}
	return &Manager{jobs: map[string]*job{}, root: root, open: open, options: o}, nil
}
func (m *Manager) Close() {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		m.workers.Wait()
		return
	}
	m.closed = true
	for _, j := range m.jobs {
		j.cancel()
	}
	m.mu.Unlock()
	m.workers.Wait()
	for _, j := range m.jobs {
		j.cleanup()
	}
	_ = os.RemoveAll(m.root)
}
func response(c protocol.Command, j *job) protocol.Response {
	s := j.status.Load()
	return protocol.Response{Type: c.Type + ".result", RequestID: c.RequestID, SchemaComparison: &protocol.SchemaComparisonResponse{JobID: j.id, State: s.state, Code: s.code, Message: s.message, Summary: s.summary, BundleSummary: s.bundleSummary, ImportSummary: s.importSummary}}
}
func fail(c protocol.Command) protocol.Response {
	return protocol.ErrorResponse(c, "schemaComparison", "Schema comparison data is unavailable or the request is invalid.")
}
func (m *Manager) Handle(c protocol.Command) protocol.Response {
	r := c.SchemaComparison
	if r == nil {
		return fail(c)
	}
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return fail(c)
	}
	if c.Type == "schema.start" || c.Type == "schema.bundle.start" || c.Type == "schema.import.start" {
		bundleJob := c.Type == "schema.bundle.start"
		importJob := c.Type == "schema.import.start"
		valid := r.Source != nil
		if importJob {
			valid = r.Bundle != nil && r.Bundle.Valid(true)
		} else if bundleJob {
			valid = valid && r.Source.Bundle == nil && schemabundle.SchemasValid(r.Source.Connection.DatabaseEngine(), r.Schemas)
		} else {
			valid = valid && r.Target != nil && r.Mappings != nil && r.Mappings.Valid() && r.Source.Valid() && r.Target.Valid() && r.Source.Engine() == r.Target.Engine()
		}
		if len(m.jobs) >= 2 || !valid {
			m.mu.Unlock()
			return fail(c)
		}
		var token [16]byte
		if _, e := rand.Read(token[:]); e != nil {
			m.mu.Unlock()
			return fail(c)
		}
		id := hex.EncodeToString(token[:])
		ctx, cancel := context.WithCancel(context.Background())
		j := &job{id: id, dir: filepath.Join(m.root, id), ctx: ctx, cancel: cancel, done: make(chan struct{}), bundleJob: bundleJob, importJob: importJob}
		if e := os.Mkdir(j.dir, 0700); e != nil {
			cancel()
			m.mu.Unlock()
			return fail(c)
		}
		j.status.Store(&status{state: "pending"})
		m.jobs[id] = j
		m.workers.Add(1)
		out := response(c, j)
		if importJob {
			go m.runImport(j, *r)
		} else if bundleJob {
			go m.runBundle(j, *r)
		} else {
			go m.run(j, *r)
		}
		m.mu.Unlock()
		return out
	}
	j := m.jobs[r.JobID]
	if j == nil || j.bundleJob != strings.HasPrefix(c.Type, "schema.bundle.") || j.importJob != strings.HasPrefix(c.Type, "schema.import.") {
		m.mu.Unlock()
		return fail(c)
	}
	if c.Type == "schema.cancel" || c.Type == "schema.close" || c.Type == "schema.bundle.cancel" || c.Type == "schema.bundle.close" || c.Type == "schema.import.cancel" || c.Type == "schema.import.close" {
		j.cancel()
		state := "cancelled"
		if c.Type == "schema.close" || c.Type == "schema.bundle.close" || c.Type == "schema.import.close" {
			state = "closed"
		}
		j.status.Store(&status{state: state})
		out := response(c, j)
		if state == "closed" || state == "cancelled" {
			m.workers.Add(1)
			go func() {
				defer m.workers.Done()
				<-j.done
				j.cleanup()
				m.mu.Lock()
				if state == "closed" {
					delete(m.jobs, j.id)
				}
				m.mu.Unlock()
			}()
		}
		m.mu.Unlock()
		return out
	}
	m.mu.Unlock()
	if c.Type == "schema.status" || c.Type == "schema.bundle.status" || c.Type == "schema.import.status" {
		return response(c, j)
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.importJob {
		return fail(c)
	}
	if j.bundleJob {
		if c.Type != "schema.bundle.export" || j.status.Load().state != "completed" || j.bundle == nil {
			return fail(c)
		}
		maxBytes := r.MaxBytes
		if maxBytes == 0 {
			maxBytes = 65536
		}
		chunk, e := j.bundle.Chunk(j.ctx, r.ValueRef, r.Offset, maxBytes)
		if e != nil {
			return fail(c)
		}
		out := response(c, j)
		out.SchemaComparison.BundleSummary = nil
		out.SchemaComparison.Export = &chunk
		return out
	}
	if j.status.Load().state != "completed" || j.result == nil {
		return fail(c)
	}
	out := response(c, j)
	out.SchemaComparison.Summary = nil
	switch c.Type {
	case "schema.plan":
		if r.ModelDigest != j.result.Report.Summary.ModelDigest || !syncplan.DigestValid(r.ModelDigest) || m.options.RenderPlan == nil {
			return fail(c)
		}
		plan, e := m.options.RenderPlan(j.ctx, j.result.Report)
		if e != nil || plan.ModelDigest != r.ModelDigest || plan.Kind != "schema" || plan.Engine != j.result.Report.Summary.Engine || plan.Validate() != nil {
			return fail(c)
		}
		// Cancellation can arrive while a renderer works. Never return a draft
		// from a retired owner, even if the immutable report still exists.
		if j.ctx.Err() != nil || j.status.Load().state != "completed" {
			return fail(c)
		}
		out.SchemaComparison.Plan = &plan
	case "schema.diff":
		d, e := j.result.TextDiff(j.ctx, r.Offset, m.options.RenderDefinition)
		if e != nil {
			return fail(c)
		}
		out.SchemaComparison.Diff = &d
		out.SchemaComparison.Offset = &r.Offset
	case "schema.page":
		limit, maxBytes := r.Limit, r.MaxBytes
		if limit == 0 {
			limit = 100
		}
		if maxBytes == 0 {
			maxBytes = 262144
		}
		p, e := j.result.Page(r.Collection, r.Offset, limit, maxBytes)
		if e != nil {
			return fail(c)
		}
		out.SchemaComparison.Page = &p
	case "schema.value", "schema.export":
		maxBytes := r.MaxBytes
		if maxBytes == 0 {
			maxBytes = 65536
		}
		v, e := j.result.Chunk(r.ValueRef, r.Offset, maxBytes, c.Type == "schema.export")
		if e != nil {
			return fail(c)
		}
		if c.Type == "schema.export" {
			out.SchemaComparison.Export = &v
		} else {
			out.SchemaComparison.Value = &v
		}
	default:
		return fail(c)
	}
	return out
}
func (j *job) cleanup() {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.bundle != nil {
		_ = j.bundle.Close()
		j.bundle = nil
	}
	if j.result != nil {
		_ = j.result.Close()
		j.result = nil
	}
	_ = os.RemoveAll(j.dir)
}
func (m *Manager) run(j *job, r protocol.SchemaComparisonRequest) {
	defer m.workers.Done()
	defer close(j.done)
	ctx, cancel := context.WithTimeout(j.ctx, m.options.Deadline)
	defer cancel()
	previous := j.status.Load()
	running := &status{state: "running"}
	if previous.state != "pending" || !j.status.CompareAndSwap(previous, running) {
		j.cleanup()
		return
	}
	type outcome struct {
		capture schemacompare.Capture
		side    string
		err     error
	}
	out := make(chan outcome, 2)
	for i, side := range []*protocol.SchemaSide{r.Source, r.Target} {
		name := "source"
		if i == 1 {
			name = "target"
		}
		spec := schemacompare.CaptureSpec{Limits: schemacompare.DefaultLimits()}
		for _, p := range r.Mappings.Schemas {
			schema := p.Source
			if i == 1 {
				schema = p.Target
			}
			spec.Schemas = append(spec.Schemas, schema)
		}
		go func(side *protocol.SchemaSide, name string, spec schemacompare.CaptureSpec) {
			capture, err := m.captureSide(ctx, *side, spec, j.dir)
			out <- outcome{capture, name, err}
		}(side, name, spec)
	}
	var source, target schemacompare.Capture
	var failure *status
	for range 2 {
		o := <-out
		if o.err != nil && failure == nil {
			code := "metadataUnavailable"
			message := "Schema metadata could not be captured."
			if errors.Is(o.err, schemaimport.ErrChanged) {
				code = "sourceChanged"
				message = "A historical schema source changed. Inspect the selected folder again."
			} else if errors.Is(o.err, schemaimport.ErrUnsupported) {
				code = "ddlUnsupported"
				message = "A changed historical definition uses unsupported SQL grammar."
			} else if errors.Is(o.err, schemacompare.ErrLimit) {
				code = "limit"
				message = "Schema metadata exceeded the comparison limits."
			}
			failure = &status{state: "failed", code: o.side + "." + code, message: message}
			j.cancel()
		}
		if o.side == "source" {
			source = o.capture
		} else {
			target = o.capture
		}
	}
	if j.status.Load().state == "cancelled" || j.status.Load().state == "closed" {
		j.cleanup()
		return
	}
	if failure != nil {
		j.status.CompareAndSwap(running, failure)
		j.cleanup()
		return
	}
	if ctx.Err() != nil {
		j.status.CompareAndSwap(running, &status{state: "failed", code: "deadline", message: "Schema comparison timed out."})
		j.cleanup()
		return
	}
	result, e := schemacompare.Build(j.ctx, j.dir, source, target, *r.Mappings)
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.ctx.Err() != nil || j.status.Load().state == "closed" || j.status.Load().state == "cancelled" {
		if result != nil {
			_ = result.Close()
		}
		_ = os.RemoveAll(j.dir)
		return
	}
	if e != nil {
		j.status.CompareAndSwap(running, &status{state: "failed", code: "reportUnavailable", message: "Schema comparison report could not be created."})
		_ = os.RemoveAll(j.dir)
		return
	}
	if !j.status.CompareAndSwap(running, &status{state: "completed", summary: &result.Report.Summary}) {
		_ = result.Close()
		_ = os.RemoveAll(j.dir)
		return
	}
	j.result = result
}

// capture opens exactly one dedicated owner. Both comparison and bundle jobs use
// the same readonly capability and connection cancellation boundary.
func (m *Manager) capture(ctx context.Context, side protocol.SchemaSide, spec schemacompare.CaptureSpec) (schemacompare.Capture, error) {
	collector := schemacompare.NewCollector(ctx, spec.Limits)
	budget := 5 * time.Second
	if side.Connection.SSH != nil {
		budget = 30 * time.Second
	}
	if side.Connection.PasswordCommand != nil {
		budget += 15 * time.Second
	}
	openingContext, stopOpening := context.WithTimeout(ctx, budget)
	session, err := m.open(openingContext, side.Connection)
	stopOpening()
	if session != nil {
		defer session.Close()
	}
	if err != nil {
		return collector.Capture, err
	}
	if err = ctx.Err(); err != nil {
		return collector.Capture, err
	}
	reader, ok := session.(adapter.SchemaReader)
	if !ok {
		return collector.Capture, schemacompare.ErrInvalid
	}
	if side.Connection.DatabaseEngine() != "cassandra" {
		readonly, ok := session.(adapter.ReadOnlySession)
		if !ok {
			return collector.Capture, schemacompare.ErrInvalid
		}
		if err = readonly.SetReadOnly(ctx, true); err != nil {
			return collector.Capture, err
		}
	}
	err = reader.ReadSchema(ctx, spec, collector)
	return collector.Capture, err
}
func (m *Manager) runBundle(j *job, r protocol.SchemaComparisonRequest) {
	defer m.workers.Done()
	defer close(j.done)
	ctx, cancel := context.WithTimeout(j.ctx, m.options.Deadline)
	defer cancel()
	previous := j.status.Load()
	running := &status{state: "running"}
	if previous.state != "pending" || !j.status.CompareAndSwap(previous, running) {
		j.cleanup()
		return
	}
	capture, err := m.capture(ctx, *r.Source, schemacompare.CaptureSpec{Schemas: r.Schemas, Limits: schemacompare.DefaultLimits()})
	var result *schemabundle.Result
	if err == nil {
		result, err = schemabundle.Build(ctx, j.dir, capture, r.Schemas, m.options.RenderDefinition)
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.ctx.Err() != nil || j.status.Load().state == "closed" || j.status.Load().state == "cancelled" {
		if result != nil {
			_ = result.Close()
		}
		_ = os.RemoveAll(j.dir)
		return
	}
	if err != nil {
		code, message := "bundleUnavailable", "The schema bundle could not be captured. Check metadata permissions."
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
			code, message = "deadline", "Schema capture exceeded its deadline."
		} else if errors.Is(err, schemacompare.ErrLimit) || errors.Is(err, schemabundle.ErrLimit) {
			code, message = "limit", "Schema metadata exceeded the bundle limits."
		}
		j.status.CompareAndSwap(running, &status{state: "failed", code: code, message: message})
		_ = os.RemoveAll(j.dir)
		return
	}
	if !j.status.CompareAndSwap(running, &status{state: "completed", bundleSummary: &result.Summary}) {
		_ = result.Close()
		_ = os.RemoveAll(j.dir)
		return
	}
	j.bundle = result
}

func (m *Manager) captureSide(ctx context.Context, side protocol.SchemaSide, spec schemacompare.CaptureSpec, workdir string) (schemacompare.Capture, error) {
	if side.Bundle == nil {
		return m.capture(ctx, side, spec)
	}
	imported, err := m.readSource(ctx, *side.Bundle, workdir)
	if err != nil {
		return schemacompare.Capture{}, err
	}
	capture, err := schemaimport.Select(ctx, imported.Capture, spec.Schemas)
	if err != nil {
		return schemacompare.Capture{}, err
	}
	summary := imported.Summary
	kind := "bundle"
	if summary.ModifiedSQL > 0 {
		kind = "editedBundle"
	}
	origin := schemacompare.HistoricalOrigin{Kind: kind, Label: summary.Label, ManifestSHA256: summary.Source.ManifestSHA256, ContentSHA256: summary.Source.ContentSHA256, ModifiedSQL: summary.ModifiedSQL, ManualObjects: summary.ManualObjects}
	if !origin.Valid() {
		return schemacompare.Capture{}, schemacompare.ErrInvalid
	}
	capture.Context.Origin = &origin
	return capture, nil
}
func (m *Manager) runImport(j *job, r protocol.SchemaComparisonRequest) {
	defer m.workers.Done()
	defer close(j.done)
	ctx, cancel := context.WithTimeout(j.ctx, m.options.Deadline)
	defer cancel()
	previous := j.status.Load()
	running := &status{state: "running"}
	if previous.state != "pending" || !j.status.CompareAndSwap(previous, running) {
		j.cleanup()
		return
	}
	imported, err := m.readSource(ctx, *r.Bundle, j.dir)
	if err == nil {
		err = ctx.Err()
	}
	if j.ctx.Err() != nil || j.status.Load().state == "cancelled" || j.status.Load().state == "closed" {
		j.cleanup()
		return
	}
	if err != nil {
		code, message := "sourceInvalid", "The schema bundle could not be validated. Check its manifest, SQL files and supported definitions."
		if errors.Is(err, schemaimport.ErrChanged) {
			code, message = "sourceChanged", "The schema bundle changed. Inspect the selected folder again."
		} else if errors.Is(err, schemaimport.ErrUnsupported) {
			code, message = "ddlUnsupported", "A changed SQL definition uses unsupported grammar. Keep the original file or use supported table, column and key definitions."
		} else if errors.Is(err, schemaimport.ErrLimit) || errors.Is(err, schemacompare.ErrLimit) {
			code, message = "limit", "The schema bundle exceeds the import limits."
		} else if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			code, message = "deadline", "The schema bundle inspection stopped or exceeded its deadline."
		}
		j.status.CompareAndSwap(running, &status{state: "failed", code: code, message: message})
		return
	}
	summary := imported.Summary
	j.status.CompareAndSwap(running, &status{state: "completed", importSummary: &summary})
}

func (m *Manager) readSource(ctx context.Context, source schemabundle.Source, dir string) (schemaimport.Imported, error) {
	if m.options.ReadSource != nil {
		return m.options.ReadSource(ctx, source, dir, m.options.RenderDefinition)
	}
	return schemaimport.Read(ctx, source, dir, m.options.RenderDefinition)
}
