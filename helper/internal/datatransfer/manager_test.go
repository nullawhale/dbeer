package datatransfer

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type fakeDatabase struct {
	rows              int
	captures, applies atomic.Int64
	readonly          atomic.Bool
	digest            string
	failure           error
	unknown           bool
}

func (f *fakeDatabase) Execute(context.Context, protocol.Command) protocol.Response {
	return protocol.Response{}
}
func (f *fakeDatabase) Close()                    {}
func (f *fakeDatabase) TransactionStatus() string { return "idle" }
func (f *fakeDatabase) SetReadOnly(_ context.Context, value bool) error {
	f.readonly.Store(value)
	return nil
}
func (f *fakeDatabase) TransferDescribe(context.Context, string, string) (Description, error) {
	return Description{Columns: []protocol.TransferColumn{{SourceIndex: 0, Name: "id", Type: "integer"}}, Digest: f.digest, Notices: []string{}}, nil
}
func (f *fakeDatabase) TransferCapture(ctx context.Context, _, _, digest string, consume func([]protocol.CellValue) error) (Description, error) {
	f.captures.Add(1)
	if digest != f.digest {
		return Description{}, ErrChanged
	}
	for index := range f.rows {
		if err := ctx.Err(); err != nil {
			return Description{}, err
		}
		if err := consume([]protocol.CellValue{text(strconv.Itoa(index))}); err != nil {
			return Description{}, err
		}
	}
	return f.TransferDescribe(ctx, "", "")
}
func (f *fakeDatabase) TransferPreview(context.Context, string, string, []protocol.TransferColumn) (string, string, error) {
	return "CREATE TABLE reviewed (id BIGINT);", "server-identity", nil
}
func (f *fakeDatabase) TransferApply(ctx context.Context, _, _, identity string, _ []protocol.TransferColumn, read RowReader, progress func(int64)) (Result, error) {
	f.applies.Add(1)
	if identity != "server-identity" {
		return Result{}, ErrChanged
	}
	if f.failure != nil {
		return Result{TableCreated: true, OutcomeUnknown: f.unknown}, f.failure
	}
	var count int64
	for {
		if err := ctx.Err(); err != nil {
			return Result{TableCreated: true}, err
		}
		row, err := read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return Result{}, err
		}
		if len(row) != 1 {
			return Result{}, ErrInvalid
		}
		count++
		progress(count)
	}
	return Result{Rows: count, TableCreated: true}, nil
}
func endpoint() *protocol.TransferEndpoint {
	return &protocol.TransferEndpoint{Connection: protocol.Connection{Engine: "postgresql", Host: "fixture.invalid", Port: 5432, Database: "fixture", User: "reader", SSLMode: "disable"}, Schema: "public", Table: "created"}
}
func waitTransfer(t *testing.T, m *Manager, id string) protocol.TransferReply {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		response := m.Handle(protocol.Command{Type: "transfer.status", RequestID: "status", Transfer: &protocol.TransferRequest{JobID: id}})
		if response.Transfer == nil {
			t.Fatal("job disappeared")
		}
		switch response.Transfer.State {
		case "pending", "running":
			time.Sleep(time.Millisecond)
		default:
			return *response.Transfer
		}
	}
	t.Fatal("transfer did not finish")
	return protocol.TransferReply{}
}
func manager(t *testing.T, source, target *fakeDatabase, quota int64) *Manager {
	t.Helper()
	m, err := New(func(_ context.Context, c protocol.Connection) (adapter.Session, error) {
		if c.Database == "source" {
			return source, nil
		}
		return target, nil
	}, Options{Root: t.TempDir(), QuotaBytes: quota})
	if err != nil {
		t.Fatal("cannot create private transfer manager")
	}
	t.Cleanup(m.Close)
	return m
}
func TestTransferCopiesBeyondDisplayAndOldCaptureLimitsAndAppliesOnce(t *testing.T) {
	source := &fakeDatabase{rows: 100001, digest: Digest("schema")}
	target := &fakeDatabase{}
	m := manager(t, source, target, 0)
	from := endpoint()
	from.Connection.Database = "source"
	from.Table = "original"
	request := protocol.TransferRequest{Mode: "table", Source: from, Target: endpoint(), SourceDigest: source.digest, Columns: []protocol.TransferColumn{{SourceIndex: 0, Name: "id", Type: "integer"}}}
	response := m.Handle(protocol.Command{Type: "transfer.preview", RequestID: "preview", Transfer: &request})
	if response.Transfer == nil {
		t.Fatal("preview rejected")
	}
	ready := waitTransfer(t, m, response.Transfer.JobID)
	if ready.State != "ready" || ready.RowsRead != 100001 || target.applies.Load() != 0 {
		t.Fatal("table capture was truncated or preview wrote data")
	}
	apply := protocol.TransferRequest{JobID: ready.JobID, PlanDigest: ready.PlanDigest, Confirmed: true}
	if reply := m.Handle(protocol.Command{Type: "transfer.apply", RequestID: "apply", Transfer: &apply}); reply.Transfer == nil {
		t.Fatal("reviewed apply rejected")
	}
	done := waitTransfer(t, m, ready.JobID)
	if done.State != "completed" || done.RowsWritten != 100001 || !done.TableCreated || target.applies.Load() != 1 {
		t.Fatal("complete immutable capture was not copied")
	}
	if replay := m.Handle(protocol.Command{Type: "transfer.apply", RequestID: "replay", Transfer: &apply}); replay.Type != "error" || target.applies.Load() != 1 {
		t.Fatal("completed transfer could be replayed")
	}
}
func TestTransferPreviewChecksLastCSVRowAndUnknownApplyNeverRetries(t *testing.T) {
	target := &fakeDatabase{}
	m := manager(t, &fakeDatabase{}, target, 0)
	request := protocol.TransferRequest{Mode: "csv", Target: endpoint(), Headers: []string{"id"}, Rows: [][]protocol.CellValue{{text("1")}, {text("late invalid value")}}, Columns: []protocol.TransferColumn{{SourceIndex: 0, Name: "id", Type: "integer"}}}
	response := m.Handle(protocol.Command{Type: "transfer.preview", RequestID: "bad", Transfer: &request})
	done := waitTransfer(t, m, response.Transfer.JobID)
	if done.State != "failed" || len(done.Diagnostics) != 1 || done.Diagnostics[0].Row != 2 || target.applies.Load() != 0 {
		t.Fatal("all-row validation failed to block target writes")
	}
	request.Rows = request.Rows[:1]
	target.failure = errors.New("private transport failure")
	target.unknown = true
	response = m.Handle(protocol.Command{Type: "transfer.preview", RequestID: "preview", Transfer: &request})
	ready := waitTransfer(t, m, response.Transfer.JobID)
	apply := protocol.TransferRequest{JobID: ready.JobID, PlanDigest: ready.PlanDigest, Confirmed: true}
	m.Handle(protocol.Command{Type: "transfer.apply", RequestID: "apply", Transfer: &apply})
	done = waitTransfer(t, m, ready.JobID)
	if done.State != "outcomeUnknown" || !done.OutcomeUnknown || !done.TableCreated {
		t.Fatal("uncertain destination outcome was hidden")
	}
	if m.Handle(protocol.Command{Type: "transfer.apply", RequestID: "again", Transfer: &apply}).Type != "error" || target.applies.Load() != 1 {
		t.Fatal("unknown apply outcome was replayed")
	}
	closed := m.Handle(protocol.Command{Type: "transfer.close", RequestID: "close-unknown", Transfer: &protocol.TransferRequest{JobID: done.JobID}})
	if closed.Transfer == nil || closed.Transfer.State != "closed" || !closed.Transfer.OutcomeUnknown || !closed.Transfer.Valid() {
		t.Fatal("closing an uncertain outcome erased it or broke the protocol")
	}
}
func TestTransferQuotaAndTamperedSpoolFailBeforeTargetMutation(t *testing.T) {
	target := &fakeDatabase{}
	m := manager(t, &fakeDatabase{}, target, 20)
	request := protocol.TransferRequest{Mode: "csv", Target: endpoint(), Headers: []string{"id"}, Rows: [][]protocol.CellValue{{text("1")}}, Columns: []protocol.TransferColumn{{SourceIndex: 0, Name: "id", Type: "integer"}}}
	response := m.Handle(protocol.Command{Type: "transfer.preview", RequestID: "quota", Transfer: &request})
	done := waitTransfer(t, m, response.Transfer.JobID)
	if done.State != "failed" || target.applies.Load() != 0 {
		t.Fatal("quota failure wrote target")
	}
	m2 := manager(t, &fakeDatabase{}, target, 0)
	response = m2.Handle(protocol.Command{Type: "transfer.preview", RequestID: "preview", Transfer: &request})
	ready := waitTransfer(t, m2, response.Transfer.JobID)
	j := m2.jobs[ready.JobID]
	j.mu.Lock()
	path := j.plan.path
	j.mu.Unlock()
	if os.WriteFile(path, []byte("changed\n"), 0600) != nil {
		t.Fatal("cannot mutate private fixture")
	}
	m2.Handle(protocol.Command{Type: "transfer.apply", RequestID: "apply", Transfer: &protocol.TransferRequest{JobID: ready.JobID, PlanDigest: ready.PlanDigest, Confirmed: true}})
	done = waitTransfer(t, m2, ready.JobID)
	if done.State != "failed" || target.applies.Load() != 0 {
		t.Fatal("changed immutable rows were applied")
	}
}

