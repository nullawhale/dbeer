package session

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
)

func tuningRequest(sql string) protocol.ExplainRequest {
	return protocol.ExplainRequest{SQL: sql, Mode: "plan", Context: &protocol.ExplainContext{DocumentID: "doc", TargetDocumentID: "doc", RangeLength: len(utf16.Encode([]rune(sql))), ProfileID: "profile", SessionID: "owner", TransactionStatus: "idle"}}
}
func tuningBaseline() tableedit.Baseline {
	target := tableedit.Target{Schema: "public", Table: "items"}
	col := sc.Column{Ref: sc.Ref{Kind: "column", Schema: "public", Table: "items", Name: "id"}, Type: sc.Known(sc.TypeUse{Kind: "builtin", Ref: sc.Ref{Schema: "pg_catalog", Name: "int4"}, Modifiers: sc.Known(sc.TypeModifiers{})}), Generated: sc.Known(sc.Generated{Kind: "none"})}
	return tableedit.Baseline{Target: target, Engine: "postgresql", Fingerprint: strings.Repeat("a", 64), DependencyProof: true, Columns: []tableedit.ObservedColumn{{Name: "id", EditableType: &tableedit.DataType{Kind: "integer"}}}, Indexes: []tableedit.Index{}, Keys: []tableedit.Key{}, Attributes: map[string]map[string]any{"id": {"atttypid": "23"}}, Facts: &tableedit.Facts{Proof: true, Table: sc.Table{Columns: sc.Complete([]sc.Column{col}), Indexes: sc.Complete[sc.Index](nil), Constraints: sc.Complete[sc.Constraint](nil)}}}
}
func tuningCapture() protocol.ExplainResult {
	return protocol.ExplainResult{Support: adapter.ExplainSupport("postgresql", "17.10"), Mode: "plan", Status: "tree", Raw: "synthetic fixture", Complete: true, Roots: []string{"0"}, Nodes: []protocol.ExplainNode{{ID: "0", Operation: "Seq Scan", Children: []string{}, Details: map[string]string{"Schema": "public", "Relation Name": "items"}, Execution: "estimated", Metrics: map[string]protocol.ExplainMetric{}}}, Metrics: map[string]protocol.ExplainMetric{}}
}
func TestTuningInspection(t *testing.T) {
	b := tuningBaseline()
	r := protocol.TuningInspectRequest{Version: 1, Source: tuningRequest("SELECT id FROM public.items WHERE id = 1 OR id = 2"), Capture: tuningCapture(), Target: b.Target}
	out := tuningInspection(r, b)
	if !out.Valid() || len(out.Indexes) != 1 || len(out.Variants) != 1 || out.Variants[0].Request.SQL != "SELECT id FROM public.items WHERE id IN (1, 2)" || out.Variants[0].Validation != "unvalidated" {
		t.Fatalf("candidate %#v", out)
	}
	if !r.Source.Valid() || out.Variants[0].Request.Context.RangeLength != len(out.Variants[0].Request.SQL) {
		t.Fatal("range")
	}
	col := "id"
	b.Indexes = []tableedit.Index{{Name: "items_pkey", Owner: "items_pkey", Definition: &tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: &col}}}}}
	b.Facts.IndexDefaultOpclasses = map[string][]bool{"items_pkey": {true}}
	out = tuningInspection(r, b)
	if len(out.Indexes) != 0 || len(out.Variants) != 1 {
		t.Fatal("key-owned index not suppressed")
	}
	b = tuningBaseline()
	b.Facts.Table.Indexes.Complete = false
	if out = tuningInspection(r, b); len(out.Indexes) != 0 || len(out.Variants) != 0 {
		t.Fatal("partial catalog")
	}
	b = tuningBaseline()
	r.Capture.Nodes[0].Details["Schema"] = "other"
	if len(tuningInspection(r, b).Indexes) != 0 {
		t.Fatal("unmatched scan")
	}
}
func TestTuningQueryGrammar(t *testing.T) {
	target := tuningBaseline().Target
	for _, sql := range []string{"SELECT id FROM public.items WHERE id = 1", "select id from public.items where id IN (1, 2)", "SELECT id FROM public.items WHERE id = 1 OR id = 1"} {
		if _, ok := parseTuningQuery("postgresql", tuningRequest(sql), target); !ok {
			t.Errorf("denied %s", sql)
		}
	}
	for _, sql := range []string{"SELECT evil() FROM public.items WHERE id = 1", "SELECT id FROM public.items WHERE id = evil()", "SELECT id FROM public.items WHERE id = 1; DELETE FROM public.items", "SELECT id FROM public.items WHERE id = 1 OR other = 2", "SELECT id FROM public.items WHERE id = 1 ORDER BY id", "SELECT id FROM public.items WHERE id = 1 LIMIT 1", "SELECT id FROM public.items WHERE id = 1 FOR UPDATE", "SELECT id FROM items WHERE id = 1", "WITH x AS (DELETE FROM public.items) SELECT id FROM public.items WHERE id = 1", "SELECT id FROM public.items WHERE id = 1 /* hint */", "SELECT id FROM public.items WHERE id = '1'", "SELECT id FROM public.items WHERE id = 1 AND id = 2", "SELECT id FROM public.items WHERE id = -99999999999999999999999", "SELECT id FROM publİc.items WHERE id = 1", "SELECT id FROM public.K WHERE id = 1"} {
		if _, ok := parseTuningQuery("postgresql", tuningRequest(sql), target); ok {
			t.Errorf("admitted %s", sql)
		}
	}
}

