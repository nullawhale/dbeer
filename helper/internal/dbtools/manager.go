// Package dbtools owns reviewed native utility plans and independently
// cancellable dump/restore jobs. Raw utility output never enters the protocol.
package dbtools

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/credential"
	"dbeer/helper/internal/exportfile"
	"dbeer/helper/internal/protocol"
)

type PreparedConnection struct {
	Connection     protocol.Connection
	Host, HostAddr string
	Port           int
	Close          func()
	Done           <-chan struct{}
}
type PrepareConnection func(context.Context, protocol.Connection) (PreparedConnection, error)
type Options struct {
	Root              string
	PrepareConnection PrepareConnection
	Deadline          time.Duration
}
type plan struct {
	id, approval, dir, input string
	request                  protocol.DatabaseToolsRequest
	connection               PreparedConnection
	tool                     *toolIdentity
	reply                    protocol.DatabaseToolsReply
	destination              protocol.ExportDestination
	created                  time.Time
	once                     sync.Once
}

func (p *plan) cleanup() {
	p.once.Do(func() {
		if p.connection.Close != nil {
			p.connection.Close()
		}
		p.connection.Connection.Password = ""
		_ = os.RemoveAll(p.dir)
	})
}

type job struct {
	id     string
	plan   *plan
	ctx    context.Context
	cancel context.CancelFunc
	done   chan struct{}
	count  atomic.Int64
	mu     sync.Mutex
	reply  protocol.DatabaseToolsReply
}
type Manager struct {
	mu        sync.Mutex
	root      string
	opener    adapter.OpenFunc
	options   Options
	ctx       context.Context
	cancel    context.CancelFunc
	plans     map[string]*plan
	jobs      map[string]*job
	preparing int
	closed    bool
	workers   sync.WaitGroup
}