func TestTransferHeaderOnlyCSVCanCreateAnEmptyReviewedTable(t *testing.T) {
	target := &fakeDatabase{}
	m := manager(t, &fakeDatabase{}, target, 0)
	request := protocol.TransferRequest{Mode: "csv", Target: endpoint(), Headers: []string{"id"}, Rows: [][]protocol.CellValue{}}
	reply := m.Handle(protocol.Command{Type: "transfer.describe", RequestID: "describe", Transfer: &request})
	if reply.Transfer == nil {
		t.Fatal("header-only descriptor rejected")
	}
	described := waitTransfer(t, m, reply.Transfer.JobID)
	if described.State != "described" || len(described.Columns) != 1 || described.Columns[0].Type != "text" || !described.Columns[0].Nullable {
		t.Fatal("empty source invented a required or typed column")
	}
	request.Columns = described.Columns
	reply = m.Handle(protocol.Command{Type: "transfer.preview", RequestID: "preview", Transfer: &request})
	ready := waitTransfer(t, m, reply.Transfer.JobID)
	if ready.State != "ready" || ready.RowsRead != 0 {
		t.Fatal("empty source could not produce a reviewed CREATE")
	}
	m.Handle(protocol.Command{Type: "transfer.apply", RequestID: "apply", Transfer: &protocol.TransferRequest{JobID: ready.JobID, PlanDigest: ready.PlanDigest, Confirmed: true}})
	done := waitTransfer(t, m, ready.JobID)
	if done.State != "completed" || !done.TableCreated || done.RowsWritten != 0 {
		t.Fatal("header-only transfer did not create an empty table")
	}
}