type tuningFake struct {
	settingUnknown  bool
	status          string
	calls           []string
	rows            [][][]protocol.NativeValue
	failSecond      bool
	metadata        tableedit.Baseline
	delayed         bool
	closeAfterFirst bool
	columns         [][]protocol.Column
}

func (f *tuningFake) TransactionStatus() string { return f.status }
func (f *tuningFake) Close()                    { f.status = "unknown" }
func (f *tuningFake) ExplainSupport() protocol.ExplainSupport {
	return adapter.ExplainSupport("postgresql", "17.10")
}
func (f *tuningFake) PrepareExplain(r protocol.ExplainRequest) (adapter.PreparedExplain, error) {
	return adapter.PreparedExplain{}, nil
}
func (f *tuningFake) ExecuteExplain(context.Context, protocol.Command) protocol.Response {
	return protocol.Response{}
}
func (f *tuningFake) StructureLoad(context.Context, tableedit.Target) (tableedit.Baseline, error) {
	return f.metadata, nil
}
func (f *tuningFake) StructureRender(tableedit.Baseline, tableedit.Draft) ([]string, []string, error) {
	return nil, nil, nil
}
func (f *tuningFake) StructureApply(context.Context, tableedit.Baseline, []string) tableedit.Execution {
	return tableedit.Execution{}
}
func (f *tuningFake) Execute(_ context.Context, c protocol.Command) protocol.Response {
	f.calls = append(f.calls, c.SQL)
	v := "4MB"
	if strings.Contains(c.SQL, "current_schemas") {
		v = `["pg_catalog","public"]`
	}
	if strings.HasPrefix(c.SQL, "SET LOCAL") {
		if f.settingUnknown {
			f.status = "unknown"
			return protocol.Response{Type: "error", Category: "connection", OutcomeUnknown: true, Connected: false, TransactionStatus: "unknown"}
		}
		return protocol.Response{Type: "query.result", TransactionStatus: f.status}
	}
	return protocol.Response{Type: "query.result", Rows: [][]*string{{&v}}, TransactionStatus: f.status}
}
func (f *tuningFake) ExecuteWithSink(ctx context.Context, c protocol.Command, sink adapter.ResultSink) protocol.Response {
	i := len(f.calls)
	f.calls = append(f.calls, c.SQL)
	cols := []protocol.Column{{Index: 0, Name: "value", Engine: "postgresql", TypeOID: 23}}
	if len(f.columns) > i {
		cols = f.columns[i]
	}
	_ = sink.Begin(0, cols)
	if f.delayed {
		<-ctx.Done()
		return protocol.Response{Type: "error", Connected: true}
	}
	if len(f.rows) > i {
		for _, row := range f.rows[i] {
			if ctx.Err() != nil {
				break
			}
			if adapter.DeliverNativeRow(sink, 0, row) != nil {
				break
			}
			if sink.Row(0, make([]*string, len(row))) != nil {
				break
			}
		}
	}
	_ = sink.End(0, protocol.ResultSet{})
	if f.closeAfterFirst {
		f.status = "unknown"
	}
	if f.failSecond && i == 1 {
		return protocol.Response{Type: "error", SQLCompleted: true, OutcomeUnknown: true}
	}
	return protocol.Response{Type: "query.result", TransactionStatus: f.status}
}
func validationRequest() protocol.TuningValidationRequest {
	return protocol.TuningValidationRequest{Version: 1, Original: tuningRequest("SELECT id FROM public.items WHERE id = 1 OR id = 2"), Variant: tuningRequest("SELECT id FROM public.items WHERE id IN (1, 2)"), Target: tuningBaseline().Target, MetadataFingerprint: tuningBaseline().Fingerprint, MaxRows: 10, MaxBytes: 1024, TimeoutMS: 1000, Comparison: "multiset"}
}
func TestTuningNativeBagComparison(t *testing.T) {
	one := protocol.NativeScalar("integer", "1")
	null := protocol.NativeValue{Kind: "null"}
	empty := protocol.NativeScalar("text", "")
	word := protocol.NativeScalar("text", "NULL")
	binary := protocol.NativeBinary([]byte{0, 1, 255})
	numeric := protocol.NativeScalar("decimal", "1.00")
	rows := [][]protocol.NativeValue{{one}, {null}, {empty}, {word}, {binary}, {numeric}, {one}}
	for _, tc := range []struct {
		name  string
		rows  [][]protocol.NativeValue
		state string
	}{{"same multiplicity reversed", [][]protocol.NativeValue{{one}, {numeric}, {binary}, {word}, {empty}, {null}, {one}}, "observedEqual"}, {"different multiplicity", rows[:6], "observedDifferent"}, {"NULL vs text", [][]protocol.NativeValue{{one}, {word}, {empty}, {word}, {binary}, {numeric}, {one}}, "observedDifferent"}, {"exact decimal spelling", [][]protocol.NativeValue{{one}, {null}, {empty}, {word}, {binary}, {protocol.NativeScalar("decimal", "1.0")}, {one}}, "observedDifferent"}} {
		t.Run(tc.name, func(t *testing.T) {
			f := &tuningFake{status: "idle", rows: [][][]protocol.NativeValue{rows, tc.rows}}
			out := runTuningValidation(context.Background(), f, protocol.Command{}, validationRequest())
			if out.State != tc.state || !out.Complete || !out.Valid() {
				t.Fatalf("%#v", out)
			}
			encoded, _ := json.Marshal(out)
			if strings.Contains(string(encoded), "1.00") {
				t.Fatal("rows leaked")
			}
		})
	}
}
func TestTuningValidationBoundsAndAcknowledgement(t *testing.T) {
	row := []protocol.NativeValue{protocol.NativeScalar("integer", "1")}
	for _, kind := range []string{"rows", "bytes", "ack", "deadline", "context", "columns"} {
		t.Run(kind, func(t *testing.T) {
			r := validationRequest()
			f := &tuningFake{status: "idle", rows: [][][]protocol.NativeValue{{row, row}, {row, row}}}
			ctx := context.Background()
			switch kind {
			case "rows":
				r.MaxRows = 1
			case "bytes":
				f.rows[0] = [][]protocol.NativeValue{{protocol.NativeScalar("text", strings.Repeat("x", 1100))}}
			case "ack":
				f.failSecond = true
			case "deadline":
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, time.Millisecond)
				defer cancel()
				f.delayed = true
			case "context":
				f.closeAfterFirst = true
			case "columns":
				f.columns = [][]protocol.Column{{{Index: 0, Name: "one"}}, {{Index: 0, Name: "two"}}}
			}
			out := runTuningValidation(ctx, f, protocol.Command{}, r)
			if kind == "columns" {
				if out.State != "observedDifferent" {
					t.Fatalf("%#v", out)
				}
			} else if out.State != "inconclusive" || out.Complete {
				t.Fatalf("%#v", out)
			}
			if out.ComparedBytes > r.MaxBytes || out.OriginalRows > r.MaxRows || out.VariantRows > r.MaxRows {
				t.Fatal("bounds")
			}
		})
	}
}
func TestTuningFreshGrantAndSetting(t *testing.T) {
	owner := &owner{id: "owner"}
	f := &tuningFake{status: "transaction", metadata: tuningBaseline()}
	r := protocol.TuningSettingRequest{Version: 1, Context: *tuningRequest("SELECT id FROM public.items WHERE id = 1").Context, Name: "work_mem", ExpectedValueKiB: 4096, ValueKiB: 8192}
	r.Context.TransactionStatus = "transaction"
	op := protocol.OperationRequest{Type: "tuning.setting", TuningSetting: &r}
	cmd := protocol.Command{Type: "operation.assess", Operations: []protocol.OperationRequest{op}}
	policy := protocol.ExecutionPolicy{Environment: "development"}
	assessment := owner.assess(cmd, "postgresql", policy, f)
	if assessment.Assessment == nil || assessment.Assessment.Decision != "confirm" || assessment.Assessment.Operations[0].TuningSetting == nil {
		t.Fatalf("%#v", assessment)
	}
	execute := protocol.Command{Type: "tuning.setting", TuningSetting: &r, Authorization: assessment.Assessment.Authorization}
	changed := r
	changed.ValueKiB = 16384
	execute.TuningSetting = &changed
	if owner.authorize(execute, "postgresql", policy, f) {
		t.Fatal("changed setting authorized")
	}
	assessment = owner.assess(cmd, "postgresql", policy, f)
	execute.TuningSetting = &r
	execute.Authorization = assessment.Assessment.Authorization
	if !owner.authorize(execute, "postgresql", policy, f) || owner.authorize(execute, "postgresql", policy, f) {
		t.Fatal("grant is not exact one-use")
	}
	out := owner.runTuning(context.Background(), f, execute, "postgresql")
	if out.TuningSetting == nil || !out.TuningSetting.Valid() || out.TuningSetting.Restore.ValueKiB != 4096 || len(f.calls) != 2 || f.calls[0] != "SHOW work_mem" || f.calls[1] != "SET LOCAL work_mem = '8192kB'" {
		t.Fatalf("%#v calls=%v", out, f.calls)
	}
	policy.ReadOnly = true
	assessment = owner.assess(cmd, "postgresql", policy, f)
	if assessment.Assessment.Decision != "deny" {
		t.Fatal("readonly setting")
	}
	r.ExpectedValueKiB = 1024
	f.calls = nil
	out = owner.runTuning(context.Background(), f, execute, "postgresql")
	if out.Type != "error" || len(f.calls) != 1 {
		t.Fatal("stale setting changed")
	}
}

