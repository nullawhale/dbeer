package session

import (
	"context"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type mariaDBOptimizerFake struct {
	tuningFake
	observations int
	driftAt      int
	all          []string
}

func (f *mariaDBOptimizerFake) ExplainSupport() protocol.ExplainSupport {
	return protocol.ExplainSupport{Engine: "mariadb", ServerVersion: "11.4.13-MariaDB", Format: "json", Modes: []string{"plan", "analyze"}}
}
func (f *mariaDBOptimizerFake) Execute(_ context.Context, c protocol.Command) protocol.Response {
	f.all = append(f.all, c.SQL)
	if c.SQL != "SELECT @@SESSION.optimizer_switch" {
		return protocol.Response{Type: "error"}
	}
	f.observations++
	value := "index_merge=on,index_condition_pushdown=on,future_native_flag=off"
	if f.observations == f.driftAt {
		value = "index_merge=off,index_condition_pushdown=on,future_native_flag=off"
	}
	return protocol.Response{Type: "query.result", Rows: [][]*string{{&value}}, TransactionStatus: f.status}
}
func (f *mariaDBOptimizerFake) ExecuteWithSink(ctx context.Context, c protocol.Command, sink adapter.ResultSink) protocol.Response {
	f.all = append(f.all, c.SQL)
	return f.tuningFake.ExecuteWithSink(ctx, c, sink)
}
func mariaDBOptimizerRequest() protocol.TuningValidationRequest {
	r := validationRequest()
	r.Variant = r.Original
	r.MariaDBOptimizer = &protocol.MariaDBOptimizerVariant{ExpectedNativeSwitch: "index_merge=on,index_condition_pushdown=on,future_native_flag=off", IndexConditionPushdown: false}
	return r
}
func TestMariaDBOptimizerValidationBindsStatementScopeAndRestoration(t *testing.T) {
	for _, tc := range []struct {
		name                  string
		drift                 int
		unknown               bool
		queries, observations int
		complete              bool
	}{
		{"acknowledged", 0, false, 2, 4, true}, {"before original", 1, false, 0, 1, false}, {"after original", 2, false, 1, 2, false}, {"before candidate", 3, false, 1, 3, false}, {"after candidate", 4, false, 2, 4, false}, {"unknown candidate", 0, true, 2, 3, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			row := []protocol.NativeValue{protocol.NativeScalar("integer", "1")}
			f := &mariaDBOptimizerFake{tuningFake: tuningFake{status: "idle", rows: [][][]protocol.NativeValue{{row, row}, {row, row}}, failSecond: tc.unknown}, driftAt: tc.drift}
			r := mariaDBOptimizerRequest()
			out := runTuningValidation(context.Background(), f, protocol.Command{}, r)
			if out.Complete != tc.complete || !out.Valid() || len(f.calls) != tc.queries || f.observations != tc.observations {
				t.Fatalf("unexpected trial boundary: complete=%t queries=%d observations=%d", out.Complete, len(f.calls), f.observations)
			}
			if tc.complete && out.State != "observedEqual" {
				t.Fatal("equal exact native bags were changed")
			}
			if len(f.calls) == 2 && f.calls[1] != adapter.MariaDBTuningOptimizerSQL(*r.MariaDBOptimizer, r.Original.SQL) {
				t.Fatal("candidate did not use exact fixed statement scope")
			}
			if len(f.all) != tc.queries+tc.observations {
				t.Fatal("unexpected restore, recovery or replay command")
			}
		})
	}
}
func TestMariaDBOptimizerPolicyAndOneUseRequestBinding(t *testing.T) {
	r := mariaDBOptimizerRequest()
	f := &mariaDBOptimizerFake{tuningFake: tuningFake{status: "idle"}}
	owner := &owner{id: "owner"}
	op := protocol.OperationRequest{Type: "tuning.validate", TuningValidation: &r}
	if !r.Valid() || !owner.tuningOperationValid(op, f) {
		t.Fatal("exact MariaDB optimizer request refused")
	}
	assessed := assessOperation("mariadb", op)
	if assessed.Kind != "write" || policyDecision(protocol.ExecutionPolicy{ReadOnly: true}, assessed) != "deny" {
		t.Fatal("readonly policy admitted statement setting")
	}
	if owner.tuningOperationValid(op, &tuningFake{status: "idle"}) {
		t.Fatal("optimizer request crossed engine boundary")
	}
	command := protocol.Command{Type: "operation.assess", Operations: []protocol.OperationRequest{op}}
	assessment := owner.assess(command, "mariadb", protocol.ExecutionPolicy{Environment: "development"}, f)
	if assessment.Assessment == nil || assessment.Assessment.Decision != "confirm" || assessment.Assessment.Authorization == "" {
		t.Fatal("statement setting bypassed explicit review")
	}
	execute := protocol.Command{Type: "tuning.validate", TuningValidation: &r, Authorization: assessment.Assessment.Authorization}
	changed := r
	selected := *r.MariaDBOptimizer
	selected.ExpectedNativeSwitch = "index_merge=off,index_condition_pushdown=on,future_native_flag=off"
	changed.MariaDBOptimizer = &selected
	execute.TuningValidation = &changed
	if owner.authorize(execute, "mariadb", protocol.ExecutionPolicy{Environment: "development"}, f) {
		t.Fatal("grant admitted a different native state")
	}
	assessment = owner.assess(command, "mariadb", protocol.ExecutionPolicy{Environment: "development"}, f)
	execute.TuningValidation = &r
	execute.Authorization = assessment.Assessment.Authorization
	if !owner.authorize(execute, "mariadb", protocol.ExecutionPolicy{Environment: "development"}, f) || owner.authorize(execute, "mariadb", protocol.ExecutionPolicy{Environment: "development"}, f) {
		t.Fatal("grant was not exact and one use")
	}
}
