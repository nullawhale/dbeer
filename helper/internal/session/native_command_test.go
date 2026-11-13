package session

import (
	"context"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

// This fake exercises admission and ownership; it is not an engine integration.
type fakeNativeCommandSession struct {
	*testSession
	calls     atomic.Int32
	runNative func(context.Context, protocol.Command) protocol.Response
}

func (s *fakeNativeCommandSession) SetReadOnly(context.Context, bool) error { return nil }
func (s *fakeNativeCommandSession) ClassifyNativeCommand(c protocol.NativeCommand) string {
	switch c.Name {
	case "READ":
		return "read"
	case "WRITE":
		return "write"
	case "ERASE":
		return "destructive"
	}
	return "unclassified"
}
func (s *fakeNativeCommandSession) ExecuteNativeCommand(ctx context.Context, c protocol.Command) protocol.Response {
	s.calls.Add(1)
	if s.runNative != nil {
		return s.runNative(ctx, c)
	}
	display := "display only"
	r := fakeResult(c)
	r.Columns = []protocol.Column{{Index: 0, Name: "reply", NativeType: "native"}}
	r.Rows, r.DisplayedRowCount = [][]*string{{&display}}, 1
	r.NativeValues = [][]protocol.NativeValue{{{Kind: "tuple", Items: []protocol.NativeValue{protocol.NativeBinary([]byte{0, 255}), protocol.NativeScalar("integer", "9007199254740993"), protocol.NativeScalar("text", "")}}}}
	return r
}
func newFakeNativeCommandSession() *fakeNativeCommandSession {
	return &fakeNativeCommandSession{testSession: &testSession{closed: make(chan struct{}), run: func(context.Context, protocol.Command) protocol.Response {
		panic("native command reached SQL executor")
	}}}
}
func nativeOperation(name, queryID string) protocol.OperationRequest {
	return protocol.OperationRequest{Type: "command.execute", QueryID: queryID, NativeCommand: &protocol.NativeCommand{Name: name, Arguments: []protocol.NativeCommandArgument{{Kind: "text", Value: "e\u0301"}, {Kind: "binary", Value: "AP8="}, {Kind: "text", Value: ""}}}}
}
func nativeExecution(session string, op protocol.OperationRequest, authorization string) protocol.Command {
	return protocol.Command{Type: op.Type, RequestID: "run", SessionID: session, QueryID: op.QueryID, NativeCommand: op.NativeCommand, ResultValues: protocol.NativeResultValuesFormat, Authorization: authorization}
}

func TestNativeCommandGrantsBindExactBytesNameKindOrderIDAndSession(t *testing.T) {
	physical := newFakeNativeCommandSession()
	policy := protocol.ExecutionPolicy{Environment: "production"}
	for _, mutate := range []string{"name", "unicode", "binary", "kind", "order", "empty", "query", "session", "replay", "direct"} {
		t.Run(mutate, func(t *testing.T) {
			o := &owner{id: "owner"}
			op := nativeOperation("WRITE", "operation")
			r := o.assess(protocol.Command{Operations: []protocol.OperationRequest{op}}, "postgresql", policy, physical)
			if r.Assessment == nil || r.Assessment.Decision != "confirm" {
				t.Fatal("write not confirmed")
			}
			c := nativeExecution("owner", op, r.Assessment.Authorization)
			// Assessment retained its own deep copy before caller mutation.
			switch mutate {
			case "name":
				c.NativeCommand.Name = "READ"
			case "unicode":
				c.NativeCommand.Arguments[0].Value = "é"
			case "binary":
				c.NativeCommand.Arguments[1].Value = "AAA="
			case "kind":
				c.NativeCommand.Arguments[1].Kind = "text"
			case "order":
				c.NativeCommand.Arguments[0], c.NativeCommand.Arguments[1] = c.NativeCommand.Arguments[1], c.NativeCommand.Arguments[0]
			case "empty":
				c.NativeCommand.Arguments = c.NativeCommand.Arguments[:2]
			case "query":
				c.QueryID = "other"
			case "session":
				c.SessionID = "other"
			case "direct":
				c.Authorization = ""
			case "replay":
				if !o.authorize(c, "postgresql", policy, physical) {
					t.Fatal("original refused")
				}
			}
			if o.authorize(c, "postgresql", policy, physical) {
				t.Fatal("changed/replayed command authorized")
			}
		})
	}
	for _, name := range []string{"READ", "WRITE", "ERASE", "MYSTERY"} {
		for _, readonly := range []bool{true, false} {
			o := &owner{id: "owner"}
			op := nativeOperation(name, "id")
			p := protocol.ExecutionPolicy{Environment: "production", ReadOnly: readonly}
			r := o.assess(protocol.Command{Operations: []protocol.OperationRequest{op}}, "postgresql", p, physical)
			if r.Assessment == nil {
				t.Fatal("assessment missing")
			}
			want := "confirm"
			if name == "READ" {
				want = "allow"
			} else if readonly {
				want = "deny"
			}
			if r.Assessment.Decision != want || name == "MYSTERY" && r.Assessment.Operations[0].Kind != "unknown" {
				t.Fatal("unsafe classification")
			}
			if o.authorize(nativeExecution("owner", op, ""), "postgresql", p, physical) {
				t.Fatal("command skipped exact assessment grant")
			}
		}
	}
}

func TestNativeCommandOwnerDispatchKeepsExactReplyAndUnsupportedFailBeforeExecution(t *testing.T) {
	physical := newFakeNativeCommandSession()
	m := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil })
	defer m.Close()
	submit(t, m, protocol.Command{Type: "connect", RequestID: "connect", Connection: &protocol.Connection{Policy: &protocol.ExecutionPolicy{Environment: "production"}}})
	connected := receive(t, m)
	if !slices.Contains(connected.Capabilities, protocol.NativeCommandsCapability) || !slices.Contains(connected.Capabilities, protocol.NativeResultValuesCapability) {
		t.Fatal("fake exact boundary not negotiated")
	}
	nativeCapabilities := 0
	for _, capability := range connected.Capabilities {
		if capability == protocol.NativeResultValuesCapability {
			nativeCapabilities++
		}
	}
	if nativeCapabilities != 1 {
		t.Fatal("exact native capability must be unique")
	}
	op := nativeOperation("WRITE", "native-operation")
	submit(t, m, protocol.Command{Type: "operation.assess", RequestID: "assess", SessionID: connected.SessionID, QueryID: "assessment", Operations: []protocol.OperationRequest{op}})
	a := receive(t, m)
	if a.Assessment == nil {
		t.Fatal("assessment missing")
	}
	submit(t, m, nativeExecution(connected.SessionID, op, a.Assessment.Authorization))
	if receive(t, m).Type != "query.started" {
		t.Fatal("owner did not start command")
	}
	r := receive(t, m)
	if r.Type != "query.result" || r.QueryID != op.QueryID || len(r.NativeValues) != 1 || r.NativeValues[0][0].Items[0].Value == nil || *r.NativeValues[0][0].Items[0].Value != "AP8=" || physical.calls.Load() != 1 {
		t.Fatal("exact reply lost")
	}
	legacy := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return blockingSession(), nil })
	defer legacy.Close()
	sid := openTestSession(t, legacy, "legacy")
	submit(t, legacy, nativeExecution(sid, nativeOperation("READ", "unsupported"), "fake"))
	if r := receive(t, legacy); r.Type != "error" || r.Category != "capability" || !r.SQLNotExecuted {
		t.Fatal("unsupported adapter admitted command")
	}
}