func TestTuningUnknownSettingIsNotRestoredOrReplayed(t *testing.T) {
	owner := &owner{id: "owner"}
	f := &tuningFake{status: "transaction", settingUnknown: true}
	r := protocol.TuningSettingRequest{Version: 1, Context: *tuningRequest("SELECT id FROM public.items WHERE id = 1").Context, Name: "work_mem", ExpectedValueKiB: 4096, ValueKiB: 8192}
	r.Context.TransactionStatus = "transaction"
	out := owner.runTuning(context.Background(), f, protocol.Command{Type: "tuning.setting", TuningSetting: &r}, "postgresql")
	if out.Type != "error" || !out.OutcomeUnknown || out.SQLNotExecuted || out.TuningSetting != nil || len(f.calls) != 2 {
		t.Fatalf("unknown setting replay/restore or false acknowledgement: %#v calls=%v", out, f.calls)
	}
}

func TestTuningCapabilityVersionAndIdleMetadataBoundaries(t *testing.T) {
	for _, tc := range []struct {
		engine, version string
		want            bool
	}{{"postgresql", "13.20", false}, {"postgresql", "14.25", true}, {"mysql", "5.7.44", false}, {"mysql", "8.0.18", false}, {"mysql", "8.0.29", false}, {"mysql", "8.0.30", true}, {"mysql", "8.4.13", true}, {"mysql", "8.4.13-MariaDB", false}, {"sqlite", "3.49.0", false}} {
		if got := adapter.TuningEngineSupported(adapter.ExplainSupport(tc.engine, tc.version)); got != tc.want {
			t.Errorf("%s %s support %v", tc.engine, tc.version, got)
		}
	}
	r := validationRequest()
	r.Original.Context.TransactionStatus = "transaction"
	r.Variant.Context.TransactionStatus = "transaction"
	if r.Valid() {
		t.Fatal("open user transaction admitted despite idle-only E2 observation")
	}
	inspect := protocol.TuningInspectRequest{Version: 1, Source: r.Original, Capture: tuningCapture(), Target: r.Target}
	if inspect.Valid() {
		t.Fatal("transactional inspect admitted")
	}
}

