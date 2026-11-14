package datatransfer

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type Options struct {
	Root       string
	QuotaBytes int64
	Timeout    time.Duration
}
type plan struct {
	target         protocol.TransferEndpoint
	columns        []protocol.TransferColumn
	digest         string
	rows           int64
	path           string
	contentDigest  string
	targetIdentity string
}
type job struct {
	id, dir string
	ctx     context.Context
	cancel  context.CancelFunc
	mu      sync.Mutex
	reply   protocol.TransferReply
	plan    *plan
	active  bool
	closed  bool
	bytes   int64
}
type Manager struct {
	mu        sync.Mutex
	jobs      map[string]*job
	open      adapter.OpenFunc
	root      string
	options   Options
	used      atomic.Int64
	workers   sync.WaitGroup
	closed    bool
	closeDone chan struct{}
}

func New(open adapter.OpenFunc, options Options) (*Manager, error) {
	if open == nil {
		return nil, ErrInvalid
	}
	if options.QuotaBytes <= 0 || options.QuotaBytes > DefaultQuotaBytes {
		options.QuotaBytes = DefaultQuotaBytes
	}
	if options.Timeout <= 0 {
		options.Timeout = 15 * time.Minute
	}
	root, err := os.MkdirTemp(options.Root, "dbeer-transfer-")
	if err != nil {
		return nil, err
	}
	if err = os.Chmod(root, 0700); err != nil {
		os.RemoveAll(root)
		return nil, err
	}
	return &Manager{jobs: map[string]*job{}, open: open, root: root, options: options, closeDone: make(chan struct{})}, nil
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
	}
	m.mu.Unlock()
	m.workers.Wait()
	os.RemoveAll(m.root)
	close(m.closeDone)
}
func safeError(err error) string {
	for _, known := range []error{ErrInvalid, ErrChanged, ErrExists, ErrQuota} {
		if errors.Is(err, known) {
			return known.Error()
		}
	}
	if errors.Is(err, context.Canceled) {
		return "The transfer was cancelled."
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "The transfer exceeded its time limit."
	}
	return "The transfer could not be completed. Check the connection, permissions and reviewed column types."
}
func (m *Manager) response(c protocol.Command, j *job) protocol.Response {
	j.mu.Lock()
	defer j.mu.Unlock()
	copy := j.reply
	// A reviewed result is not actionable until all preparation connections
	// and files have finished cleanup. Never publish ready while apply is busy.
	if j.active && (copy.State == "ready" || copy.State == "described") {
		copy.State = "running"
		copy.Phase = "finishing"
	}
	copy.Columns = append([]protocol.TransferColumn(nil), copy.Columns...)
	copy.Diagnostics = append([]protocol.TransferDiagnostic(nil), copy.Diagnostics...)
	copy.Notices = []string{}
	seen := map[string]bool{}
	for _, notice := range j.reply.Notices {
		if !seen[notice] {
			if len(copy.Notices) == 31 {
				copy.Notices = append(copy.Notices, "Additional transfer notices were omitted from this bounded reply.")
				break
			}
			copy.Notices = append(copy.Notices, notice)
			seen[notice] = true
		}
	}
	return protocol.Response{Type: c.Type + ".result", RequestID: c.RequestID, Transfer: &copy}
}
func transferFailure(c protocol.Command) protocol.Response {
	return protocol.ErrorResponse(c, "dataTransfer", "The transfer request is unavailable or invalid.")
}
func (m *Manager) Handle(c protocol.Command) protocol.Response {
	r := c.Transfer
	if r == nil || !r.Valid(c.Type) {
		return transferFailure(c)
	}
	// Asynchronous workers own a deep copy, including mapping and cell slices.
	ownedBytes, err := json.Marshal(r)
	if err != nil {
		return transferFailure(c)
	}
	var owned protocol.TransferRequest
	if json.Unmarshal(ownedBytes, &owned) != nil {
		return transferFailure(c)
	}
	r = &owned
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return transferFailure(c)
	}
	if c.Type == "transfer.describe" || c.Type == "transfer.preview" {
		if len(m.jobs) >= 4 {
			m.mu.Unlock()
			return protocol.ErrorResponse(c, "busy", "Close an existing transfer before preparing another.")
		}
		var random [16]byte
		if _, err := rand.Read(random[:]); err != nil {
			m.mu.Unlock()
			return transferFailure(c)
		}
		id := hex.EncodeToString(random[:])
		dir := filepath.Join(m.root, id)
		if os.Mkdir(dir, 0700) != nil {
			m.mu.Unlock()
			return transferFailure(c)
		}
		ctx, cancel := context.WithCancel(context.Background())
		j := &job{id: id, dir: dir, ctx: ctx, cancel: cancel, active: true, reply: protocol.TransferReply{JobID: id, State: "pending", Phase: "preparing", Notices: []string{OmissionNotice(), "The private transfer workspace is limited to 4 GiB; no displayed-row limit is used for table copying."}}}
		m.jobs[id] = j
		m.workers.Add(1)
		go m.prepare(j, *r, c.Type == "transfer.describe")
		m.mu.Unlock()
		return m.response(c, j)
	}
	j := m.jobs[r.JobID]
	if j == nil {
		m.mu.Unlock()
		return transferFailure(c)
	}
	switch c.Type {
	case "transfer.status":
		m.mu.Unlock()
		return m.response(c, j)
	case "transfer.cancel", "transfer.close":
		j.cancel()
		j.mu.Lock()
		if c.Type == "transfer.close" {
			j.closed = true
		}
		active := j.active
		if !active {
			if c.Type == "transfer.close" {
				j.reply.State = "closed"
			} else if j.reply.State == "ready" || j.reply.State == "described" {
				j.reply.State = "cancelled"
			}
			j.plan = nil
		}
		j.mu.Unlock()
		if !active {
			m.cleanup(j)
			if c.Type == "transfer.close" {
				delete(m.jobs, j.id)
			}
		}
		m.mu.Unlock()
		return m.response(c, j)
	case "transfer.apply":
		j.mu.Lock()
		if j.active || j.closed || j.reply.State != "ready" || j.plan == nil || j.plan.digest != r.PlanDigest || !r.Confirmed || j.plan.target.Connection.Policy != nil && j.plan.target.Connection.Policy.ReadOnly {
			j.mu.Unlock()
			m.mu.Unlock()
			return transferFailure(c)
		}
		p := j.plan
		j.plan = nil
		j.active = true
		j.reply.State, j.reply.Phase = "running", "creating"
		j.mu.Unlock()
		m.workers.Add(1)
		go m.apply(j, p)
		m.mu.Unlock()
		return m.response(c, j)
	default:
		m.mu.Unlock()
		return transferFailure(c)
	}
}
func (m *Manager) cleanup(j *job) {
	if j.bytes > 0 {
		m.used.Add(-j.bytes)
		j.bytes = 0
	}
	os.RemoveAll(j.dir)
}
func (m *Manager) finished(j *job, err error) {
	j.mu.Lock()
	j.active = false
	if err == nil && j.ctx.Err() != nil && j.reply.State != "completed" && j.reply.State != "outcomeUnknown" {
		err = j.ctx.Err()
	}
	if err != nil && j.reply.State != "outcomeUnknown" {
		j.reply.State = "failed"
		j.reply.Code = "transfer"
		if errors.Is(err, context.Canceled) {
			j.reply.State = "cancelled"
			j.reply.Code = "cancelled"
		}
		j.reply.Message = safeError(err)
	}
	closed := j.closed
	if closed {
		j.reply.State = "closed"
	}
	terminal := closed || j.reply.State == "failed" || j.reply.State == "cancelled" || j.reply.State == "completed" || j.reply.State == "outcomeUnknown"
	if terminal {
		j.plan = nil
	}
	j.mu.Unlock()
	if terminal {
		m.mu.Lock()
		m.cleanup(j)
		if closed {
			delete(m.jobs, j.id)
		}
		m.mu.Unlock()
	}
}
func (m *Manager) openDatabase(ctx context.Context, endpoint protocol.TransferEndpoint, readonly bool) (adapter.Session, Database, error) {
	settings := endpoint.Connection
	policy := protocol.ExecutionPolicy{Environment: "unspecified"}
	if settings.Policy != nil {
		policy = *settings.Policy
	}
	if readonly {
		policy.ReadOnly = true
	}
	settings.Policy = &policy
	opening, stop := context.WithTimeout(ctx, 45*time.Second)
	session, err := m.open(opening, settings)
	stop()
	if err != nil {
		if session != nil {
			session.Close()
		}
		return nil, nil, err
	}
	database, ok := session.(Database)
	if !ok {
		session.Close()
		return nil, nil, ErrInvalid
	}
	if readonly {
		mode, ok := session.(adapter.ReadOnlySession)
		if !ok {
			session.Close()
			return nil, nil, ErrInvalid
		}
		if err = mode.SetReadOnly(ctx, true); err != nil {
			session.Close()
			return nil, nil, err
		}
	}
	return session, database, nil
}
func (m *Manager) prepare(j *job, r protocol.TransferRequest, describe bool) {
	defer m.workers.Done()
	ctx, cancel := context.WithTimeout(j.ctx, m.options.Timeout)
	defer cancel()
	var finalErr error
	defer func() { m.finished(j, finalErr) }()
	j.mu.Lock()
	j.reply.State = "running"
	j.reply.Phase = "describing"
	j.mu.Unlock()
	columns := r.Columns
	description := Description{}
	if r.Mode == "csv" {
		if describe {
			columns, _ = Infer(r.Headers, r.Rows, r.Target.Connection.DatabaseEngine())
		}
	} else {
		session, database, err := m.openDatabase(ctx, *r.Source, true)
		if err != nil {
			finalErr = err
			return
		}
		defer session.Close()
		description, err = database.TransferDescribe(ctx, r.Source.Schema, r.Source.Table)
		if err != nil {
			finalErr = err
			return
		}
		if describe {
			columns = description.Columns
		} else if description.Digest != r.SourceDigest {
			finalErr = ErrChanged
			return
		}
	}
	j.mu.Lock()
	j.reply.Columns = columns
	j.reply.SourceDigest = description.Digest
	j.reply.Notices = append(j.reply.Notices, description.Notices...)
	if r.Target.Connection.DatabaseEngine() == "mariadb" {
		j.reply.Notices = append(j.reply.Notices, "MariaDB commits CREATE TABLE separately from inserted rows. Cancellation or failure can leave the known created destination table; inspect uncertain outcomes before retrying.")
	}
	if r.Target.Connection.DatabaseEngine() == "mysql" {
		j.reply.Notices = append(j.reply.Notices, "MySQL commits CREATE TABLE separately from inserted rows. A cancelled or failed transfer can leave an empty destination table; uncertain outcomes require inspecting that table before retrying.")
	}
	if r.Mode == "csv" {
		j.reply.Notices = append(j.reply.Notices, "Numeric, boolean and temporal destination types use canonical value representations. Choose TEXT when the original CSV spelling is significant.")
	}
	if r.Target.Connection.DatabaseEngine() == "mariadb" {
		for _, column := range columns {
			if column.Type == "timestampTZ" {
				j.reply.Notices = append(j.reply.Notices, "Zoned timestamps are transferred to native UTC DATETIME(6) values; source session-dependent TIMESTAMP behavior is not cloned.")
				break
			}
		}
		for _, column := range columns {
			if column.Type == "json" {
				j.reply.Notices = append(j.reply.Notices, "MariaDB JSON transfer destinations retain reviewed text bytes, duplicate keys and whitespace; future writes are not constrained by a cloned JSON property.")
				break
			}
		}
	}
	for _, column := range columns {
		if column.Type == "timestampTZ" && r.Target.Connection.DatabaseEngine() == "mysql" {
			j.reply.Notices = append(j.reply.Notices, "Zoned timestamps are stored as UTC DATETIME(6) values in MySQL; session-dependent TIMESTAMP conversion behavior is not cloned.")
			break
		}
	}
	for _, column := range columns {
		if column.Type == "json" && r.Target.Connection.DatabaseEngine() == "mysql" {
			j.reply.Notices = append(j.reply.Notices, "MySQL JSON destinations use LONGTEXT validated before transfer, preserving exact JSON spelling and numeric values. Future writes are not constrained to JSON.")
			break
		}
	}
	j.mu.Unlock()
	if err := ValidateColumns(columns, r.Target.Connection.DatabaseEngine()); err != nil {
		finalErr = err
		return
	}
	if describe {
		j.mu.Lock()
		j.reply.State = "described"
		j.reply.Phase = "complete"
		j.mu.Unlock()
		return
	}
	session, target, err := m.openDatabase(ctx, *r.Target, true)
	if err != nil {
		finalErr = err
		return
	}
	defer session.Close()
	statement, identity, err := target.TransferPreview(ctx, r.Target.Schema, r.Target.Table, columns)
	if err != nil {
		finalErr = err
		return
	}
	path := filepath.Join(j.dir, "rows.ndjson")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		finalErr = err
		return
	}
	defer file.Close()
	hasher := sha256.New()
	writer := bufio.NewWriterSize(io.MultiWriter(file, hasher), 256<<10)
	var count int64
	diagnostics := []protocol.TransferDiagnostic{}
	consume := func(row []protocol.CellValue) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		count++
		if count%1000 == 0 {
			j.mu.Lock()
			j.reply.RowsRead = count
			j.mu.Unlock()
		}
		mapped, column, err := MapRow(row, columns, r.Target.Connection.DatabaseEngine())
		if err != nil {
			if len(diagnostics) < protocol.MaxTransferDiagnostics {
				diagnostics = append(diagnostics, protocol.TransferDiagnostic{Row: int(count), Column: column + 1, Message: "The value cannot be represented by the selected type or nullability."})
			}
			return nil
		}
		data, err := json.Marshal(mapped)
		if err != nil || len(data) > MaxRowBytes {
			return ErrInvalid
		}
		amount := int64(len(data) + 1)
		if m.used.Add(amount) > m.options.QuotaBytes {
			m.used.Add(-amount)
			return ErrQuota
		}
		j.bytes += amount
		if _, err = writer.Write(data); err == nil {
			err = writer.WriteByte('\n')
		}
		if err != nil {
			return err
		}
		if count%1000 == 0 {
			j.mu.Lock()
			j.reply.RowsRead = count
			j.mu.Unlock()
		}
		return nil
	}
	j.mu.Lock()
	j.reply.Phase = "capturing"
	j.mu.Unlock()
	if r.Mode == "csv" {
		for _, row := range r.Rows {
			if err = consume(row); err != nil {
				break
			}
		}
	} else {
		sourceSession, source, openErr := m.openDatabase(ctx, *r.Source, true)
		if openErr != nil {
			finalErr = openErr
			return
		}
		defer sourceSession.Close()
		_, err = source.TransferCapture(ctx, r.Source.Schema, r.Source.Table, r.SourceDigest, consume)
	}
	if err == nil {
		err = writer.Flush()
	}
	if err == nil {
		err = file.Sync()
	}
	if err != nil {
		finalErr = err
		return
	}
	if len(diagnostics) > 0 {
		j.mu.Lock()
		j.reply.RowsRead = count
		j.reply.Diagnostics = diagnostics
		j.mu.Unlock()
		finalErr = ErrInvalid
		return
	}
	contentDigest := hex.EncodeToString(hasher.Sum(nil))
	digest := Digest(struct {
		TargetEngine, Schema, Table, SourceDigest string
		ContentDigest, TargetIdentity             string
		Columns                                   []protocol.TransferColumn
		Rows                                      int64
		Nonce                                     string
	}{r.Target.Connection.DatabaseEngine(), r.Target.Schema, r.Target.Table, description.Digest, contentDigest, identity, columns, count, j.id})
	j.mu.Lock()
	j.plan = &plan{target: *r.Target, columns: columns, digest: digest, rows: count, path: path, contentDigest: contentDigest, targetIdentity: identity}
	j.reply.State, j.reply.Phase = "ready", "review"
	j.reply.SQL = statement
	j.reply.PlanDigest = digest
	j.reply.RowsRead = count
	j.mu.Unlock()
}
func (m *Manager) apply(j *job, p *plan) {
	defer m.workers.Done()
	ctx, cancel := context.WithTimeout(j.ctx, m.options.Timeout)
	defer cancel()
	var finalErr error
	defer func() { m.finished(j, finalErr) }()
	file, err := os.Open(p.path)
	if err != nil {
		finalErr = err
		return
	}
	defer file.Close()
	hasher := sha256.New()
	if _, err = io.Copy(hasher, transferContextReader{ctx, file}); err != nil {
		finalErr = err
		return
	}
	if hex.EncodeToString(hasher.Sum(nil)) != p.contentDigest {
		finalErr = ErrChanged
		return
	}
	if _, err = file.Seek(0, io.SeekStart); err != nil {
		finalErr = err
		return
	}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64<<10), MaxRowBytes+1)
	read := func() ([]protocol.CellValue, error) {
		if !scanner.Scan() {
			if err := scanner.Err(); err != nil {
				return nil, err
			}
			return nil, io.EOF
		}
		line := scanner.Bytes()
		var row []protocol.CellValue
		if json.Unmarshal(line, &row) != nil || len(row) != len(p.columns) {
			return nil, ErrInvalid
		}
		return row, nil
	}
	session, database, err := m.openDatabase(ctx, p.target, false)
	if err != nil {
		finalErr = err
		return
	}
	defer session.Close()
	result, err := database.TransferApply(ctx, p.target.Schema, p.target.Table, p.targetIdentity, p.columns, read, func(count int64) {
		j.mu.Lock()
		j.reply.Phase = "inserting"
		j.reply.RowsWritten = count
		j.mu.Unlock()
	})
	j.mu.Lock()
	j.reply.TableCreated = result.TableCreated
	j.reply.RowsWritten = result.Rows
	j.reply.OutcomeUnknown = result.OutcomeUnknown
	if result.OutcomeUnknown {
		j.reply.State = "outcomeUnknown"
		j.reply.Message = "The destination outcome is unknown. Verify the new table before starting another transfer."
	} else if err == nil {
		j.reply.State = "completed"
		j.reply.Phase = "complete"
		j.reply.RowsWritten = result.Rows
	}
	j.mu.Unlock()
	finalErr = err
	if err == nil && result.Rows != p.rows {
		finalErr = ErrInvalid
	}
}

type transferContextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r transferContextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(p)
}