type blockedCaptureDatabase struct {
	*fakeDatabase
	started chan struct{}
}

func (f *blockedCaptureDatabase) TransferCapture(ctx context.Context, _, _, _ string, consume func([]protocol.CellValue) error) (Description, error) {
	f.captures.Add(1)
	if err := consume([]protocol.CellValue{text("1")}); err != nil {
		return Description{}, err
	}
	close(f.started)
	<-ctx.Done()
	return Description{}, ctx.Err()
}

func TestTransferCancelReleasesPartialPrivateCaptureBeforeAnyApply(t *testing.T) {
	source := &blockedCaptureDatabase{fakeDatabase: &fakeDatabase{digest: Digest("schema")}, started: make(chan struct{})}
	target := &fakeDatabase{}
	m, err := New(func(_ context.Context, settings protocol.Connection) (adapter.Session, error) {
		if settings.Database == "source" {
			return source, nil
		}
		return target, nil
	}, Options{Root: t.TempDir()})
	if err != nil {
		t.Fatal("cannot create cancellation fixture")
	}
	t.Cleanup(m.Close)
	from := endpoint()
	from.Connection.Database = "source"
	request := protocol.TransferRequest{Mode: "table", Source: from, Target: endpoint(), SourceDigest: source.digest,
		Columns: []protocol.TransferColumn{{SourceIndex: 0, Name: "id", Type: "integer"}}}
	started := m.Handle(protocol.Command{Type: "transfer.preview", RequestID: "preview", Transfer: &request})
	if started.Transfer == nil {
		t.Fatal("cancellation fixture did not start")
	}
	select {
	case <-source.started:
	case <-time.After(3 * time.Second):
		t.Fatal("capture did not reach its cancellable operation")
	}
	if m.used.Load() == 0 {
		t.Fatal("fixture did not retain a partial private capture")
	}
	id := started.Transfer.JobID
	m.Handle(protocol.Command{Type: "transfer.cancel", RequestID: "cancel", Transfer: &protocol.TransferRequest{JobID: id}})
	terminal := waitTransfer(t, m, id)
	if terminal.State != "cancelled" || terminal.TableCreated || terminal.OutcomeUnknown || target.applies.Load() != 0 {
		t.Fatal("cancelled preparation reached the destination or lost its outcome")
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		_, statErr := os.Stat(filepath.Join(m.root, id))
		if m.used.Load() == 0 && errors.Is(statErr, os.ErrNotExist) {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("cancelled capture retained workspace bytes or files")
}

func TestTransferRetainedReadonlyPolicyAndDigestBlockWrites(t *testing.T) {
	target := &fakeDatabase{}
	m := manager(t, &fakeDatabase{}, target, 0)
	to := endpoint()
	to.Connection.Policy = &protocol.ExecutionPolicy{ReadOnly: true, Environment: "unspecified"}
	request := protocol.TransferRequest{Mode: "csv", Target: to, Headers: []string{"id"}, Rows: [][]protocol.CellValue{{text("1")}},
		Columns: []protocol.TransferColumn{{SourceIndex: 0, Name: "id", Type: "integer"}}}
	started := m.Handle(protocol.Command{Type: "transfer.preview", RequestID: "preview", Transfer: &request})
	if started.Transfer == nil {
		t.Fatal("readonly preview was rejected")
	}
	ready := waitTransfer(t, m, started.Transfer.JobID)
	if ready.State != "ready" {
		t.Fatal("readonly profile could not review the proposed table")
	}
	// The asynchronous plan owns its policy. Changing the caller's settings
	// after review must not convert an approved readonly plan into a write.
	request.Target.Connection.Policy.ReadOnly = false
	apply := protocol.TransferRequest{JobID: ready.JobID, PlanDigest: ready.PlanDigest, Confirmed: true}
	if m.Handle(protocol.Command{Type: "transfer.apply", RequestID: "apply", Transfer: &apply}).Type != "error" || target.applies.Load() != 0 {
		t.Fatal("retained readonly policy permitted a destination write")
	}
	request.Target = endpoint()
	started = m.Handle(protocol.Command{Type: "transfer.preview", RequestID: "fresh-preview", Transfer: &request})
	ready = waitTransfer(t, m, started.Transfer.JobID)
	apply.JobID, apply.PlanDigest = ready.JobID, Digest("another reviewed plan")
	if m.Handle(protocol.Command{Type: "transfer.apply", RequestID: "wrong-plan", Transfer: &apply}).Type != "error" || target.applies.Load() != 0 {
		t.Fatal("an unrelated plan digest authorized a destination write")
	}
}

func TestTransferChangedSourceMetadataIsRejectedBeforeCapture(t *testing.T) {
	source := &fakeDatabase{digest: Digest("current schema"), rows: 2}
	target := &fakeDatabase{}
	m := manager(t, source, target, 0)
	from := endpoint()
	from.Connection.Database = "source"
	request := protocol.TransferRequest{Mode: "table", Source: from, Target: endpoint(), SourceDigest: Digest("stale schema"),
		Columns: []protocol.TransferColumn{{SourceIndex: 0, Name: "id", Type: "integer"}}}
	started := m.Handle(protocol.Command{Type: "transfer.preview", RequestID: "preview", Transfer: &request})
	if started.Transfer == nil {
		t.Fatal("metadata fixture did not start")
	}
	terminal := waitTransfer(t, m, started.Transfer.JobID)
	if terminal.State != "failed" || source.captures.Load() != 0 || target.applies.Load() != 0 {
		t.Fatal("stale column indexes were used to capture or apply data")
	}
}