func TestNativeCommandTargetedCancellationAndInvalidReplyOutcome(t *testing.T) {
	physical := newFakeNativeCommandSession()
	entered := make(chan struct{})
	physical.runNative = func(ctx context.Context, c protocol.Command) protocol.Response {
		close(entered)
		<-ctx.Done()
		r := protocol.ErrorResponse(c, "cancelled", "Native command cancelled.")
		r.Connected, r.OutcomeUnknown = true, true
		return r
	}
	m := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil })
	defer m.Close()
	sid := openTestSession(t, m, "cancel-owner")
	op := nativeOperation("WRITE", "pending-command")
	submit(t, m, protocol.Command{Type: "operation.assess", RequestID: "assess", SessionID: sid, QueryID: "assessment", Operations: []protocol.OperationRequest{op}})
	a := receive(t, m)
	submit(t, m, nativeExecution(sid, op, a.Assessment.Authorization))
	if receive(t, m).Type != "query.started" {
		t.Fatal("start")
	}
	<-entered
	submit(t, m, protocol.Command{Type: "cancel", RequestID: "wrong", SessionID: sid, QueryID: "other"})
	if receive(t, m).Status != "alreadyFinished" {
		t.Fatal("wrong operation cancelled")
	}
	submit(t, m, protocol.Command{Type: "cancel", RequestID: "cancel", SessionID: sid, QueryID: op.QueryID})
	for range 2 {
		r := receive(t, m)
		if r.RequestID == "run" && (!r.OutcomeUnknown || r.Category != "cancelled") {
			t.Fatal("write uncertainty lost")
		}
	}
	physical = newFakeNativeCommandSession()
	physical.runNative = func(_ context.Context, c protocol.Command) protocol.Response { return fakeResult(c) }
	r := runNativeCommand(context.Background(), physical, nativeExecution("owner", op, "grant"))
	if r.Type != "error" || !r.SQLCompleted || r.OutcomeUnknown {
		t.Fatal("completed command with missing exact reply lost outcome")
	}
}

func TestNativeCommandMalformedOrOversizeReplyRetainsCompletionEvidence(t *testing.T) {
	for _, fault := range []string{"missing", "unicode", "budget", "column"} {
		t.Run(fault, func(t *testing.T) {
			physical := newFakeNativeCommandSession()
			physical.runNative = func(_ context.Context, c protocol.Command) protocol.Response {
				r := fakeResult(c)
				value := "display"
				r.Columns, r.Rows, r.DisplayedRowCount = []protocol.Column{{Index: 0, Name: "reply", NativeType: "native"}}, [][]*string{{&value}}, 1
				r.NativeValues = [][]protocol.NativeValue{{protocol.NativeBinary([]byte{0, 255})}}
				switch fault {
				case "missing":
					r.NativeValues = nil
				case "unicode":
					value = string([]byte{0xff})
				case "budget":
					r.Columns[0].Name = strings.Repeat("x", displayBytes+1)
				case "column":
					r.Columns[0].Index = 1
				}
				return r
			}
			r := runNativeCommand(context.Background(), physical, nativeExecution("owner", nativeOperation("WRITE", "operation"), "grant"))
			if r.Type != "error" || !r.SQLCompleted || r.OutcomeUnknown || physical.calls.Load() != 1 {
				t.Fatal("malformed reply changed completion or retried command")
			}
		})
	}
}
