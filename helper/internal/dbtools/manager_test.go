package dbtools

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func TestMain(m *testing.M) {
	if len(os.Args) == 4 && os.Args[1] == "--dbtools-parent-fixture" {
		_, _ = process(context.Background(), os.Args[2], nil, baseEnvironment(os.Args[3]), nil, io.Discard)
		os.Exit(0)
	}
	if handled, err := RunUtility(os.Args[1:]); handled {
		os.Exit(UtilityExitCode(err))
	}
	os.Exit(m.Run())
}

type fakeSession struct{}

func (*fakeSession) Execute(context.Context, protocol.Command) protocol.Response {
	panic("database tools must not execute user SQL")
}
func (*fakeSession) Close()                             {}
func (*fakeSession) TransactionStatus() string          { return "idle" }
func (*fakeSession) DatabaseToolsServerVersion() string { return "17.6" }
func connection() protocol.Connection {
	return protocol.Connection{Engine: "postgresql", Host: "fixture.invalid", Port: 5432, Database: "fixture", User: "reader", Password: "synthetic-password", SSLMode: "disable"}
}
func fakeUtility(t *testing.T, name, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	script := "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo '" + name + " (PostgreSQL) 17.6'; exit 0; fi\nif [ \"$1\" = \"--list\" ]; then printf '; Format: CUSTOM\\n; Dumped from database version: 17.6\\n'; exit 0; fi\n" + body + "\n"
	if os.WriteFile(path, []byte(script), 0700) != nil {
		t.Fatal("cannot create fake utility")
	}
	return path
}
func manager(t *testing.T) *Manager {
	t.Helper()
	m, err := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return &fakeSession{}, nil }, Options{Root: t.TempDir()})
	if err != nil {
		t.Fatal("cannot create utility manager")
	}
	t.Cleanup(m.Close)
	return m
}
func preview(t *testing.T, m *Manager, operation, format, path, tool string) protocol.DatabaseToolsReply {
	t.Helper()
	c := connection()
	r := m.Handle(protocol.Command{Type: "dbtools.preview", RequestID: "preview", DatabaseTools: &protocol.DatabaseToolsRequest{Connection: &c, Operation: operation, Format: format, Path: path, ToolPath: tool}})
	if r.Type != "dbtools.preview.result" || r.DatabaseTools == nil || !r.DatabaseTools.Valid(r.Type) {
		t.Fatalf("preview failed: category=%s message=%s", r.Category, r.Message)
	}
	return *r.DatabaseTools
}
func start(t *testing.T, m *Manager, p protocol.DatabaseToolsReply) protocol.DatabaseToolsReply {
	t.Helper()
	r := m.Handle(protocol.Command{Type: "dbtools.start", RequestID: "start", DatabaseTools: &protocol.DatabaseToolsRequest{PlanID: p.PlanID, ApprovalToken: p.ApprovalToken, Confirmed: p.RequiresConfirmation}})
	if r.DatabaseTools == nil || !r.DatabaseTools.Valid(r.Type) {
		t.Fatal("reviewed job did not start")
	}
	return *r.DatabaseTools
}
func await(t *testing.T, m *Manager, j protocol.DatabaseToolsReply) protocol.DatabaseToolsReply {
	t.Helper()
	deadline := time.Now().Add(6 * time.Second)
	for time.Now().Before(deadline) {
		r := m.Handle(protocol.Command{Type: "dbtools.status", RequestID: "status", DatabaseTools: &protocol.DatabaseToolsRequest{JobID: j.JobID}})
		if r.DatabaseTools == nil || !r.DatabaseTools.Valid(r.Type) {
			t.Fatal("invalid job status")
		}
		if r.DatabaseTools.State != "running" {
			return *r.DatabaseTools
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("utility job did not finish")
	return protocol.DatabaseToolsReply{}
}

func TestDatabaseToolsDumpPublishesOnlyReviewedDestination(t *testing.T) {
	m := manager(t)
	tool := fakeUtility(t, "pg_dump", "printf 'private-dump-bytes'")
	path := filepath.Join(t.TempDir(), "backup.dump")
	p := preview(t, m, "dump", "custom", path, tool)
	j := start(t, m, p)
	done := await(t, m, j)
	if done.State != "completed" || !done.OutputPublished || done.BytesProcessed == nil || *done.BytesProcessed != 18 {
		t.Fatal("dump was not authoritatively published")
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "private-dump-bytes" {
		t.Fatal("dump output changed")
	}
	if _, err := json.Marshal(protocol.Response{Type: "dbtools.status.result", RequestID: "status", DatabaseTools: &done}); err != nil {
		t.Fatal("job status did not serialize")
	}
	p = preview(t, m, "dump", "custom", path, tool)
	if os.WriteFile(path, []byte("external-edit"), 0600) != nil {
		t.Fatal("cannot change destination fixture")
	}
	done = await(t, m, start(t, m, p))
	data, _ = os.ReadFile(path)
	if done.State != "failed" || string(data) != "external-edit" {
		t.Fatal("changed destination was overwritten")
	}
}
func TestDatabaseToolsRestoreUsesFrozenFileAndRequiresConfirmation(t *testing.T) {
	m := manager(t)
	dir := t.TempDir()
	observed := filepath.Join(dir, "observed")
	tool := fakeUtility(t, "pg_restore", "cat > '"+observed+"'")
	source := filepath.Join(dir, "input.dump")
	os.WriteFile(source, []byte("PGDMPoriginal-reviewed-bytes"), 0600)
	p := preview(t, m, "restore", "custom", source, tool)
	r := m.Handle(protocol.Command{Type: "dbtools.start", RequestID: "denied", DatabaseTools: &protocol.DatabaseToolsRequest{PlanID: p.PlanID, ApprovalToken: p.ApprovalToken}})
	if r.Type != "error" {
		t.Fatal("restore started without explicit confirmation")
	}
	os.WriteFile(source, []byte("different-unreviewed-bytes"), 0600)
	done := await(t, m, start(t, m, p))
	data, _ := os.ReadFile(observed)
	if done.State != "completed" || string(data) != "PGDMPoriginal-reviewed-bytes" {
		t.Fatal("restore input changed after preview")
	}
	r = m.Handle(protocol.Command{Type: "dbtools.start", RequestID: "replay", DatabaseTools: &protocol.DatabaseToolsRequest{PlanID: p.PlanID, ApprovalToken: p.ApprovalToken, Confirmed: true}})
	if r.Type != "error" {
		t.Fatal("review token was reusable")
	}
}
func TestDatabaseToolsReadonlyAndToolMutationArePreflightFailures(t *testing.T) {
	m := manager(t)
	c := connection()
	c.Policy = &protocol.ExecutionPolicy{ReadOnly: true}
	tool := fakeUtility(t, "pg_restore", "exit 0")
	path := filepath.Join(t.TempDir(), "input.dump")
	os.WriteFile(path, []byte("PGDMPreviewed"), 0600)
	r := m.Handle(protocol.Command{Type: "dbtools.preview", RequestID: "readonly", DatabaseTools: &protocol.DatabaseToolsRequest{Connection: &c, Operation: "restore", Format: "custom", Path: path, ToolPath: tool}})
	if r.Type != "error" {
		t.Fatal("readonly restore was permitted")
	}
	p := preview(t, m, "restore", "custom", path, tool)
	os.WriteFile(tool, []byte("#!/bin/sh\nexit 0\n"), 0700)
	done := await(t, m, start(t, m, p))
	if done.State != "failed" {
		t.Fatal("changed executable was invoked")
	}
}
func TestDatabaseToolsCancelDoesNotPublishAndRestoreRemainsUncertain(t *testing.T) {
	for _, operation := range []string{"dump", "restore"} {
		t.Run(operation, func(t *testing.T) {
			m := manager(t)
			name := "pg_dump"
			if operation == "restore" {
				name = "pg_restore"
			}
			tool := fakeUtility(t, name, "trap 'exit 9' TERM\nsleep 30 &\nwait")
			path := filepath.Join(t.TempDir(), "file.dump")
			if operation == "restore" {
				os.WriteFile(path, []byte("PGDMPdata"), 0600)
			}
			p := preview(t, m, operation, "custom", path, tool)
			j := start(t, m, p)
			time.Sleep(100 * time.Millisecond)
			m.Handle(protocol.Command{Type: "dbtools.cancel", RequestID: "cancel", DatabaseTools: &protocol.DatabaseToolsRequest{JobID: j.JobID}})
			done := await(t, m, j)
			if operation == "dump" {
				if done.State != "cancelled" || done.OutputPublished {
					t.Fatal("cancelled dump published")
				}
				if _, err := os.Stat(path); !os.IsNotExist(err) {
					t.Fatal("cancelled dump created destination")
				}
			} else if done.State != "outcomeUnknown" {
				t.Fatal("interrupted restore did not retain uncertainty")
			}
		})
	}
}
func TestDatabaseToolsCredentialAndEnvironmentIsolation(t *testing.T) {
	c := connection()
	c.Password = "quote:\\with\"special"
	dir := t.TempDir()
	args, env, err := utilityArguments(protocol.DatabaseToolsRequest{Operation: "dump", Format: "custom"}, PreparedConnection{Connection: c, Host: c.Host, Port: c.Port}, dir)
	if err != nil {
		t.Fatal("cannot construct private utility credentials")
	}
	for _, value := range append(args, env...) {
		if strings.Contains(value, c.Password) {
			t.Fatal("password escaped private credential file")
		}
	}
	file := filepath.Join(dir, "pgpass")
	info, err := os.Stat(file)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("password file is not private")
	}
	c.Engine = "mysql"
	_, _, err = utilityArguments(protocol.DatabaseToolsRequest{Operation: "restore", Format: "sql"}, PreparedConnection{Connection: c, Host: c.Host, Port: c.Port}, dir)
	if err != nil {
		t.Fatal("mysql credentials failed")
	}
	data, _ := os.ReadFile(filepath.Join(dir, "mysql.cnf"))
	if !strings.Contains(string(data), `password="quote:\\with\"special"`) {
		t.Fatal("mysql option-file password escaping changed")
	}
	_ = io.Discard
}
