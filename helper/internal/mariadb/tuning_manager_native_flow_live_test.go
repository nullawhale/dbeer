package mariadb_test

import (
	"context"
	"fmt"
	"os"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf16"

	"dbeer/helper/internal/mariadb"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/session"
	"dbeer/helper/internal/tableedit"
)

func tuningFlowSettings(t *testing.T) protocol.Connection {
	t.Helper()
	port, e := strconv.Atoi(os.Getenv("DBEER_TEST_MARIADB_PORT"))
	if e != nil {
		if os.Getenv("DBEER_REQUIRE_MARIADB") == "1" {
			t.Fatal("required native endpoint missing")
		}
		t.Skip("native endpoint not configured")
	}
	user, password := os.Getenv("DBEER_TEST_MARIADB_ADMIN_USER"), os.Getenv("DBEER_TEST_MARIADB_ADMIN_PASSWORD")
	if user == "" || password == "" {
		t.Fatal("owned GLOBAL-metadata actor is required; use official optional ADMIN fixture")
	}
	mode := os.Getenv("DBEER_TEST_MARIADB_SSLMODE")
	if mode == "" {
		mode = "disable"
	}
	if os.Getenv("DBEER_REQUIRE_MARIADB_TLS") == "1" {
		mode = "verify-full"
		if os.Getenv("DBEER_TEST_MARIADB_CA_FILE") == "" {
			t.Fatal("required native CA missing")
		}
	}
	return protocol.Connection{Engine: "mariadb", Host: os.Getenv("DBEER_TEST_MARIADB_HOST"), Port: port, Database: os.Getenv("DBEER_TEST_MARIADB_DATABASE"), User: user, Password: password, SSLMode: mode, SSLRootCert: os.Getenv("DBEER_TEST_MARIADB_CA_FILE"), Policy: &protocol.ExecutionPolicy{Environment: "production"}}
}
func TestMariaDBTuningNativeManagerOptimizerReviewAndScope(t *testing.T) {
	settings := tuningFlowSettings(t)
	setup, e := mariadb.Open(context.Background(), settings)
	if e != nil {
		t.Fatal("native tuning fixture unavailable")
	}
	defer setup.Close()
	target := tableedit.Target{Schema: settings.Database, Table: fmt.Sprintf("g1_tuning_%d", time.Now().UnixNano())}
	qualified := mariadb.QuoteIdentifier(target.Schema) + "." + mariadb.QuoteIdentifier(target.Table)
	raw := func(sql string) protocol.Response {
		t.Helper()
		r := setup.Execute(context.Background(), protocol.Command{SQL: sql})
		if r.Type != "query.result" {
			t.Fatalf("native tuning scaffold failed: %s/%s", r.Category, r.SQLState)
		}
		return r
	}
	raw("CREATE TABLE " + qualified + "(id BIGINT,calls INTEGER NOT NULL DEFAULT 0) ENGINE=InnoDB")
	defer raw("DROP TABLE IF EXISTS " + qualified)
	raw("INSERT INTO " + qualified + "(id) VALUES(1),(1),(2)")
	manager := session.New(mariadb.Open)
	defer manager.Close()
	seq := 0
	id := func() string { seq++; return "maria-tuning-" + strconv.Itoa(seq) }
	send := func(c protocol.Command) protocol.Response {
		t.Helper()
		if c.RequestID == "" {
			c.RequestID = id()
		}
		if !manager.Submit(c) {
			t.Fatal("normal tuning Manager stopped")
		}
		for {
			select {
			case r := <-manager.Responses():
				if r.RequestID != c.RequestID {
					t.Fatal("normal tuning response lost correlation")
				}
				if r.Type == "query.started" {
					continue
				}
				return r
			case <-time.After(15 * time.Second):
				t.Fatal("normal tuning response timed out")
				return protocol.Response{}
			}
		}
	}
	connected := send(protocol.Command{Type: "connect", Connection: &settings})
	if connected.Type != "connect.result" || connected.Engine != "mariadb" || !slices.Contains(connected.Capabilities, protocol.TuningCapability) {
		t.Fatal("normal native tuning owner/capability missing")
	}
	owner := connected.SessionID
	assess := func(op protocol.OperationRequest, decision string) string {
		t.Helper()
		r := send(protocol.Command{Type: "operation.assess", SessionID: owner, Operations: []protocol.OperationRequest{op}})
		if r.Assessment == nil || r.Assessment.Decision != decision {
			t.Fatalf("native exact review decision failed: %s", r.Category)
		}
		return r.Assessment.Authorization
	}
	execute := func(sql string) protocol.Response {
		t.Helper()
		op := protocol.OperationRequest{Type: "execute", SQL: sql}
		a := send(protocol.Command{Type: "operation.assess", SessionID: owner, Operations: []protocol.OperationRequest{op}})
		if a.Assessment == nil || a.Assessment.Decision == "deny" {
			t.Fatal("native owner control was refused")
		}
		r := send(protocol.Command{Type: "execute", SessionID: owner, QueryID: id(), SQL: sql, Authorization: a.Assessment.Authorization})
		if r.Type != "query.result" {
			t.Fatalf("native owner control failed: %s/%s", r.Category, r.SQLState)
		}
		return r
	}
	stateSQL := "SELECT @@SESSION.optimizer_switch,@@SESSION.time_zone,@@SESSION.sql_mode,@@SESSION.tx_isolation,@@SESSION.character_set_client,@@SESSION.character_set_connection,@@SESSION.character_set_results"
	before := execute(stateSQL).Rows
	queryTable := target.Schema + "." + target.Table
	for _, b := range []byte(queryTable) {
		if !(b >= 'a' && b <= 'z' || b >= '0' && b <= '9' || b == '_' || b == '.') {
			t.Fatal("fixture requires synthetic ASCII tuning identifiers")
		}
	}
	source := protocol.ExplainRequest{SQL: "SELECT id,calls FROM " + queryTable + " WHERE calls=0", Mode: "plan", Context: &protocol.ExplainContext{DocumentID: "source", TargetDocumentID: "source", ProfileID: "profile", SessionID: owner, TransactionStatus: "idle"}}
	source.Context.RangeLength = len(utf16.Encode([]rune(source.SQL)))
	plan := send(protocol.Command{Type: "explain.run", SessionID: owner, QueryID: id(), Explain: &source, Authorization: assess(protocol.OperationRequest{Type: "explain.run", Explain: &source}, "allow")})
	if plan.Explain == nil || !plan.Explain.Valid() {
		t.Fatalf("native tuning capture failed: %s", plan.Category)
	}
	inspection := send(protocol.Command{Type: "tuning.inspect", SessionID: owner, QueryID: id(), TuningInspect: &protocol.TuningInspectRequest{Version: 1, Source: source, Capture: *plan.Explain, Target: target}})
	if inspection.TuningInspection == nil || inspection.TuningInspection.MariaDBOptimizer == nil {
		t.Fatalf("native ordinary tuning metadata/switch unavailable: %s", inspection.Category)
	}
	observed := inspection.TuningInspection.MariaDBOptimizer
	if !observed.Valid() || before[0][0] == nil || observed.NativeSwitch != *before[0][0] {
		t.Fatal("optimizer inspection did not bind exact current native string")
	}
	validation := protocol.TuningValidationRequest{Version: 1, Original: source, Variant: source, Target: target, MetadataFingerprint: inspection.TuningInspection.MetadataFingerprint, MaxRows: 100, MaxBytes: 65536, TimeoutMS: 5000, Comparison: "multiset", MariaDBOptimizer: &protocol.MariaDBOptimizerVariant{ExpectedNativeSwitch: observed.NativeSwitch, IndexConditionPushdown: !observed.IndexConditionPushdown}}
	command := protocol.Command{Type: "tuning.validate", SessionID: owner, QueryID: id(), TuningValidation: &validation}
	if r := send(command); r.Category != "policy" {
		t.Fatal("native optimizer validation bypassed exact review")
	}
	command.Authorization = assess(protocol.OperationRequest{Type: "tuning.validate", TuningValidation: &validation}, "confirm")
	result := send(command)
	if result.TuningValidation == nil || !result.TuningValidation.Complete || result.TuningValidation.State != "observedEqual" || result.TuningValidation.OriginalRows != 3 || result.TuningValidation.VariantRows != 3 || result.TransactionStatus != "idle" {
		t.Fatalf("native statement optimizer validation failed: %s", result.Category)
	}
	if r := send(command); r.Category != "policy" {
		t.Fatal("native optimizer review was replayed")
	}
	if !reflect.DeepEqual(before, execute(stateSQL).Rows) {
		t.Fatal("native statement optimizer trial changed session settings")
	}
	if *raw("SELECT SUM(calls) FROM " + qualified).Rows[0][0] != "0" {
		t.Fatal("native tuning trial changed source data")
	}
	// A current-session transaction cannot be finished or silently used by an idle trial.
	execute("BEGIN")
	if r := send(protocol.Command{Type: "tuning.inspect", SessionID: owner, QueryID: id(), TuningInspect: &protocol.TuningInspectRequest{Version: 1, Source: source, Capture: *plan.Explain, Target: target}}); r.TuningInspection != nil || r.TransactionStatus != "transaction" {
		t.Fatal("stale idle tuning context changed an active transaction")
	}
	execute("ROLLBACK")
	// Genuine native partition metadata must hit the first Advanced refusal.
	partition := target.Table + "_partition"
	partitionQ := mariadb.QuoteIdentifier(target.Schema) + "." + mariadb.QuoteIdentifier(partition)
	raw("CREATE TABLE " + partitionQ + "(id BIGINT,calls INT) ENGINE=InnoDB PARTITION BY HASH(id) PARTITIONS 2")
	defer raw("DROP TABLE IF EXISTS " + partitionQ)
	advanced := source
	advanced.SQL = "SELECT id,calls FROM " + target.Schema + "." + partition + " WHERE calls=0"
	contextCopy := *source.Context
	contextCopy.RangeLength = len(utf16.Encode([]rune(advanced.SQL)))
	advanced.Context = &contextCopy
	capture := send(protocol.Command{Type: "explain.run", SessionID: owner, QueryID: id(), Explain: &advanced, Authorization: assess(protocol.OperationRequest{Type: "explain.run", Explain: &advanced}, "allow")})
	if capture.Explain == nil {
		t.Fatal("native partition plan scaffold failed")
	}
	rejected := send(protocol.Command{Type: "tuning.inspect", SessionID: owner, QueryID: id(), TuningInspect: &protocol.TuningInspectRequest{Version: 1, Source: advanced, Capture: *capture.Explain, Target: tableedit.Target{Schema: target.Schema, Table: partition}}})
	if rejected.TuningInspection != nil || rejected.Category != "validation" || !strings.Contains(rejected.Message, "ordinary table") {
		t.Fatal("native advanced table bypassed the first tuning refusal")
	}
}
