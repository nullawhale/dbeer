package sqlite_test

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/session"
	"dbeer/helper/internal/sqlite"
)

func TestSQLiteReadonlyAttachmentPolicyAndExecution(t *testing.T) {
	ctx := context.Background()
	main := filepath.Join(t.TempDir(), "main.sqlite")
	extra := filepath.Join(t.TempDir(), "extra.sqlite")
	for _, path := range []string{main, extra} {
		if err := sqlite.Create(ctx, path); err != nil {
			t.Fatal(err)
		}
	}
	m := session.New(sqlite.Open)
	defer m.Close()
	sequence := 0
	request := func(c protocol.Command) protocol.Response {
		t.Helper()
		sequence++
		c.RequestID = fmt.Sprintf("r%d", sequence)
		if c.SessionID != "" {
			c.QueryID = fmt.Sprintf("q%d", sequence)
		}
		if !m.Submit(c) {
			t.Fatal("manager rejected command")
		}
		for {
			select {
			case r := <-m.Responses():
				if r.Type == "query.started" {
					continue
				}
				if r.RequestID != c.RequestID {
					t.Fatal("incorrect response correlation")
				}
				return r
			case <-time.After(5 * time.Second):
				t.Fatal("readonly manager timed out")
				return protocol.Response{}
			}
		}
	}
	connected := request(protocol.Command{Type: "connect", Connection: &protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: main}, Policy: &protocol.ExecutionPolicy{ReadOnly: true}}})
	if connected.Type != "connect.result" {
		t.Fatal("readonly connection failed")
	}
	sid := connected.SessionID
	attach := "ATTACH DATABASE '" + extra + "' AS extra"
	assessed := request(protocol.Command{Type: "operation.assess", SessionID: sid, Operations: []protocol.OperationRequest{{Type: "execute", SQL: attach}}})
	if assessed.Assessment == nil || assessed.Assessment.Decision != "allow" || assessed.Assessment.Operations[0].Kind != "read" {
		t.Fatal("readonly attachment was not safely assessed")
	}
	result := request(protocol.Command{Type: "execute", SessionID: sid, SQL: attach, Authorization: assessed.Assessment.Authorization})
	if result.Type != "query.result" {
		t.Fatal("approved readonly attachment failed")
	}
	for _, sql := range []string{"SELECT count(*) FROM extra.sqlite_schema", "DETACH extra"} {
		if r := request(protocol.Command{Type: "execute", SessionID: sid, SQL: sql}); r.Type != "query.result" {
			t.Fatal("readonly session operation failed")
		}
	}
	for _, sql := range []string{attach + "; CREATE TABLE main.bad(id)", "CREATE TABLE main.bad(id)", "ATTACH ':memory:' AS extra"} {
		r := request(protocol.Command{Type: "operation.assess", SessionID: sid, Operations: []protocol.OperationRequest{{Type: "execute", SQL: sql}}})
		if r.Assessment == nil || r.Assessment.Decision != "deny" {
			t.Fatal("readonly policy allowed unsafe operation")
		}
	}
}
