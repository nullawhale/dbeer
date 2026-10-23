// Package schemajob owns dedicated, read-only sessions and private transient reports.
package schemajob

import (
	"context"
	"crypto/rand"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/schemacompare"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

type Options struct {
	Root             string
	Deadline         time.Duration
	RenderDefinition schemacompare.DefinitionRenderer
}
type status struct {
	state, code, message string
	summary              *schemacompare.Summary
}
type job struct {
	id, dir string
	ctx     context.Context
	cancel  context.CancelFunc
	done    chan struct{}
	status  atomic.Pointer[status]
	mu      sync.Mutex
	result  *schemacompare.Result
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
	return protocol.Response{Type: c.Type + ".result", RequestID: c.RequestID, SchemaComparison: &protocol.SchemaComparisonResponse{JobID: j.id, State: s.state, Code: s.code, Message: s.message, Summary: s.summary}}
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
	if c.Type == "schema.start" {
		if len(m.jobs) >= 2 || r.Source == nil || r.Target == nil || r.Mappings == nil || !r.Mappings.Valid() || r.Source.Connection.DatabaseEngine() != r.Target.Connection.DatabaseEngine() {
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
		j := &job{id: id, dir: filepath.Join(m.root, id), ctx: ctx, cancel: cancel, done: make(chan struct{})}
		if e := os.Mkdir(j.dir, 0700); e != nil {
			cancel()
			m.mu.Unlock()
			return fail(c)
		}
		j.status.Store(&status{state: "pending"})
		m.jobs[id] = j
		m.workers.Add(1)
		out := response(c, j)
		go m.run(j, *r)
		m.mu.Unlock()
		return out
	}
	j := m.jobs[r.JobID]
	if j == nil {
		m.mu.Unlock()
		return fail(c)
	}
	if c.Type == "schema.cancel" || c.Type == "schema.close" {
		j.cancel()
		state := "cancelled"
		if c.Type == "schema.close" {
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
	if c.Type == "schema.status" {
		return response(c, j)
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.status.Load().state != "completed" || j.result == nil {
		return fail(c)
	}
	out := response(c, j)
	out.SchemaComparison.Summary = nil
	switch c.Type {
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
			collector := schemacompare.NewCollector(ctx, spec.Limits)
			err := func() error {
				budget := 5 * time.Second
				if side.Connection.SSH != nil {
					budget = 30 * time.Second
				}
				if side.Connection.PasswordCommand != nil {
					budget += 15 * time.Second
				}
				openingContext, stopOpening := context.WithTimeout(ctx, budget)
				session, e := m.open(openingContext, side.Connection)
				stopOpening()
				if session != nil {
					defer session.Close()
				}
				if e != nil {
					return e
				}
				if e = ctx.Err(); e != nil {
					return e
				}
				reader, ok := session.(adapter.SchemaReader)
				if !ok {
					return schemacompare.ErrInvalid
				}
				// Cassandra catalog capture issues only generated SELECT reads;
				// that engine has no server read-only transaction mode.
				if side.Connection.DatabaseEngine() != "cassandra" {
					readonly, ok := session.(adapter.ReadOnlySession)
					if !ok {
						return schemacompare.ErrInvalid
					}
					if e = readonly.SetReadOnly(ctx, true); e != nil {
						return e
					}
				}
				return reader.ReadSchema(ctx, spec, collector)
			}()
			out <- outcome{collector.Capture, name, err}
		}(side, name, spec)
	}
	var source, target schemacompare.Capture
	var failure *status
	for range 2 {
		o := <-out
		if o.err != nil && failure == nil {
			code := "metadataUnavailable"
			message := "Schema metadata could not be captured."
			if errors.Is(o.err, schemacompare.ErrLimit) {
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
