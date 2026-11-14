package session_test

import (
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/session"
	"dbeer/helper/internal/tableedit"
	"os"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
)

func TestTuningPostgresLive(t *testing.T) {
	h := newPGHarness(t)
	exerciseTuningLive(t, h.manager, h.connection, "postgresql", "public")
}
func TestTuningMySQLLive(t *testing.T) {
	port, err := strconv.Atoi(os.Getenv("DBEER_TEST_MYSQL_PORT"))
	if err != nil || port < 1 {
		t.Skip("MySQL disposable fixture missing")
	}
	c := protocol.Connection{Engine: "mysql", Host: "localhost", Port: port, Database: os.Getenv("DBEER_TEST_MYSQL_DATABASE"), User: os.Getenv("DBEER_TEST_MYSQL_USER"), Password: os.Getenv("DBEER_TEST_MYSQL_PASSWORD"), SSLMode: "disable"}
	m := session.New(mysql.Open)
	defer m.Close()
	exerciseTuningLive(t, m, c, "mysql", c.Database)
}
func exerciseTuningLive(t *testing.T, m *session.Manager, c protocol.Connection, engine, schema string) {
	t.Helper()
	seq := 0
	id := func() string { seq++; return "tuning-live-" + strconv.Itoa(seq) }
	receive := func() protocol.Response {
		select {
		case r := <-m.Responses():
			return r
		case <-time.After(45 * time.Second):
			t.Fatal("tuning fixture response timed out")
			return protocol.Response{}
		}
	}
	send := func(c protocol.Command) protocol.Response {
		if !m.Submit(c) {
			t.Fatal("tuning manager stopped")
		}
		r := receive()
		if r.Type == "query.started" {
			r = receive()
		}
		return r
	}
	connected := send(protocol.Command{Type: "connect", RequestID: id(), Connection: &c})
	if connected.Type != "connect.result" || !slices.Contains(connected.Capabilities, protocol.TuningCapability) {
		t.Fatal("tuning owner capability missing")
	}
	sid := connected.SessionID
	t.Logf("Tuning live engine %s server %s", engine, connected.ExplainSupport.ServerVersion)
	execute := func(sql string) protocol.Response {
		q := id()
		assessed := send(protocol.Command{Type: "operation.assess", RequestID: q, SessionID: sid, QueryID: q, Operations: []protocol.OperationRequest{{Type: "execute", SQL: sql}}})
		if assessed.Assessment == nil || assessed.Assessment.Decision == "deny" {
			t.Fatal("owned fixture assessment failed")
		}
		q = id()
		r := send(protocol.Command{Type: "execute", RequestID: q, SessionID: sid, QueryID: q, SQL: sql, Authorization: assessed.Assessment.Authorization})
		if r.Type != "query.result" {
			t.Fatalf("owned fixture SQL failed: %s %s", r.Category, r.Message)
		}
		return r
	}
	target := tableedit.Target{Schema: schema, Table: "f7_tuning_items"}
	name := schema + "." + target.Table
	// These objects belong to this test's disposable database, never a saved profile.
	payloadType, payloadValue := "bytea", `decode('0001ff','hex')`
	if engine == "mysql" {
		payloadType, payloadValue = "blob", "X'0001ff'"
	}
	execute("CREATE TABLE " + name + " (id bigint, note text, amount numeric(30,3), payload " + payloadType + ")")
	execute("INSERT INTO " + name + " VALUES (1,NULL,9007199254740993.125," + payloadValue + "),(1,'',9007199254740993.125," + payloadValue + "),(2,'NULL',0.000," + payloadValue + ")")
	source := protocol.ExplainRequest{SQL: "SELECT id, note, amount, payload FROM " + name + " WHERE id = 1 OR id = 2", Mode: "plan", Context: &protocol.ExplainContext{DocumentID: "source", TargetDocumentID: "source", ProfileID: "profile", SessionID: sid, TransactionStatus: "idle"}}
	source.Context.RangeLength = len(utf16.Encode([]rune(source.SQL)))
	if engine == "mysql" {
		source.Options = &protocol.ExplainOptions{MySQL: &protocol.MySQLExplainOptions{Format: "json"}}
	}
	grant := func(op protocol.OperationRequest, decision string) string {
		q := id()
		r := send(protocol.Command{Type: "operation.assess", RequestID: q, SessionID: sid, QueryID: q, Operations: []protocol.OperationRequest{op}})
		if r.Assessment == nil || r.Assessment.Decision != decision {
			t.Fatalf("tuning assessment: %s %s", r.Type, r.Message)
		}
		return r.Assessment.Authorization
	}
	q := id()
	plan := send(protocol.Command{Type: "explain.run", RequestID: q, SessionID: sid, QueryID: q, Explain: &source, Authorization: grant(protocol.OperationRequest{Type: "explain.run", Explain: &source}, "allow")})
	if plan.Explain == nil || !plan.Explain.Valid() {
		t.Fatalf("plan missing %s", plan.Message)
	}
	q = id()
	inspection := send(protocol.Command{Type: "tuning.inspect", RequestID: q, SessionID: sid, QueryID: q, TuningInspect: &protocol.TuningInspectRequest{Version: 1, Source: source, Capture: *plan.Explain, Target: target}})
	if inspection.TuningInspection == nil || len(inspection.TuningInspection.Indexes) != 1 || len(inspection.TuningInspection.Variants) != 1 {
		t.Fatalf("useful candidate unavailable: %s %s %#v", inspection.Category, inspection.Message, inspection.TuningInspection)
	}
	candidate := inspection.TuningInspection.Variants[0].Request
	validation := protocol.TuningValidationRequest{Version: 1, Original: source, Variant: candidate, Target: target, MetadataFingerprint: inspection.TuningInspection.MetadataFingerprint, MaxRows: 100, MaxBytes: 65536, TimeoutMS: 5000, Comparison: "multiset"}
	validate := func(r *protocol.TuningValidationRequest) protocol.Response {
		q := id()
		return send(protocol.Command{Type: "tuning.validate", RequestID: q, SessionID: sid, QueryID: q, TuningValidation: r, Authorization: grant(protocol.OperationRequest{Type: "tuning.validate", TuningValidation: r}, "confirm")})
	}
	result := validate(&validation)
	if result.TuningValidation == nil || result.TuningValidation.State != "observedEqual" || result.TuningValidation.OriginalRows != 3 || result.TuningValidation.VariantRows != 3 {
		t.Fatalf("native observation failed: %s %s %#v", result.Category, result.Message, result.TuningValidation)
	}
	validation.MaxRows = 1
	result = validate(&validation)
	if result.TuningValidation == nil || result.TuningValidation.State != "inconclusive" || result.TuningValidation.Complete {
		t.Fatal("bounded partial result claimed equality")
	}
	validation.MaxRows = 100
	// A new schema/index fingerprint cannot borrow an older validation review.
	execute("CREATE INDEX f7_existing_id ON " + name + " (id)")
	result = validate(&validation)
	if result.Type != "error" || result.Category != "conflict" {
		t.Fatal("stale metadata authorized validation")
	}
	q = id()
	inspection = send(protocol.Command{Type: "tuning.inspect", RequestID: q, SessionID: sid, QueryID: q, TuningInspect: &protocol.TuningInspectRequest{Version: 1, Source: source, Capture: *plan.Explain, Target: target}})
	if inspection.TuningInspection == nil || len(inspection.TuningInspection.Indexes) != 0 {
		t.Fatal("existing index candidate duplicated")
	}
	validation.MetadataFingerprint = inspection.TuningInspection.MetadataFingerprint
	result = validate(&validation)
	if result.TuningValidation == nil || result.TuningValidation.State != "observedEqual" {
		t.Fatalf("safe existing index rejected validation: %s %s", result.Category, result.Message)
	}

	if engine == "postgresql" {
		execute("BEGIN")
		observe := protocol.TuningSettingObservationRequest{Version: 1, Context: *source.Context, Name: "work_mem"}
		observe.Context.TransactionStatus = "transaction"
		q = id()
		current := send(protocol.Command{Type: "tuning.setting.observe", RequestID: q, SessionID: sid, QueryID: q, TuningSettingObservation: &observe})
		if current.TuningSettingObservation == nil || current.TransactionStatus != "transaction" {
			t.Fatalf("current transaction observation failed: %s", current.Message)
		}
		setting := protocol.TuningSettingRequest{Version: 1, Context: *source.Context, Name: "work_mem", ExpectedValueKiB: current.TuningSettingObservation.WorkMemKiB, ValueKiB: current.TuningSettingObservation.WorkMemKiB + 64}
		setting.Context.TransactionStatus = "transaction"
		apply := func(r *protocol.TuningSettingRequest) protocol.Response {
			q := id()
			return send(protocol.Command{Type: "tuning.setting", RequestID: q, SessionID: sid, QueryID: q, TuningSetting: r, Authorization: grant(protocol.OperationRequest{Type: "tuning.setting", TuningSetting: r}, "confirm")})
		}
		changed := apply(&setting)
		if changed.TuningSetting == nil || changed.TuningSetting.State != "applied" {
			t.Fatalf("setting apply: %s %s", changed.Category, changed.Message)
		}
		restored := apply(&changed.TuningSetting.Restore)
		if restored.TuningSetting == nil || restored.TuningSetting.RequestedKiB != setting.ExpectedValueKiB {
			t.Fatal("separately reviewed restore failed")
		}
		execute("ROLLBACK")
		// Explicit pg_catalog-last operator lookup is refused before user SELECT.
		execute("SET search_path = public, pg_catalog")
		q = id()
		blocked := send(protocol.Command{Type: "tuning.inspect", RequestID: q, SessionID: sid, QueryID: q, TuningInspect: &protocol.TuningInspectRequest{Version: 1, Source: source, Capture: *plan.Explain, Target: target}})
		if blocked.Type != "error" || !strings.Contains(blocked.Message, "search path") {
			t.Fatal("custom operator lookup not refused")
		}
	}
	q = id()
	_ = send(protocol.Command{Type: "disconnect", RequestID: q, SessionID: sid})
}
