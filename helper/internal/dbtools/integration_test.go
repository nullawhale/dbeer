package dbtools

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/postgres"
	"dbeer/helper/internal/protocol"
)

// Run inside the disposable server container so the real version-matched
// utilities are available even on a development host without local clients.
func TestDatabaseToolsRealDumpRestoreRoundTrip(t *testing.T) {
	engine := os.Getenv("DBEER_DBTOOLS_TEST_ENGINE")
	if engine == "" {
		t.Skip("DBEER_DBTOOLS_TEST_ENGINE is not configured")
	}
	password, err := os.ReadFile(os.Getenv("DBEER_DBTOOLS_TEST_PASSWORD_FILE"))
	if err != nil {
		t.Fatal("disposable utility fixture password unavailable")
	}
	c := protocol.Connection{Engine: engine, Host: "127.0.0.1", Database: "dbeer", User: "dbeer", Password: strings.TrimSpace(string(password)), SSLMode: "disable"}
	opener := adapter.OpenFunc(postgres.Open)
	formats := []string{"custom", "sql", "tar"}
	bin := os.Getenv("DBEER_DBTOOLS_TEST_BIN")
	if engine == "mysql" {
		opener = mysql.Open
		c.Port = 3306
		formats = []string{"sql"}
	} else {
		c.Port = 5432
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	session, err := opener(ctx, c)
	if err != nil {
		t.Fatal("cannot open utility fixture database")
	}
	defer session.Close()
	run := func(sql string) protocol.Response {
		t.Helper()
		r := session.Execute(ctx, protocol.Command{Type: "execute", RequestID: "fixture", SessionID: "fixture", QueryID: "fixture", SQL: sql})
		if r.Type != "query.result" {
			t.Fatalf("utility fixture SQL failed: category=%s SQLSTATE=%s", r.Category, r.SQLState)
		}
		return r
	}
	run("DROP TABLE IF EXISTS dbeer_tool_rows")
	defer run("DROP TABLE IF EXISTS dbeer_tool_rows")
	ddl := "CREATE TABLE dbeer_tool_rows(id INTEGER PRIMARY KEY,nullable_text TEXT,empty_text TEXT,precise NUMERIC(30,10),payload BYTEA)"
	insert := "INSERT INTO dbeer_tool_rows VALUES(1,NULL,'',9007199254740993.1234567890,decode('00ff','hex')),(2,'NULL','unicode Ω',-0.0000000001,decode('','hex'))"
	if engine == "mysql" {
		ddl = "CREATE TABLE dbeer_tool_rows(id INTEGER PRIMARY KEY,nullable_text TEXT,empty_text TEXT,precise DECIMAL(30,10),payload BLOB) ENGINE=InnoDB"
		insert = "INSERT INTO dbeer_tool_rows VALUES(1,NULL,'',9007199254740993.1234567890,X'00FF'),(2,'NULL','unicode Ω',-0.0000000001,X'')"
	}
	run(ddl)
	run(insert)
	before := run("SELECT id,nullable_text,empty_text,precise,payload FROM dbeer_tool_rows ORDER BY id")
	beforeBytes, _ := json.Marshal(before.Rows)
	for _, format := range formats {
		t.Run(format, func(t *testing.T) {
			m, err := New(opener, Options{Root: t.TempDir()})
			if err != nil {
				t.Fatal("cannot initialize utility service")
			}
			defer m.Close()
			path := filepath.Join(t.TempDir(), "backup."+format)
			request := func(operation, tool string) protocol.DatabaseToolsReply {
				t.Helper()
				r := m.Handle(protocol.Command{Type: "dbtools.preview", RequestID: "preview", DatabaseTools: &protocol.DatabaseToolsRequest{Connection: &c, Operation: operation, Format: format, Path: path, ToolPath: filepath.Join(bin, tool)}})
				if r.DatabaseTools == nil {
					t.Fatalf("real utility preview failed: category=%s message=%s", r.Category, r.Message)
				}
				return *r.DatabaseTools
			}
			dump := request("dump", expectedTool(engine, "dump", format))
			done := await(t, m, start(t, m, dump))
			if done.State != "completed" || !done.OutputPublished {
				t.Fatalf("real dump failed: state=%s code=%v", done.State, done.ExitCode)
			}
			run("DROP TABLE dbeer_tool_rows")
			restore := request("restore", expectedTool(engine, "restore", format))
			done = await(t, m, start(t, m, restore))
			if done.State != "completed" {
				t.Fatalf("real restore failed: state=%s code=%v", done.State, done.ExitCode)
			}
			after := run("SELECT id,nullable_text,empty_text,precise,payload FROM dbeer_tool_rows ORDER BY id")
			afterBytes, _ := json.Marshal(after.Rows)
			if string(beforeBytes) != string(afterBytes) {
				t.Fatal("dump/restore changed NULL, empty text, exact decimals or binary values")
			}
		})
	}
	t.Run("cancel_restore", func(t *testing.T) {
		m, err := New(opener, Options{Root: t.TempDir()})
		if err != nil {
			t.Fatal("cannot initialize cancellation fixture")
		}
		defer m.Close()
		path := filepath.Join(t.TempDir(), "cancel.sql")
		sql := "CREATE TABLE dbeer_tool_cancel(id INTEGER);\nSELECT pg_sleep(30);\n"
		active := "SELECT count(*)::text FROM pg_catalog.pg_stat_activity WHERE application_name='DBeer database tools' AND state='active' AND wait_event='PgSleep'"
		if engine == "mysql" {
			sql = "CREATE TABLE dbeer_tool_cancel(id INTEGER);\nSELECT SLEEP(30);\n"
			active = "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO LIKE 'SELECT SLEEP(30)%' AND COMMAND='Query'"
		}
		run("DROP TABLE IF EXISTS dbeer_tool_cancel")
		defer run("DROP TABLE IF EXISTS dbeer_tool_cancel")
		os.WriteFile(path, []byte(sql), 0600)
		preview := m.Handle(protocol.Command{Type: "dbtools.preview", RequestID: "cancel-preview", DatabaseTools: &protocol.DatabaseToolsRequest{Connection: &c, Operation: "restore", Format: "sql", Path: path, ToolPath: filepath.Join(bin, expectedTool(engine, "restore", "sql"))}})
		if preview.DatabaseTools == nil {
			t.Fatal("cannot prepare real cancellation restore")
		}
		job := start(t, m, *preview.DatabaseTools)
		observed := false
		deadline := time.Now().Add(4 * time.Second)
		for time.Now().Before(deadline) {
			r := run(active)
			if len(r.Rows) == 1 && len(r.Rows[0]) == 1 && r.Rows[0][0] != nil && *r.Rows[0][0] != "0" {
				observed = true
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		if !observed {
			t.Fatal("restore utility did not reach its independently observed server query")
		}
		m.Handle(protocol.Command{Type: "dbtools.cancel", RequestID: "cancel", DatabaseTools: &protocol.DatabaseToolsRequest{JobID: job.JobID}})
		done := await(t, m, job)
		if done.State != "outcomeUnknown" || done.OutputPublished {
			t.Fatal("interrupted real restore lost explicit partial/unknown outcome")
		}
		if session.TransactionStatus() != "idle" {
			t.Fatal("utility cancellation changed the ordinary fixture session")
		}
		if engine == "postgresql" {
			result := run("SELECT to_regclass('public.dbeer_tool_cancel')::text")
			if len(result.Rows) != 1 || result.Rows[0][0] != nil {
				t.Fatal("cancelled single-transaction PostgreSQL restore committed its preceding DDL")
			}
		} else {
			result := run("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='dbeer_tool_cancel'")
			if len(result.Rows) != 1 || result.Rows[0][0] == nil || *result.Rows[0][0] != "1" {
				t.Fatal("MySQL cancellation fixture did not retain the documented committed DDL")
			}
		}
	})
	t.Run("local_commands", func(t *testing.T) {
		m, err := New(opener, Options{Root: t.TempDir()})
		if err != nil {
			t.Fatal("cannot initialize local-command fixture")
		}
		defer m.Close()
		dir := t.TempDir()
		marker := filepath.Join(dir, "must-not-exist")
		path := filepath.Join(dir, "local.sql")
		os.WriteFile(path, []byte("\\! touch "+marker+"\n"), 0600)
		prepared := m.Handle(protocol.Command{Type: "dbtools.preview", RequestID: "local-preview", DatabaseTools: &protocol.DatabaseToolsRequest{Connection: &c, Operation: "restore", Format: "sql", Path: path, ToolPath: filepath.Join(bin, expectedTool(engine, "restore", "sql"))}})
		if engine == "postgresql" {
			if prepared.Type != "error" {
				t.Fatal("psql local command passed preview")
			}
		} else {
			if prepared.DatabaseTools == nil {
				t.Fatal("cannot prepare binary-mode command rejection fixture")
			}
			done := await(t, m, start(t, m, *prepared.DatabaseTools))
			if done.State == "completed" {
				t.Fatal("mysql local command was not rejected")
			}
		}
		if _, err := os.Stat(marker); !os.IsNotExist(err) {
			t.Fatal("restore executed a local shell command")
		}
	})
}
