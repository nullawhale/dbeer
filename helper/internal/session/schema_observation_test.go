package session

import (
	"context"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type schemaObserverTestSession struct{ *monitorTestSession }

func (s *schemaObserverTestSession) ObserveSchema(context.Context, protocol.Command) protocol.Response {
	return protocol.Response{Type: "monitor.schema.result", Connected: true, TransactionStatus: "idle", SchemaObservation: &protocol.SchemaObservation{Engine: "postgresql", Action: "poll", Tables: []protocol.SchemaObservationTable{{Schema: "public", Name: "t"}}, Mode: "notifications", Revision: "0", ObservedAt: time.Now().UTC().Format(time.RFC3339Nano), Installed: true, Complete: true, Notices: []string{}}}
}
func TestSchemaObservationManagerRequiresDedicatedReadonlyOwnership(t *testing.T) {
	var opened *schemaObserverTestSession
	manager := New(func(_ context.Context, connection protocol.Connection) (adapter.Session, error) {
		physical := &schemaObserverTestSession{&monitorTestSession{testSession: &testSession{closed: make(chan struct{}), run: func(context.Context, protocol.Command) protocol.Response {
			t.Error("schema observer dispatched user SQL")
			return protocol.Response{}
		}}}}
		if connection.SessionPurpose == "monitor" {
			opened = physical
			if connection.Policy == nil || !connection.Policy.ReadOnly {
				t.Error("observation connection was not readonly")
			}
		}
		return physical, nil
	})
	defer manager.Close()
	ordinary := openTestSession(t, manager, "ordinary")
	dedicated := connectMonitorTestSession(t, manager)
	if opened == nil || !opened.readonly.Load() {
		t.Fatal("physical readonly missing")
	}
	request := &protocol.SchemaObservationRequest{Action: "poll", Tables: []protocol.SchemaObservationTable{{Schema: "public", Name: "t"}}}
	submit(t, manager, protocol.Command{Type: "monitor.schema", RequestID: "ordinary-watch", SessionID: ordinary, QueryID: "ordinary-watch", SchemaObservation: request})
	if r := receive(t, manager); r.Type != "error" || r.Category != "policy" {
		t.Fatal("ordinary session accepted schema observation")
	}
	submit(t, manager, protocol.Command{Type: "monitor.schema", RequestID: "watch", SessionID: dedicated, QueryID: "watch", SchemaObservation: request})
	started, terminal := receive(t, manager), receive(t, manager)
	if started.Type != "query.started" || terminal.Type != "monitor.schema.result" || terminal.SchemaObservation == nil || !terminal.SchemaObservation.Valid() || terminal.RequestID != "watch" || terminal.QueryID != "watch" {
		t.Fatal("schema observation lost started/terminal correlation")
	}
	submit(t, manager, protocol.Command{Type: "execute", RequestID: "write", SessionID: dedicated, QueryID: "write", SQL: "DROP TABLE t"})
	if r := receive(t, manager); r.Type != "error" || r.Category != "policy" {
		t.Fatal("dedicated observer accepted SQL")
	}
}
