package session

import (
	"context"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
)

type operationSupportSession struct {
	*explainTestSession
}

func (*operationSupportSession) SetReadOnly(context.Context, bool) error { return nil }

func availability(t *testing.T, support *protocol.OperationSupport, operation string) protocol.OperationAvailability {
	t.Helper()
	if support == nil || !support.Valid() {
		t.Fatal("missing valid operation support")
	}
	for _, value := range support.Operations {
		if value.Operation == operation {
			return value
		}
	}
	t.Fatalf("missing %s", operation)
	return protocol.OperationAvailability{}
}

func TestOperationSupportConnectUsesPhysicalAdapterAndPolicy(t *testing.T) {
	physical := &operationSupportSession{explainTestSession: &explainTestSession{testSession: blockingSession()}}
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil })
	defer manager.Close()
	policy := &protocol.ExecutionPolicy{Environment: "production", ReadOnly: true}
	submit(t, manager, protocol.Command{Type: "connect", RequestID: "connect", Connection: &protocol.Connection{Database: "synthetic", Policy: policy}})
	response := receive(t, manager)
	if response.Type != "connect.result" {
		t.Fatal("connection did not finish")
	}
	if availability(t, response.OperationSupport, "gridEditing").State != "unavailable" {
		t.Fatal("readonly editing advertised")
	}
	if availability(t, response.OperationSupport, "explain.plan").State != "available" {
		t.Fatal("supported plan unavailable")
	}
	if availability(t, response.OperationSupport, "structure.preview").State != "unavailable" {
		t.Fatal("missing adapter advertised structure support")
	}
}

func TestOperationSupportKeepsMetadataAndPreviewRequirements(t *testing.T) {
	policy := protocol.ExecutionPolicy{Environment: "development"}
	response := protocol.Response{Type: "structure.load.result", Structure: &tableedit.Reply{Baseline: &tableedit.Baseline{}}}
	attachOperationSupport(&response, "mysql", policy)
	if availability(t, response.OperationSupport, "structure.preview").State != "available" || availability(t, response.OperationSupport, "structure.apply").State != "requiresMetadata" {
		t.Fatal("load bypassed preview")
	}
	response.Structure = &tableedit.Reply{Plan: &tableedit.Plan{}}
	attachOperationSupport(&response, "mysql", policy)
	if availability(t, response.OperationSupport, "structure.apply").State != "available" {
		t.Fatal("current plan not reflected")
	}
	response.Structure = &tableedit.Reply{Outcome: &tableedit.Outcome{State: "outcomeUnknown"}}
	attachOperationSupport(&response, "mysql", policy)
	if availability(t, response.OperationSupport, "structure.apply").State != "requiresMetadata" {
		t.Fatal("unknown outcome allowed another apply")
	}
	policy.ReadOnly = true
	attachOperationSupport(&response, "mysql", policy)
	if availability(t, response.OperationSupport, "structure.apply").State != "unavailable" {
		t.Fatal("readonly policy was lost")
	}
}

func TestOperationSupportPreservesResultProvenanceReasons(t *testing.T) {
	source := &protocol.ResultSource{Schema: "public", Table: "sample", Columns: []protocol.ResultSourceColumn{{Name: "id", PrimaryKey: 1, Editable: true}}, ReadOnlyReason: "Only part of the source row was selected."}
	response := protocol.Response{Type: "query.result", Source: source, ResultSets: []protocol.ResultSet{{Source: source}}}
	attachOperationSupport(&response, "postgresql", protocol.ExecutionPolicy{})
	if availability(t, source.OperationSupport, "resultSource.open").State != "available" {
		t.Fatal("exact source key cannot open row")
	}
	if availability(t, source.OperationSupport, "resultSource.edit").Reason != source.ReadOnlyReason {
		t.Fatal("projection limitation was lost")
	}
	source.ReadOnlyReason = ""
	attachOperationSupport(&response, "postgresql", protocol.ExecutionPolicy{ReadOnly: true})
	if availability(t, source.OperationSupport, "resultSource.edit").State != "unavailable" {
		t.Fatal("readonly source allowed editing")
	}
}
