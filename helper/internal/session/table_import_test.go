package session

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"strings"
	"sync/atomic"
	"testing"
)

func policyImportRequest() *protocol.TableImportRequest {
	value := "one"
	return &protocol.TableImportRequest{Schema: "s", Table: "t", Fingerprint: strings.Repeat("a", 64), Columns: []string{"label"}, Rows: [][]protocol.CellValue{{{Kind: "text", Value: &value}}}}
}

func TestTableImportManagerIsolatesSQLTabsAndRetainsStartedCorrelation(t *testing.T) {
	var calls atomic.Int32
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		return &testSession{closed: make(chan struct{}), run: func(_ context.Context, command protocol.Command) protocol.Response {
			calls.Add(1)
			count := len(command.TableImport.Rows)
			return protocol.Response{Type: command.Type + ".result", Connected: true, TransactionStatus: "idle", TableImport: &protocol.TableImportReply{Fingerprint: command.TableImport.Fingerprint, RowCount: &count, SQL: "INSERT INTO fixture VALUES (?)"}}
		}}, nil
	})
	defer manager.Close()
	sqlID := openTestSession(t, manager, "sql")
	submit(t, manager, protocol.Command{Type: "import.preview", RequestID: "blocked-import", QueryID: "blocked-import", SessionID: sqlID, TableImport: policyImportRequest()})
	if response := receive(t, manager); response.Type != "error" || response.Category != "policy" || !response.SQLNotExecuted || calls.Load() != 0 {
		t.Fatal("import reached a SQL tab adapter")
	}
	submit(t, manager, protocol.Command{Type: "connect", RequestID: "import-connect", Connection: &protocol.Connection{SessionPurpose: "import"}})
	connected := receive(t, manager)
	if connected.Type != "connect.result" {
		t.Fatal("dedicated import session did not connect")
	}
	submit(t, manager, protocol.Command{Type: "execute", RequestID: "blocked-sql", QueryID: "blocked-sql", SessionID: connected.SessionID, SQL: "SELECT 1"})
	if response := receive(t, manager); response.Type != "error" || response.Category != "policy" || calls.Load() != 0 {
		t.Fatal("SQL reached the dedicated import adapter")
	}
	command := protocol.Command{Type: "import.preview", RequestID: "preview", QueryID: "preview", SessionID: connected.SessionID, TableImport: policyImportRequest()}
	submit(t, manager, command)
	started, finished := receive(t, manager), receive(t, manager)
	if started.Type != "query.started" || finished.Type != "import.preview.result" || started.RequestID != command.RequestID || finished.RequestID != command.RequestID || started.QueryID != command.QueryID || finished.QueryID != command.QueryID || finished.SessionID != connected.SessionID || calls.Load() != 1 {
		t.Fatal("import lifecycle lost correlation or executed twice")
	}
}

func TestTableImportPolicyRequiresDedicatedSessionAndBindsImmutableRows(t *testing.T) {
	for _, environment := range []string{"development", "production"} {
		for _, readOnly := range []bool{false, true} {
			o := &owner{id: "import", importOnly: true}
			request := policyImportRequest()
			policy := protocol.ExecutionPolicy{Environment: environment, ReadOnly: readOnly}
			response := o.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "import.apply", TableImport: request}}}, "postgresql", policy)
			expected := "allow"
			if environment == "production" {
				expected = "confirm"
			}
			if readOnly {
				expected = "deny"
			}
			if response.Assessment == nil || response.Assessment.Decision != expected {
				t.Fatal("import policy mismatch")
			}
			if !readOnly {
				*request.Rows[0][0].Value = "changed"
				if o.authorize(protocol.Command{Type: "import.apply", TableImport: request, Authorization: response.Assessment.Authorization}, "postgresql", policy) {
					t.Fatal("changed import rows reused approval")
				}
			}
		}
	}
	o := &owner{id: "sql"}
	if o.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "import.apply", TableImport: policyImportRequest()}}}, "postgresql", protocol.ExecutionPolicy{Environment: "development"}).Type != "error" {
		t.Fatal("SQL tab accepted import")
	}
	importer := &owner{id: "import", importOnly: true}
	if importer.authorize(protocol.Command{Type: "execute", SQL: "SELECT 1"}, "postgresql", protocol.ExecutionPolicy{Environment: "development"}) {
		t.Fatal("import session accepted arbitrary SQL")
	}
}
