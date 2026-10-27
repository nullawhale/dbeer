package comparisonjob

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/resultartifact"
	"dbeer/helper/internal/resultcompare"
)

type fixtureSource struct {
	value  string
	closed atomic.Bool
	scan   func(context.Context) error
	read   func(context.Context) error
}

func (s *fixtureSource) Metadata() resultcompare.Metadata {
	return resultcompare.Metadata{Columns: []resultcompare.Column{{Index: 0, Name: "value", Engine: "postgresql", NativeType: "text"}}, RowCount: 1, Complete: true}
}
func (s *fixtureSource) Scan(ctx context.Context, visit func(resultcompare.RowRef, []*string) error) error {
	if s.scan != nil {
		return s.scan(ctx)
	}
	return visit(resultcompare.RowRef{Index: 0}, []*string{&s.value})
}
func (s *fixtureSource) ReadRow(ctx context.Context, _ resultcompare.RowRef) ([]*string, error) {
	if s.read != nil {
		if e := s.read(ctx); e != nil {
			return nil, e
		}
	}
	return []*string{&s.value}, nil
}
func (s *fixtureSource) Close() error { s.closed.Store(true); return nil }
func startRequest() protocol.Command {
	return protocol.Command{Type: "compare.start", RequestID: "start", Comparison: &protocol.ComparisonRequest{Left: &protocol.ArtifactReference{Kind: "snapshot", ID: "11111111-1111-1111-1111-111111111111"}, Right: &protocol.ArtifactReference{Kind: "snapshot", ID: "22222222-2222-2222-2222-222222222222"}, Mode: "rowOrder", Columns: []resultcompare.Mapping{{}}}}
}
func cmd(kind, id string) protocol.Command {
	return protocol.Command{Type: "compare." + kind, RequestID: kind, Comparison: &protocol.ComparisonRequest{JobID: id}}
}
func wait(t *testing.T, check func() bool) {
	t.Helper()
	deadline := time.After(5 * time.Second)
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	for {
		if check() {
			return
		}
		select {
		case <-deadline:
			t.Fatal("comparison did not reach expected state")
		case <-ticker.C:
		}
	}
}
func waitState(t *testing.T, m *Manager, id, state string) *protocol.ComparisonResponse {
	t.Helper()
	var response *protocol.ComparisonResponse
	wait(t, func() bool {
		response = m.Handle(cmd("status", id)).Comparison
		return response != nil && response.State == state
	})
	return response
}
func TestAdmissionRetainedJobsAndExplicitClose(t *testing.T) {
	var sources []*fixtureSource
	m, e := New(func(context.Context, protocol.ArtifactReference) (resultcompare.Source, error) {
		s := &fixtureSource{value: "same"}
		sources = append(sources, s)
		return s, nil
	}, Options{Root: t.TempDir()})
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	first := m.Handle(startRequest())
	if first.Comparison == nil || first.Comparison.State != "pending" {
		t.Fatal("start did not return pending immediately")
	}
	id := first.Comparison.JobID
	waitState(t, m, id, "completed")
	second := m.Handle(startRequest())
	waitState(t, m, second.Comparison.JobID, "completed")
	if busy := m.Handle(startRequest()); busy.Category != "busy" {
		t.Fatal("job admission is unbounded")
	}
	if r := m.Handle(cmd("cancel", id)); r.Comparison.State != "cancelled" {
		t.Fatal("cancel failed")
	}
	wait(t, func() bool { return sources[0].closed.Load() && sources[1].closed.Load() })
	if m.Handle(startRequest()).Category != "busy" {
		t.Fatal("cancelled status lost admission slot before explicit close")
	}
	if r := m.Handle(cmd("close", id)); r.Comparison.State != "closed" {
		t.Fatal("close failed")
	}
	wait(t, func() bool { m.mu.Lock(); defer m.mu.Unlock(); return len(m.retiring) == 0 })
	if m.Handle(cmd("status", id)).Type != "error" {
		t.Fatal("closed job still available")
	}
	third := m.Handle(startRequest())
	if third.Comparison == nil {
		t.Fatal("closed admission slot not reusable")
	}
	waitState(t, m, third.Comparison.JobID, "completed")
	root := m.root
	m.Close()
	if _, e = os.Stat(root); !os.IsNotExist(e) {
		t.Fatal("manager scratch retained after close")
	}
	for _, s := range sources {
		if !s.closed.Load() {
			t.Fatal("source handle leaked")
		}
	}
}
func TestCancelDuringOpenAndQuotaFailureCleanSources(t *testing.T) {
	left := &fixtureSource{value: "private exact bytes"}
	opening := make(chan struct{})
	var calls atomic.Int32
	m, e := New(func(ctx context.Context, _ protocol.ArtifactReference) (resultcompare.Source, error) {
		if calls.Add(1) == 1 {
			return left, nil
		}
		close(opening)
		<-ctx.Done()
		return nil, ctx.Err()
	}, Options{Root: t.TempDir()})
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	id := m.Handle(startRequest()).Comparison.JobID
	<-opening
	before := time.Now()
	if m.Handle(cmd("cancel", id)).Comparison.State != "cancelled" || time.Since(before) > time.Second {
		t.Fatal("cancel waited for worker output")
	}
	wait(t, func() bool { _, e := os.Stat(filepath.Join(m.root, id)); return left.closed.Load() && os.IsNotExist(e) })
	if _, e = os.Stat(filepath.Join(m.root, id)); !os.IsNotExist(e) {
		t.Fatal("cancelled open scratch retained")
	}
	a, b := &fixtureSource{value: "secret-left"}, &fixtureSource{value: "secret-right"}
	calls.Store(0)
	quota, e := New(func(context.Context, protocol.ArtifactReference) (resultcompare.Source, error) {
		if calls.Add(1) == 1 {
			return a, nil
		}
		return b, nil
	}, Options{Root: t.TempDir(), QuotaBytes: 1})
	if e != nil {
		t.Fatal(e)
	}
	defer quota.Close()
	qid := quota.Handle(startRequest()).Comparison.JobID
	status := waitState(t, quota, qid, "failed")
	if !strings.Contains(status.Message, "quota") || strings.Contains(status.Message, "secret") || !a.closed.Load() || !b.closed.Load() {
		t.Fatal("quota failure not safe and fully cleaned")
	}
	if _, e = os.Stat(filepath.Join(quota.root, qid)); !os.IsNotExist(e) {
		t.Fatal("quota failure scratch retained")
	}
}
func TestCancelAndCloseInterruptBlockedPageRead(t *testing.T) {
	for _, operation := range []string{"cancel", "close"} {
		t.Run(operation, func(t *testing.T) {
			reading := make(chan struct{})
			a := &fixtureSource{value: "left", read: func(ctx context.Context) error { close(reading); <-ctx.Done(); return ctx.Err() }}
			b := &fixtureSource{value: "right"}
			var calls atomic.Int32
			m, e := New(func(context.Context, protocol.ArtifactReference) (resultcompare.Source, error) {
				if calls.Add(1) == 1 {
					return a, nil
				}
				return b, nil
			}, Options{Root: t.TempDir()})
			if e != nil {
				t.Fatal(e)
			}
			defer m.Close()
			id := m.Handle(startRequest()).Comparison.JobID
			waitState(t, m, id, "completed")
			done := make(chan protocol.Response, 1)
			go func() { done <- m.Handle(cmd("page", id)) }()
			<-reading
			before := time.Now()
			control := m.Handle(cmd(operation, id))
			if control.Comparison == nil || time.Since(before) > time.Second {
				t.Fatal("Stop blocked behind page read")
			}
			select {
			case response := <-done:
				if response.Category != "cancelled" {
					t.Fatal("read not cancelled")
				}
			case <-time.After(time.Second):
				t.Fatal("cancel did not interrupt read")
			}
			wait(t, func() bool { return a.closed.Load() && b.closed.Load() })
		})
	}
}
func TestManagedArtifactAdapterUsesUUIDAndPreservesPartial(t *testing.T) {
	root := t.TempDir()
	if e := os.Chmod(root, 0700); e != nil {
		t.Fatal(e)
	}
	id := "11111111-1111-1111-1111-111111111111"
	dir := filepath.Join(root, id)
	if e := os.Mkdir(dir, 0700); e != nil {
		t.Fatal(e)
	}
	for _, name := range []string{"manifest.json", "rows.jsonl"} {
		data, e := os.ReadFile(filepath.Join("../../../protocol/fixtures/snapshot-v1", id, name))
		if e != nil {
			t.Fatal(e)
		}
		if e = os.WriteFile(filepath.Join(dir, name), data, 0600); e != nil {
			t.Fatal(e)
		}
	}
	open := OpenArtifacts(resultartifact.NewStore(root))
	if _, e := open(context.Background(), protocol.ArtifactReference{Kind: "snapshot", ID: "../manifest.json"}); !errors.Is(e, resultcompare.ErrReference) {
		t.Fatal("arbitrary path accepted")
	}
	m, e := New(open, Options{Root: t.TempDir()})
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	command := startRequest()
	command.Comparison.Right = command.Comparison.Left
	command.Comparison.Columns = []resultcompare.Mapping{{Left: 0, Right: 0}, {Left: 1, Right: 1}, {Left: 2, Right: 2}}
	job := m.Handle(command).Comparison.JobID
	s := waitState(t, m, job, "completed").Summary
	if s.Complete || s.FullEquality || s.UncertainRows != 3 {
		t.Fatal("legacy artifact lost its partial or incomplete type evidence")
	}
}