func New(opener adapter.OpenFunc, options Options) (*Manager, error) {
	if opener == nil {
		return nil, errors.New("Database utility connections are unavailable.")
	}
	root, err := os.MkdirTemp(options.Root, "dbeer-dbtools-")
	if err != nil {
		return nil, errors.New("The private database utility workspace could not be created.")
	}
	if options.Deadline <= 0 {
		options.Deadline = 24 * time.Hour
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Manager{root: root, opener: opener, options: options, ctx: ctx, cancel: cancel, plans: map[string]*plan{}, jobs: map[string]*job{}}, nil
}
func (m *Manager) Close() {
	m.mu.Lock()
	if !m.closed {
		m.closed = true
		m.cancel()
		for _, j := range m.jobs {
			j.cancel()
		}
	}
	m.mu.Unlock()
	m.workers.Wait()
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, p := range m.plans {
		p.cleanup()
	}
	for _, j := range m.jobs {
		j.plan.cleanup()
	}
	_ = os.RemoveAll(m.root)
}
func token() (string, error) {
	var value [24]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(value[:]), nil
}
func failure(c protocol.Command, message string) protocol.Response {
	return protocol.ErrorResponse(c, "databaseTools", message)
}
func reply(c protocol.Command, value protocol.DatabaseToolsReply) protocol.Response {
	return protocol.Response{Type: c.Type + ".result", RequestID: c.RequestID, DatabaseTools: &value}
}
func (m *Manager) Handle(c protocol.Command) protocol.Response {
	r := c.DatabaseTools
	if r == nil || !r.Valid(c.Type) {
		return failure(c, "The database utility request is invalid.")
	}
	if c.Type == "dbtools.preview" {
		return m.preview(c, *r)
	}
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return failure(c, "Database utility operations are closed.")
	}
	if c.Type == "dbtools.start" {
		p := m.plans[r.PlanID]
		if p == nil || subtle.ConstantTimeCompare([]byte(p.approval), []byte(r.ApprovalToken)) != 1 || p.request.Operation == "restore" && !r.Confirmed || len(m.jobs) >= 2 {
			m.mu.Unlock()
			return failure(c, "The reviewed utility plan is unavailable or requires explicit confirmation.")
		}
		if time.Since(p.created) > 15*time.Minute {
			delete(m.plans, p.id)
			m.mu.Unlock()
			p.cleanup()
			return failure(c, "The utility preview expired. Preview this operation again before starting.")
		}
		delete(m.plans, p.id)
		id, err := token()
		if err != nil {
			m.mu.Unlock()
			p.cleanup()
			return failure(c, "The database utility job could not be created.")
		}
		ctx, cancel := context.WithTimeout(m.ctx, m.options.Deadline)
		initial := p.reply
		initial.PlanID, initial.ApprovalToken = "", ""
		initial.JobID = id
		initial.State, initial.Phase = "running", "starting"
		j := &job{id: id, plan: p, ctx: ctx, cancel: cancel, done: make(chan struct{}), reply: initial}
		m.jobs[id] = j
		m.workers.Add(1)
		go m.run(j)
		m.mu.Unlock()
		return reply(c, initial)
	}
	if c.Type == "dbtools.close" && r.PlanID != "" {
		p := m.plans[r.PlanID]
		if p == nil {
			m.mu.Unlock()
			return failure(c, "The reviewed utility plan is unavailable.")
		}
		delete(m.plans, p.id)
		m.mu.Unlock()
		p.cleanup()
		return reply(c, protocol.DatabaseToolsReply{PlanID: p.id, State: "closed", Phase: "closed", Warnings: []string{}})
	}
	j := m.jobs[r.JobID]
	if j == nil {
		m.mu.Unlock()
		return failure(c, "The database utility job is unavailable.")
	}
	if c.Type == "dbtools.cancel" || c.Type == "dbtools.close" {
		j.cancel()
	}
	if c.Type == "dbtools.close" {
		delete(m.jobs, j.id)
		m.mu.Unlock()
		<-j.done
		j.plan.cleanup()
		return reply(c, protocol.DatabaseToolsReply{JobID: j.id, State: "closed", Phase: "closed", Warnings: []string{}})
	}
	m.mu.Unlock()
	j.mu.Lock()
	out := j.reply
	if out.BytesProcessed != nil {
		value := j.count.Load()
		out.BytesProcessed = &value
	}
	j.mu.Unlock()
	return reply(c, out)
}
func (m *Manager) preview(c protocol.Command, r protocol.DatabaseToolsRequest) protocol.Response {
	m.mu.Lock()
	if m.closed || len(m.plans)+len(m.jobs)+m.preparing >= 4 {
		m.mu.Unlock()
		return failure(c, "Close an existing database utility operation before preparing another.")
	}
	m.preparing++
	m.workers.Add(1)
	m.mu.Unlock()
	defer func() { m.mu.Lock(); m.preparing--; m.mu.Unlock(); m.workers.Done() }()
	p, err := m.prepare(m.ctx, r)
	if err != nil {
		return failure(c, safeMessage(err))
	}
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		p.cleanup()
		return failure(c, "Database utility preparation was cancelled.")
	}
	m.plans[p.id] = p
	m.mu.Unlock()
	return reply(c, p.reply)
}
func safeMessage(err error) string {
	var known *safeError
	if errors.As(err, &known) {
		return known.message
	}
	if errors.Is(err, errTool) {
		return errTool.Error()
	}
	return "The database utility could not be prepared. Check the selected file, utility, credentials and server availability."
}

type safeError struct{ message string }