func TestTuningTransactionSettingObservationIsReadonlyAndOwned(t *testing.T) {
	owner := &owner{id: "owner"}
	f := &tuningFake{status: "transaction"}
	request := protocol.TuningSettingObservationRequest{Version: 1, Context: *tuningRequest("SELECT id FROM public.items WHERE id = 1").Context, Name: "work_mem"}
	request.Context.TransactionStatus = "transaction"
	cmd := protocol.Command{Type: "tuning.setting.observe", TuningSettingObservation: &request}
	out := owner.runTuning(context.Background(), f, cmd, "postgresql")
	if out.TuningSettingObservation == nil || !out.TuningSettingObservation.Valid() || out.TuningSettingObservation.WorkMemKiB != 4096 || f.TransactionStatus() != "transaction" || len(f.calls) != 1 || f.calls[0] != "SHOW work_mem" {
		t.Fatalf("not a fixed readonly observation: %#v", out)
	}
	f.calls = nil
	request.Context.SessionID = "stale"
	out = owner.runTuning(context.Background(), f, cmd, "postgresql")
	if out.Type != "error" || len(f.calls) != 0 {
		t.Fatal("stale owner read current setting")
	}
	request.Context.SessionID = "owner"
	out = owner.runTuning(context.Background(), f, cmd, "mysql")
	if out.Type != "error" || len(f.calls) != 0 {
		t.Fatal("non-PostgreSQL setting read")
	}
}