func TestIntegrityFailureRevokesReportAndRemovesScratch(t *testing.T) {
	left, right := &fixtureSource{value: "left", read: func(context.Context) error { return resultcompare.ErrSource }}, &fixtureSource{value: "right"}
	var calls atomic.Int32
	manager, e := New(func(context.Context, protocol.ArtifactReference) (resultcompare.Source, error) {
		if calls.Add(1) == 1 {
			return left, nil
		}
		return right, nil
	}, Options{Root: t.TempDir()})
	if e != nil {
		t.Fatal(e)
	}
	defer manager.Close()
	id := manager.Handle(startRequest()).Comparison.JobID
	waitState(t, manager, id, "completed")
	if response := manager.Handle(cmd("page", id)); response.Type != "error" || response.Category != "comparison" {
		t.Fatal("source mutation returned report values")
	}
	state := waitState(t, manager, id, "failed")
	if state.Summary != nil {
		t.Fatal("mutated source retained an equality assertion")
	}
	wait(t, func() bool {
		_, e := os.Stat(filepath.Join(manager.root, id))
		return os.IsNotExist(e) && left.closed.Load() && right.closed.Load()
	})
}

type blockingCloseSource struct {
	fixtureSource
	closing chan struct{}
	release chan struct{}
}

func (s *blockingCloseSource) Close() error {
	close(s.closing)
	<-s.release
	return s.fixtureSource.Close()
}
func TestConcurrentManagerCloseWaitsForResourceTeardown(t *testing.T) {
	left := &blockingCloseSource{fixtureSource: fixtureSource{value: "left"}, closing: make(chan struct{}), release: make(chan struct{})}
	right := &fixtureSource{value: "right"}
	var calls atomic.Int32
	manager, e := New(func(context.Context, protocol.ArtifactReference) (resultcompare.Source, error) {
		if calls.Add(1) == 1 {
			return left, nil
		}
		return right, nil
	}, Options{Root: t.TempDir()})
	if e != nil {
		t.Fatal(e)
	}
	id := manager.Handle(startRequest()).Comparison.JobID
	waitState(t, manager, id, "completed")
	first, second := make(chan struct{}), make(chan struct{})
	go func() { manager.Close(); close(first) }()
	<-left.closing
	go func() { manager.Close(); close(second) }()
	select {
	case <-second:
		t.Fatal("second Close returned before source teardown")
	case <-time.After(20 * time.Millisecond):
	}
	close(left.release)
	for _, done := range []chan struct{}{first, second} {
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("close did not finish")
		}
	}
	if !right.closed.Load() {
		t.Fatal("second source not closed")
	}
}