func (e *safeError) Error() string { return e.message }
func safe(message string) error    { return &safeError{message} }
func (m *Manager) prepare(ctx context.Context, r protocol.DatabaseToolsRequest) (p *plan, err error) {
	if r.Operation == "restore" && r.Connection.Policy != nil && r.Connection.Policy.ReadOnly {
		return nil, safe("Restore is unavailable for readonly connections.")
	}
	id, err := token()
	if err != nil {
		return nil, err
	}
	approval, err := token()
	if err != nil {
		return nil, err
	}
	dir := filepath.Join(m.root, id)
	if os.Mkdir(dir, 0700) != nil {
		return nil, errors.New("workspace")
	}
	p = &plan{id: id, approval: approval, dir: dir, request: r}
	owned := p
	defer func() {
		if err != nil {
			owned.cleanup()
		}
	}()
	prepare := m.options.PrepareConnection
	if prepare == nil {
		prepare = func(ctx context.Context, c protocol.Connection) (PreparedConnection, error) {
			if c.SSH != nil {
				return PreparedConnection{}, safe("SSH database utility transport is unavailable.")
			}
			password, err := credential.Password(ctx, c)
			if err != nil {
				return PreparedConnection{}, err
			}
			c.Password, c.PasswordCommand = password, nil
			return PreparedConnection{Connection: c, Host: c.Host, Port: c.Port}, nil
		}
	}
	p.connection, err = prepare(ctx, *r.Connection)
	if err != nil {
		return nil, err
	}
	p.request.Connection = nil
	engine := p.connection.Connection.DatabaseEngine()
	name := expectedTool(engine, r.Operation, r.Format)
	p.tool, err = captureTool(r.ToolPath, name)
	if err != nil {
		return nil, err
	}
	version, err := probeTool(ctx, p.tool, engine, dir)
	if err != nil {
		return nil, err
	}
	probeCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	physical, err := m.opener(probeCtx, p.connection.Connection)
	cancel()
	if err != nil {
		return nil, err
	}
	defer physical.Close()
	metadata, ok := physical.(interface{ DatabaseToolsServerVersion() string })
	if !ok {
		return nil, safe("The database adapter cannot report a utility-compatible server version.")
	}
	server := metadata.DatabaseToolsServerVersion()
	if e := compatible(engine, version, server); e != nil {
		return nil, safe(e.Error())
	}
	if r.Operation == "restore" && engine == "postgresql" && r.Format == "sql" && !supportsRestrict(version) {
		return nil, safe("Plain SQL restore requires psql 16.10, 17.6 or later with restricted client-command support.")
	}
	warnings := []string{}
	if r.Operation == "restore" {
		warnings = append(warnings, "Restore executes database code from the selected file. Use a trusted backup and verify the selected target.", "Existing objects represented in this backup will be replaced. No database is created or dropped automatically.", "A cancelled or failed restore may have changed database objects. Inspect the target before another restore.")
		p.input, err = freezeInput(ctx, r.Path, dir, engine == "postgresql" && r.Format == "sql")
		if err != nil {
			return nil, err
		}
		if engine == "postgresql" && r.Format != "sql" {
			if err = verifyArchive(ctx, p, server); err != nil {
				return nil, err
			}
		}
	} else {
		p.destination, err = exportfile.CaptureDestination(r.Path)
		if err != nil {
			return nil, err
		}
		if p.destination.Exists {
			warnings = append(warnings, "The reviewed existing destination will be replaced only after the dump completes successfully.")
		}
		if engine == "mysql" {
			warnings = append(warnings, "MySQL single-transaction dumps are consistent for InnoDB; concurrent DDL and nontransactional tables require separate coordination.")
		}
	}
	// Validate TLS translation and credential representation before approval.
	if _, _, e := utilityArguments(p.request, p.connection, dir); e != nil {
		return nil, safe(e.Error())
	}
	p.reply = protocol.DatabaseToolsReply{PlanID: id, ApprovalToken: approval, State: "prepared", Phase: "ready", Engine: engine, Operation: r.Operation, Format: r.Format, Database: r.Connection.Database, Path: r.Path, ToolName: name, ToolVersion: version.text, ServerVersion: server, RequiresConfirmation: r.Operation == "restore", Warnings: warnings}
	if !p.reply.Valid("dbtools.preview.result") {
		return nil, safe("The database utility returned incompatible or malformed version metadata.")
	}
	if p.connection.Done != nil {
		select {
		case <-p.connection.Done:
			return nil, safe("The SSH transport ended while preparing this operation.")
		default:
		}
	}
	p.created = time.Now()
	return p, nil
}
func (m *Manager) run(j *job) {
	defer m.workers.Done()
	defer close(j.done)
	defer j.plan.cleanup()
	defer j.cancel()
	p := j.plan
	finish := func(state, message string, exit *int, published bool) {
		j.mu.Lock()
		defer j.mu.Unlock()
		j.reply.State, j.reply.Phase, j.reply.Message, j.reply.ExitCode, j.reply.OutputPublished = state, state, message, exit, published
		if j.reply.BytesProcessed != nil {
			value := j.count.Load()
			j.reply.BytesProcessed = &value
		}
	}
	if j.ctx.Err() != nil {
		finish("cancelled", "The utility was cancelled before starting.", nil, false)
		return
	}
	if !p.tool.valid() {
		finish("failed", errTool.Error(), nil, false)
		return
	}
	args, env, err := utilityArguments(p.request, p.connection, p.dir)
	if err != nil {
		finish("failed", safeMessage(err), nil, false)
		return
	}
	ctx, cancel := context.WithCancel(j.ctx)
	defer cancel()
	if p.connection.Done != nil {
		go func() {
			select {
			case <-p.connection.Done:
				cancel()
			case <-ctx.Done():
			}
		}()
	}
	var input io.ReadCloser
	var output *exportfile.BinaryWriter
	phase := "dumping"
	if p.request.Operation == "restore" {
		phase = "restoring"
		input, err = os.Open(p.input)
		if err == nil {
			info, e := input.(*os.File).Stat()
			err = e
			if e == nil {
				size := info.Size()
				j.mu.Lock()
				j.reply.TotalBytes = &size
				j.mu.Unlock()
			}
		}
		if input != nil {
			defer input.Close()
		}
	} else {
		output, err = exportfile.NewBinaryWriter(p.request.Path, p.destination)
		if output != nil {
			defer output.Abort()
		}
	}
	if err != nil {
		finish("failed", "The reviewed backup file or destination changed or is unavailable. Preview again.", nil, false)
		return
	}
	j.mu.Lock()
	zero := int64(0)
	j.reply.Phase, j.reply.BytesProcessed = phase, &zero
	j.mu.Unlock()
	var reader io.Reader
	var writer io.Writer = io.Discard
	if input != nil {
		reader = countingReader{in: input, count: &j.count, ctx: ctx}
	}
	if output != nil {
		writer = countingWriter{out: output, count: &j.count}
	}
	code, runErr := process(ctx, p.tool.path, args, env, reader, writer)
	var codePtr *int
	if code >= 0 && code <= 255 {
		codePtr = &code
	}
	if runErr != nil || ctx.Err() != nil {
		if phase == "restoring" && code >= 0 {
			finish("outcomeUnknown", "Restore was interrupted or failed. Database changes may have been applied; inspect the target before trying again.", codePtr, false)
		} else if ctx.Err() != nil {
			finish("cancelled", "The dump was cancelled before publishing its destination.", codePtr, false)
		} else {
			finish("failed", "The database utility failed. Check utility compatibility, database privileges and available disk space.", codePtr, false)
		}
		return
	}
	if output != nil {
		j.mu.Lock()
		j.reply.Phase = "publishing"
		j.mu.Unlock()
		if err = output.Publish(ctx); err != nil {
			if errors.Is(err, exportfile.ErrPublicationUnknown) {
				finish("outcomeUnknown", "Dump publication could not be verified. Inspect the destination before retrying.", codePtr, false)
			} else if ctx.Err() != nil {
				finish("cancelled", "The dump was cancelled before publication.", codePtr, false)
			} else {
				finish("failed", "The reviewed dump destination changed or could not be published. The completed temporary dump was not retained.", codePtr, false)
			}
			return
		}
	}
	finish("completed", "The database utility completed successfully.", codePtr, output != nil)
}
