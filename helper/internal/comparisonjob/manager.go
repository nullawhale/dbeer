// Package comparisonjob owns bounded asynchronous comparisons separately from
// database sessions. Work never depends on a protocol output consumer.
package comparisonjob

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/resultcompare"
)

const MaxJobs = 2

type OpenSource func(context.Context, protocol.ArtifactReference) (resultcompare.Source, error)
type Options struct {
	Root        string
	QuotaBytes  int64
	MemoryBytes int
	FanIn       int
}
type status struct {
	state, message string
	summary        *resultcompare.Summary
}
type job struct {
	id, dir     string
	ctx         context.Context
	cancel      context.CancelFunc
	status      atomic.Pointer[status]
	mu          sync.Mutex
	result      *resultcompare.Result
	left, right resultcompare.Source
	done        chan struct{}
}
type Manager struct {
	mu        sync.Mutex
	jobs      map[string]*job
	root      string
	open      OpenSource
	options   Options
	closed    bool
	workers   sync.WaitGroup
	retiring  map[*job]bool
	retirees  sync.WaitGroup
	closeDone chan struct{}
}

func New(open OpenSource, o Options) (*Manager, error) {
	if open == nil {
		return nil, resultcompare.ErrConfiguration
	}
	root, e := os.MkdirTemp(o.Root, "dbeer-comparison-")
	if e != nil {
		return nil, e
	}
	return &Manager{jobs: map[string]*job{}, retiring: map[*job]bool{}, root: root, open: open, options: o, closeDone: make(chan struct{})}, nil
}
func (j *job) cleanup() {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.result != nil {
		_ = j.result.Close()
		j.result = nil
	}
	if j.left != nil {
		_ = j.left.Close()
		j.left = nil
	}
	if j.right != nil {
		_ = j.right.Close()
		j.right = nil
	}
	_ = os.RemoveAll(j.dir)
}
func (m *Manager) Close() {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		<-m.closeDone
		return
	}
	m.closed = true
	defer close(m.closeDone)
	jobs := make([]*job, 0, len(m.jobs))
	for _, j := range m.jobs {
		j.cancel()
		j.status.Store(&status{state: "closed"})
		jobs = append(jobs, j)
	}
	for j := range m.retiring {
		j.cancel()
		j.status.Store(&status{state: "closed"})
		jobs = append(jobs, j)
	}
	m.jobs = map[string]*job{}
	m.mu.Unlock()
	m.workers.Wait()
	m.retirees.Wait()
	for _, j := range jobs {
		j.cleanup()
	}
	_ = os.RemoveAll(m.root)
}
func (m *Manager) response(c protocol.Command, j *job) protocol.Response {
	s := j.status.Load()
	return protocol.Response{Type: c.Type + ".result", RequestID: c.RequestID, Comparison: &protocol.ComparisonResponse{JobID: j.id, State: s.state, Message: s.message, Summary: s.summary}}
}
func failure(c protocol.Command, e error) protocol.Response {
	message := "Comparison data is unavailable or changed."
	switch {
	case errors.Is(e, resultcompare.ErrConfiguration):
		message = "Invalid comparison configuration."
	case errors.Is(e, resultcompare.ErrQuota):
		message = "Comparison scratch quota exceeded. Close other comparisons or use smaller inputs."
	case errors.Is(e, resultcompare.ErrReference):
		message = "Comparison reference or page request is invalid."
	case errors.Is(e, context.Canceled):
		return protocol.ErrorResponse(c, "cancelled", "Comparison was cancelled.")
	}
	return protocol.ErrorResponse(c, "comparison", message)
}
func (m *Manager) Handle(c protocol.Command) protocol.Response {
	if c.Comparison == nil {
		return failure(c, resultcompare.ErrConfiguration)
	}
	if c.Type == "compare.start" {
		return m.start(c)
	}
	m.mu.Lock()
	j := m.jobs[c.Comparison.JobID]
	if m.closed || j == nil {
		m.mu.Unlock()
		return failure(c, resultcompare.ErrReference)
	}
	if c.Type == "compare.cancel" || c.Type == "compare.close" {
		j.cancel()
		state := "cancelled"
		if c.Type == "compare.close" {
			state = "closed"
		}
		previous := j.status.Swap(&status{state: state})
		if c.Type == "compare.close" {
			delete(m.jobs, j.id)
			m.retiring[j] = true
			m.retirees.Add(1)
			go func() {
				defer m.retirees.Done()
				<-j.done
				j.cleanup()
				m.mu.Lock()
				delete(m.retiring, j)
				m.mu.Unlock()
			}()
		} else if previous.state == "completed" || previous.state == "failed" {
			go j.cleanup()
		}
		response := m.response(c, j)
		m.mu.Unlock()
		return response
	}
	m.mu.Unlock()
	switch c.Type {
	case "compare.status":
		return m.response(c, j)
	case "compare.page", "compare.value":
		j.mu.Lock()
		defer j.mu.Unlock()
		if j.status.Load().state != "completed" || j.result == nil {
			return failure(c, resultcompare.ErrReference)
		}
		response := protocol.Response{Type: c.Type + ".result", RequestID: c.RequestID, Comparison: &protocol.ComparisonResponse{JobID: j.id, State: "completed"}}
		if c.Type == "compare.page" {
			page, e := j.result.Page(j.ctx, c.Comparison.Offset, c.Comparison.Limit, c.Comparison.MaxBytes, c.Comparison.CellOffset)
			if e != nil {
				return m.readFailure(c, j, e)
			}
			response.Comparison.Page = &page
		} else {
			value, e := j.result.Value(j.ctx, c.Comparison.ValueRef, c.Comparison.Offset, c.Comparison.MaxBytes)
			if e != nil {
				return m.readFailure(c, j, e)
			}
			response.Comparison.Value = &value
		}
		return response
	default:
		return failure(c, resultcompare.ErrConfiguration)
	}
}
func (m *Manager) start(c protocol.Command) protocol.Response {
	request := c.Comparison
	if request.Left == nil || request.Right == nil || request.Left.Kind != "snapshot" || request.Right.Kind != "snapshot" || !protocol.ValidArtifactID(request.Left.ID) || !protocol.ValidArtifactID(request.Right.ID) {
		return failure(c, resultcompare.ErrConfiguration)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return failure(c, resultcompare.ErrClosed)
	}
	if len(m.jobs)+len(m.retiring) >= MaxJobs {
		return protocol.ErrorResponse(c, "busy", "Close an existing comparison before starting another.")
	}
	var token [16]byte
	if _, e := rand.Read(token[:]); e != nil {
		return failure(c, e)
	}
	id := hex.EncodeToString(token[:])
	ctx, cancel := context.WithCancel(context.Background())
	j := &job{id: id, dir: filepath.Join(m.root, id), ctx: ctx, cancel: cancel, done: make(chan struct{})}
	j.status.Store(&status{state: "pending"})
	m.jobs[id] = j
	m.workers.Add(1)
	go m.run(j, *c.Comparison)
	return protocol.Response{Type: c.Type + ".result", RequestID: c.RequestID, Comparison: &protocol.ComparisonResponse{JobID: id, State: "pending"}}
}
func (m *Manager) run(j *job, request protocol.ComparisonRequest) {
	defer m.workers.Done()
	defer close(j.done)
	pending := j.status.Load()
	if pending.state != "pending" || !j.status.CompareAndSwap(pending, &status{state: "running"}) {
		j.cleanup()
		return
	}
	var err error
	// Only this worker writes source fields before publishing completed. Pending
	// cancellation never races source opening/cleanup.
	if err = os.Mkdir(j.dir, 0700); err == nil {
		j.left, err = m.open(j.ctx, *request.Left)
	}
	if err == nil {
		j.right, err = m.open(j.ctx, *request.Right)
	}
	if err == nil {
		j.result, err = resultcompare.Compare(j.ctx, j.left, j.right, resultcompare.Options{Mode: request.Mode, Columns: request.Columns, ScratchDir: j.dir, QuotaBytes: m.options.QuotaBytes, MemoryBytes: m.options.MemoryBytes, FanIn: m.options.FanIn})
	}
	current := j.status.Load()
	if err != nil || j.ctx.Err() != nil || current.state != "running" {
		j.cleanup()
		if current.state == "running" {
			state, message := "failed", "Comparison data is unavailable or changed."
			if errors.Is(err, resultcompare.ErrQuota) {
				message = "Comparison scratch quota exceeded."
			}
			if errors.Is(err, resultcompare.ErrConfiguration) {
				message = "Invalid comparison configuration."
			}
			if j.ctx.Err() != nil {
				state, message = "cancelled", ""
			}
			j.status.CompareAndSwap(current, &status{state: state, message: message})
		}
		return
	}
	summary := j.result.Summary()
	if !j.status.CompareAndSwap(current, &status{state: "completed", summary: &summary}) {
		j.cleanup()
	}
}

// Called while holding the job read lock. Integrity failures revoke the report;
// invalid client offsets/references alone do not destroy a valid comparison.
func (m *Manager) readFailure(c protocol.Command, j *job, e error) protocol.Response {
	if !errors.Is(e, resultcompare.ErrReference) && !errors.Is(e, context.Canceled) {
		current := j.status.Load()
		if current.state == "completed" && j.status.CompareAndSwap(current, &status{state: "failed", message: "Comparison data is unavailable or changed."}) {
			j.cancel()
			go j.cleanup()
		}
	}
	return failure(c, e)
}
