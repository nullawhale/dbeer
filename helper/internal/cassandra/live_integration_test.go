package cassandra_test

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/cassandra"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/safety"
	"dbeer/helper/internal/session"
)

func liveConnection(t *testing.T) protocol.Connection {
	t.Helper()
	host := os.Getenv("DBEER_TEST_CASSANDRA_HOST")
	if host == "" {
		if os.Getenv("DBEER_REQUIRE_CASSANDRA") == "1" {
			t.Fatal("required Cassandra fixture is not configured")
		}
		t.Skip("DBEER_TEST_CASSANDRA_HOST is not configured")
	}
	port, err := strconv.Atoi(os.Getenv("DBEER_TEST_CASSANDRA_PORT"))
	if err != nil {
		t.Fatal("invalid Cassandra fixture port")
	}
	return protocol.Connection{Engine: "cassandra", Host: host, Port: port, Database: os.Getenv("DBEER_TEST_CASSANDRA_DATABASE"), User: os.Getenv("DBEER_TEST_CASSANDRA_USER"), Password: os.Getenv("DBEER_TEST_CASSANDRA_PASSWORD"), SSLMode: os.Getenv("DBEER_TEST_CASSANDRA_SSLMODE"), SSLRootCert: os.Getenv("DBEER_TEST_CASSANDRA_CA_FILE"), LocalDatacenter: os.Getenv("DBEER_TEST_CASSANDRA_DATACENTER")}
}
func liveOpen(t *testing.T, c protocol.Connection) adapter.Session {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	s, err := cassandra.Open(ctx, c)
	if err != nil {
		t.Fatalf("Cassandra fixture connection failed: %v", err)
	}
	t.Cleanup(s.Close)
	return s
}
func liveSQL(t *testing.T, s adapter.Session, sql string) protocol.Response {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	r := s.Execute(ctx, protocol.Command{Type: "execute", RequestID: "live", SessionID: "live", QueryID: "live", SQL: sql})
	if r.Type != "query.result" {
		t.Fatalf("Cassandra operation failed: category=%s message=%s", r.Category, r.Message)
	}
	if r.TransactionStatus != "unsupported" || r.SQLState != "" {
		t.Fatal("Cassandra invented transaction state or SQLSTATE")
	}
	return r
}
func liveCatalog(t *testing.T, s adapter.Session, request protocol.CatalogRequest) protocol.Response {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return s.Execute(ctx, protocol.Command{Type: "catalog", RequestID: "catalog", SessionID: "live", QueryID: "catalog", Catalog: &request})
}
func liveValue(t *testing.T, r protocol.Response, column string) *string {
	t.Helper()
	for i, c := range r.Columns {
		if c.Name == column {
			if len(r.Rows) != 1 {
				t.Fatalf("expected one row for column %s", column)
			}
			return r.Rows[0][i]
		}
	}
	t.Fatalf("missing column %s", column)
	return nil
}

type cancelLiveSink struct {
	cancel context.CancelFunc
	rows   int
}

func (*cancelLiveSink) Begin(int, []protocol.Column) error { return nil }
func (s *cancelLiveSink) Row(int, []*string) error         { s.rows++; s.cancel(); return nil }
func (*cancelLiveSink) End(int, protocol.ResultSet) error  { return nil }

func TestCassandraLiveSessionsCQLAndLosslessTypes(t *testing.T) {
	c := liveConnection(t)
	s := liveOpen(t, c)
	other := liveOpen(t, c)
	liveSQL(t, s, "CREATE TYPE IF NOT EXISTS dbeer.live_address (city text, zip int)")
	liveSQL(t, s, "CREATE TABLE IF NOT EXISTS dbeer.live_values (pk int, ck int, empty text, literal text, absent text, exact decimal, huge varint, binary blob, tuple_value frozen<tuple<int,text>>, address frozen<live_address>, items list<text>, tags set<int>, lookup map<text,int>, shared text static, PRIMARY KEY(pk,ck))")
	liveSQL(t, s, "INSERT INTO dbeer.live_values (pk,ck,empty,literal,exact,huge,binary,tuple_value,address,items,tags,lookup,shared) VALUES (1,1,'','NULL',9007199254740993.123456789,1234567890123456789012345678901234567890,0x0001ff,(7,null),{city:'London',zip:123},['a','b'],{1,2},{'x':3},'partition')")
	r := liveSQL(t, s, "SELECT * FROM dbeer.live_values WHERE pk=1 AND ck=1")
	for column, want := range map[string]string{"empty": "", "literal": "NULL", "exact": "9007199254740993.123456789", "huge": "1234567890123456789012345678901234567890", "binary": "AAH/"} {
		v := liveValue(t, r, column)
		if v == nil || *v != want {
			t.Errorf("lossless %s mismatch", column)
		}
	}
	if liveValue(t, r, "absent") != nil {
		t.Fatal("CQL NULL became a scalar zero value")
	}
	for _, column := range []string{"tuple_value", "address", "items", "tags", "lookup"} {
		v := liveValue(t, r, column)
		if v == nil || *v == "" {
			t.Errorf("complex %s value lost", column)
		}
	}
	tuple := liveValue(t, r, "tuple_value")
	if tuple == nil || !strings.Contains(strings.ToLower(*tuple), "null") {
		t.Fatal("tuple NULL lost")
	}
	liveSQL(t, s, "BEGIN UNLOGGED BATCH UPDATE dbeer.live_values SET literal='batch' WHERE pk=1 AND ck=1; INSERT INTO dbeer.live_values (pk,ck,literal) VALUES (1,2,'second'); APPLY BATCH;")
	lwt := liveSQL(t, s, "INSERT INTO dbeer.live_values (pk,ck,literal) VALUES (1,2,'wrong') IF NOT EXISTS")
	applied := liveValue(t, lwt, "[applied]")
	if applied == nil || *applied != "false" {
		t.Fatal("conditional write result lost")
	}
	liveSQL(t, s, "USE dbeer_other")
	if s.(interface{ CurrentKeyspace() string }).CurrentKeyspace() != "dbeer_other" || other.(interface{ CurrentKeyspace() string }).CurrentKeyspace() != "dbeer" {
		t.Fatal("USE changed another tab keyspace")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	cancelled := s.Execute(ctx, protocol.Command{Type: "execute", RequestID: "cancelled", SQL: "SELECT * FROM system.local"})
	if cancelled.Type != "error" || cancelled.OutcomeUnknown {
		t.Fatal("pre-send cancelled read outcome incorrect")
	}
	liveSQL(t, other, "SELECT * FROM dbeer.live_values WHERE pk=1 AND ck=1")
	partial := other.Execute(context.Background(), protocol.Command{Type: "execute", RequestID: "partial", SQL: "SELECT pk FROM dbeer.live_values WHERE pk=1; SELECT * FROM dbeer.missing_table; SELECT pk FROM dbeer.live_values WHERE pk=1;"})
	if partial.Type != "error" || len(partial.ResultSets) != 1 {
		t.Fatal("script did not retain exact completed prefix")
	}
	if strings.HasPrefix(os.Getenv("DBEER_TEST_CASSANDRA_VERSION"), "5") {
		liveSQL(t, other, "CREATE TABLE IF NOT EXISTS dbeer.live_vectors (id int PRIMARY KEY, embedding vector<float,3>)")
		liveSQL(t, other, "INSERT INTO dbeer.live_vectors (id,embedding) VALUES (1,[1.25,2.5,3.75])")
		vector := liveValue(t, liveSQL(t, other, "SELECT embedding FROM dbeer.live_vectors WHERE id=1"), "embedding")
		if vector == nil || !strings.Contains(*vector, "1.25") || !strings.Contains(*vector, "3.75") {
			t.Fatal("Cassandra 5 vector lost")
		}
	}
}

func seedLivePages(t *testing.T, s adapter.Session) {
	t.Helper()
	liveSQL(t, s, "CREATE TABLE IF NOT EXISTS dbeer.live_pages (bucket int,id int,value text,PRIMARY KEY(bucket,id))")
	for start := 0; start < 1205; start += 100 {
		var b strings.Builder
		b.WriteString("BEGIN UNLOGGED BATCH ")
		for i := start; i < start+100 && i < 1205; i++ {
			fmt.Fprintf(&b, "INSERT INTO dbeer.live_pages (bucket,id,value) VALUES (1,%d,'row');", i)
		}
		b.WriteString("APPLY BATCH;")
		liveSQL(t, s, b.String())
	}
}
func TestCassandraLiveBrowsePagingCatalogAndFullExport(t *testing.T) {
	c := liveConnection(t)
	s := liveOpen(t, c)
	seedLivePages(t, s)
	request := protocol.CatalogRequest{Kind: "browse", Schema: "dbeer", Object: "live_pages", ObjectKind: "table"}
	first := liveCatalog(t, s, request)
	if first.Type != "query.result" || len(first.Rows) != 200 || first.NextCursor == "" {
		t.Fatalf("first Cassandra page invalid: category=%s rows=%d cursor=%t", first.Category, len(first.Rows), first.NextCursor != "")
	}
	request.Cursor = first.NextCursor
	second := liveCatalog(t, s, request)
	if second.Type != "query.result" || len(second.Rows) != 200 || second.NextCursor == "" {
		t.Fatal("second Cassandra cursor page invalid")
	}
	if replay := liveCatalog(t, s, request); replay.Type != "error" || replay.Category != "cursor" {
		t.Fatal("one-shot cursor replay accepted")
	}
	request.Cursor = ""
	first = liveCatalog(t, s, request)
	request.Cursor = first.NextCursor
	value := "1"
	request.Filters = []protocol.CatalogFilter{{Column: "bucket", Operator: "eq", Value: &value}}
	if stale := liveCatalog(t, s, request); stale.Type != "error" || stale.Category != "cursor" {
		t.Fatal("changed-filter cursor accepted")
	}
	request.Filters = nil
	request.Cursor = ""
	first = liveCatalog(t, s, request)
	request.Cursor = first.NextCursor
	liveSQL(t, s, "ALTER TABLE dbeer.live_pages ADD schema_added text")
	if stale := liveCatalog(t, s, request); stale.Type != "error" || stale.Category != "cursor" {
		t.Fatal("schema change did not invalidate cursor")
	}
	request.Cursor = ""
	request.Filters = []protocol.CatalogFilter{{Column: "value", Operator: "eq", Value: &value}}
	if invalid := liveCatalog(t, s, request); invalid.Type != "error" || invalid.Category != "unsupported" {
		t.Fatal("unsupported filtering was silently allowed")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancelSink := &cancelLiveSink{cancel: cancel}
	cancelled := s.(adapter.StreamingSession).ExecuteWithSink(ctx, protocol.Command{Type: "execute", RequestID: "cancel-stream", SQL: "SELECT * FROM dbeer.live_pages"}, cancelSink)
	cancel()
	if cancelSink.rows != 1 || cancelled.Type != "error" || cancelled.OutcomeUnknown {
		t.Fatal("active streamed read cancellation was not isolated and known")
	}
	liveSQL(t, liveOpen(t, c), "SELECT id FROM dbeer.live_pages WHERE bucket=1 AND id=0")
	limited := liveSQL(t, s, "SELECT * FROM dbeer.live_pages")
	if limited.RowCount != 1000 || len(limited.Rows) != 1000 || !limited.Truncated {
		t.Fatal("interactive read did not stop at display limit")
	}
	catalog := liveCatalog(t, s, protocol.CatalogRequest{Kind: "completion", Schema: "dbeer"})
	if catalog.Type != "query.result" || len(catalog.Columns) < 9 {
		t.Fatal("CQL completion metadata unavailable")
	}
	for _, format := range []string{"csv", "json"} {
		t.Run(format, func(t *testing.T) { liveFullExport(t, c, format) })
	}
}
func liveFullExport(t *testing.T, c protocol.Connection, format string) {
	t.Helper()
	m := session.New(cassandra.Open)
	defer m.Close()
	if !m.Submit(protocol.Command{Type: "connect", RequestID: "connect", Connection: &c}) {
		t.Fatal("manager stopped")
	}
	receive := func() protocol.Response {
		select {
		case r := <-m.Responses():
			return r
		case <-time.After(90 * time.Second):
			t.Fatal("Cassandra manager response timed out")
			return protocol.Response{}
		}
	}
	connected := receive()
	if connected.Type != "connect.result" {
		t.Fatal("Cassandra manager failed to connect")
	}
	path := filepath.Join(t.TempDir(), "result."+format)
	if !m.Submit(protocol.Command{Type: "execute", RequestID: "export", SessionID: connected.SessionID, QueryID: "export", SQL: "SELECT * FROM dbeer.live_pages", Export: &protocol.ExportRequest{Path: path, Format: format}}) {
		t.Fatal("manager stopped")
	}
	var terminal protocol.Response
	for {
		terminal = receive()
		if terminal.Type == "query.result" || terminal.Type == "error" {
			break
		}
	}
	if terminal.Type != "query.result" || terminal.ExportRowCount != 1205 || terminal.RowCount != 1205 {
		t.Fatalf("full Cassandra export incomplete: type=%s category=%s rows=%d", terminal.Type, terminal.Category, terminal.ExportRowCount)
	}
	bytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("full export file missing")
	}
	if format == "csv" {
		records, err := csv.NewReader(strings.NewReader(string(bytes))).ReadAll()
		if err != nil || len(records) != 1206 {
			t.Fatal("CSV full export row count mismatch")
		}
	} else {
		var document any
		if json.Unmarshal(bytes, &document) != nil {
			t.Fatal("invalid JSON full export")
		}
		if strings.Count(string(bytes), "row") < 1205 {
			t.Fatal("JSON omitted full-export rows")
		}
	}
}

func TestCassandraLiveTLSAndAuthenticationFailures(t *testing.T) {
	c := liveConnection(t)
	if c.SSLMode != "verify-full" {
		t.Skip("authenticated TLS fixture is not selected")
	}
	for _, mutate := range []func(*protocol.Connection){func(c *protocol.Connection) { c.Password = "incorrect-fixture-password" }, func(c *protocol.Connection) { c.SSLRootCert = os.Getenv("DBEER_TEST_CASSANDRA_UNTRUSTED_CA_FILE") }} {
		invalid := c
		mutate(&invalid)
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		s, err := cassandra.Open(ctx, invalid)
		cancel()
		if s != nil {
			s.Close()
		}
		if err == nil {
			t.Fatal("invalid credentials or certificate accepted")
		}
		if strings.Contains(err.Error(), invalid.Password) && invalid.Password != "" {
			t.Fatal("connection diagnostic leaked credentials")
		}
	}
}
func TestCassandraLiveReplicaConsistencyFailure(t *testing.T) {
	c := liveConnection(t)
	if os.Getenv("DBEER_TEST_CASSANDRA_MULTI_NODE") != "1" {
		t.Skip("three-node replica-failure fixture is not selected")
	}
	quorum := liveOpen(t, c)
	liveSQL(t, quorum, "UPDATE dbeer.live_quorum SET value='quorum_available' WHERE id=1")
	c.Consistency = "ALL"
	all := liveOpen(t, c)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	failure := all.Execute(ctx, protocol.Command{Type: "execute", RequestID: "all", SQL: "SELECT * FROM dbeer.live_quorum WHERE id=1"})
	if failure.Type != "error" || failure.OutcomeUnknown {
		t.Fatal("ALL unexpectedly succeeded or a failed read became an unknown write")
	}
	liveSQL(t, quorum, "SELECT * FROM dbeer.live_quorum WHERE id=1")
}

func TestCassandraLiveUserFunctionShadowingIsNotReadOnly(t *testing.T) {
	c := liveConnection(t)
	if os.Getenv("DBEER_TEST_CASSANDRA_UDF") != "1" {
		t.Skip("UDF-enabled isolated fixture is not selected")
	}
	s := liveOpen(t, c)
	liveSQL(t, s, `CREATE OR REPLACE FUNCTION dbeer.uuid(input int) CALLED ON NULL INPUT RETURNS text LANGUAGE java AS 'return "harmless-marker";'`)
	liveSQL(t, s, "CREATE TABLE IF NOT EXISTS dbeer.live_udf (id int PRIMARY KEY)")
	liveSQL(t, s, "INSERT INTO dbeer.live_udf (id) VALUES (1)")
	result := liveSQL(t, s, "SELECT uuid(id) FROM dbeer.live_udf WHERE id=1")
	if len(result.Rows) != 1 || len(result.Rows[0]) != 1 || result.Rows[0][0] == nil || *result.Rows[0][0] != "harmless-marker" {
		t.Fatal("unqualified built-in-looking UDF overload was not resolved in current keyspace")
	}
	native := liveSQL(t, s, "SELECT system.uuid() FROM dbeer.live_udf WHERE id=1")
	if len(native.Rows) != 1 || native.Rows[0][0] == nil || *native.Rows[0][0] == "harmless-marker" {
		t.Fatal("explicit native namespace did not resolve the system function")
	}
	statement := "SELECT uuid(id) FROM dbeer.live_udf WHERE id=1"
	assessment := safety.Classify("cassandra", statement)
	if len(assessment) != 1 || assessment[0].Kind == safety.Read {
		t.Fatal("built-in-looking keyspace UDF bypasses conservative CQL assessment")
	}
	c.Policy = &protocol.ExecutionPolicy{Environment: "development", ReadOnly: true}
	manager := session.New(cassandra.Open)
	defer manager.Close()
	manager.Submit(protocol.Command{Type: "connect", RequestID: "udf-connect", Connection: &c})
	var connected protocol.Response
	select {
	case connected = <-manager.Responses():
	case <-time.After(20 * time.Second):
		t.Fatal("readonly UDF fixture connection timed out")
	}
	if connected.Type != "connect.result" {
		t.Fatal("readonly UDF fixture did not connect")
	}
	manager.Submit(protocol.Command{Type: "execute", RequestID: "udf", SessionID: connected.SessionID, QueryID: "udf", SQL: statement})
	select {
	case rejected := <-manager.Responses():
		if rejected.Type != "error" || rejected.Category != "policy" || rejected.OutcomeUnknown {
			t.Fatal("local readonly allowed unknown UDF execution")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("readonly UDF policy did not respond")
	}
	manager.Submit(protocol.Command{Type: "execute", RequestID: "native-read", SessionID: connected.SessionID, QueryID: "native-read", SQL: "SELECT system.uuid() FROM dbeer.live_udf WHERE id=1"})
	for {
		select {
		case reply := <-manager.Responses():
			if reply.Type == "error" {
				t.Fatal("readonly rejected explicit native function")
			}
			if reply.Type == "query.result" {
				return
			}
		case <-time.After(10 * time.Second):
			t.Fatal("readonly native function did not complete")
		}
	}
}

type failingLiveSink struct{ stage string }

func (s failingLiveSink) Begin(int, []protocol.Column) error {
	if s.stage == "begin" {
		return fmt.Errorf("fixture delivery failure")
	}
	return nil
}
func (s failingLiveSink) Row(int, []*string) error {
	if s.stage == "row" {
		return fmt.Errorf("fixture delivery failure")
	}
	return nil
}
func (failingLiveSink) End(int, protocol.ResultSet) error { return nil }
func TestCassandraLiveAcknowledgedWritesSurviveDeliveryAndExportFailures(t *testing.T) {
	c := liveConnection(t)
	s := liveOpen(t, c)
	liveSQL(t, s, "CREATE TABLE IF NOT EXISTS dbeer.live_delivery (id int PRIMARY KEY,value text)")
	liveSQL(t, s, "INSERT INTO dbeer.live_delivery (id,value) VALUES (1,'collision')")
	for _, check := range []struct{ stage, sql string }{
		{"begin", "UPDATE dbeer.live_delivery SET value='collision' WHERE id=1"},
		{"row", "INSERT INTO dbeer.live_delivery (id,value) VALUES (1,'unused') IF NOT EXISTS"},
	} {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		r := s.(adapter.StreamingSession).ExecuteWithSink(ctx, protocol.Command{Type: "execute", RequestID: "delivery", SQL: check.sql}, failingLiveSink{stage: check.stage})
		cancel()
		if r.Type != "error" || r.OutcomeUnknown || !r.SQLCompleted || !r.Connected || r.ExportPublication != "" || len(r.ResultSets) != 1 {
			t.Fatalf("acknowledged %s write lost completion evidence: type=%s category=%s", check.stage, r.Type, r.Category)
		}
	}
	manager := session.New(cassandra.Open)
	defer manager.Close()
	manager.Submit(protocol.Command{Type: "connect", RequestID: "collision-connect", Connection: &c})
	receive := func() protocol.Response {
		select {
		case r := <-manager.Responses():
			return r
		case <-time.After(30 * time.Second):
			t.Fatal("acknowledged export response timed out")
			return protocol.Response{}
		}
	}
	connected := receive()
	if connected.Type != "connect.result" {
		t.Fatal("acknowledged export fixture did not connect")
	}
	marker := "collision"
	path := filepath.Join(t.TempDir(), "collision.csv")
	manager.Submit(protocol.Command{Type: "execute", RequestID: "collision", SessionID: connected.SessionID, QueryID: "collision", SQL: "INSERT INTO dbeer.live_delivery (id,value) VALUES (1,'unused') IF NOT EXISTS", Export: &protocol.ExportRequest{Path: path, Format: "csv", NullMarker: &marker}})
	for {
		r := receive()
		if r.Type == "query.started" || r.Type == "query.progress" {
			continue
		}
		if r.Type != "error" || r.Category != "export" || r.OutcomeUnknown || !r.SQLCompleted || r.ExportPublication != "notPublished" || len(r.ResultSets) != 1 {
			t.Fatalf("acknowledged LWT export confused delivery failure with write loss: type=%s category=%s", r.Type, r.Category)
		}
		break
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("failed LWT export was published")
	}
}
func TestCassandraLiveUDTFieldsAndWideEmptyResultsStayBounded(t *testing.T) {
	c := liveConnection(t)
	s := liveOpen(t, c)
	liveSQL(t, s, "CREATE TYPE IF NOT EXISTS dbeer.live_details (city text,zip int)")
	fields := liveCatalog(t, s, protocol.CatalogRequest{Kind: "columns", Schema: "dbeer", Object: "live_details", ObjectKind: "type"})
	if fields.Type != "query.result" || len(fields.Rows) != 2 {
		t.Fatal("UDT fields not available in catalog columns")
	}
	var ddl strings.Builder
	ddl.WriteString("CREATE TABLE IF NOT EXISTS dbeer.live_wide (id int PRIMARY KEY")
	for i := 0; i < 512; i++ {
		fmt.Fprintf(&ddl, ", column_%03d text", i)
	}
	ddl.WriteByte(')')
	liveSQL(t, s, ddl.String())
	script := strings.Repeat("SELECT * FROM dbeer.live_wide;", 512)
	for _, streamed := range []bool{false, true} {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		command := protocol.Command{Type: "execute", RequestID: "wide", SessionID: "wide", QueryID: "wide", SQL: script}
		var r protocol.Response
		if streamed {
			r = s.(adapter.StreamingSession).ExecuteWithSink(ctx, command, failingLiveSink{})
		} else {
			r = s.Execute(ctx, command)
		}
		cancel()
		encoded, err := json.Marshal(r)
		if err != nil || len(encoded) >= protocol.MaxFrameBytes || r.OutcomeUnknown || len(r.ResultSets) >= 512 {
			t.Fatal("wide empty result metadata exceeded the bounded response budget")
		}
	}
}

func TestCassandraLiveSpecialSelectorsAndNativeFunctions(t *testing.T) {
	c := liveConnection(t)
	s := liveOpen(t, c)
	liveSQL(t, s, "CREATE TABLE IF NOT EXISTS dbeer.live_selectors (id int PRIMARY KEY,value text)")
	liveSQL(t, s, "INSERT INTO dbeer.live_selectors (id,value) VALUES (1,'selector')")
	statement := "SELECT TTL(value) AS expiry,WRITETIME(value) AS written,CAST(id AS text) AS identifier FROM dbeer.live_selectors WHERE id=1"
	result := liveSQL(t, s, statement)
	if liveValue(t, result, "expiry") != nil || liveValue(t, result, "written") == nil || liveValue(t, result, "identifier") == nil || *liveValue(t, result, "identifier") != "1" {
		t.Fatal("CQL special selector semantics changed")
	}
	count := liveSQL(t, s, "SELECT COUNT(*) AS total FROM dbeer.live_selectors")
	if value := liveValue(t, count, "total"); value == nil || *value != "1" {
		t.Fatal("CQL count star selector failed")
	}
	native := liveSQL(t, s, "SELECT system.uuid() AS identifier FROM dbeer.live_selectors WHERE id=1")
	if liveValue(t, native, "identifier") == nil {
		t.Fatal("ordinary native function namespace unavailable")
	}
	c.Policy = &protocol.ExecutionPolicy{Environment: "development", ReadOnly: true}
	manager := session.New(cassandra.Open)
	defer manager.Close()
	manager.Submit(protocol.Command{Type: "connect", RequestID: "selector-connect", Connection: &c})
	var connected protocol.Response
	select {
	case connected = <-manager.Responses():
	case <-time.After(20 * time.Second):
		t.Fatal("readonly selector fixture did not connect")
	}
	if connected.Type != "connect.result" {
		t.Fatal("readonly selector connection failed")
	}
	manager.Submit(protocol.Command{Type: "execute", RequestID: "selector", SessionID: connected.SessionID, QueryID: "selector", SQL: statement})
	for {
		select {
		case response := <-manager.Responses():
			if response.Type == "error" {
				t.Fatal("readonly rejected non-overridable CQL selectors")
			}
			if response.Type == "query.result" {
				return
			}
		case <-time.After(20 * time.Second):
			t.Fatal("readonly CQL selectors timed out")
		}
	}
}

func TestCassandraLiveGeneratedNativeFunctionCompletions(t *testing.T) {
	c := liveConnection(t)
	s := liveOpen(t, c)
	liveSQL(t, s, "CREATE TABLE IF NOT EXISTS dbeer.live_functions (id int PRIMARY KEY,value text)")
	liveSQL(t, s, "INSERT INTO dbeer.live_functions (id,value) VALUES (1,'function')")
	for _, check := range []struct{ name, expression string }{
		{"COUNT", "COUNT(*)"}, {"SUM", "system.SUM(id)"}, {"AVG", "system.AVG(id)"}, {"MIN", "system.MIN(id)"}, {"MAX", "system.MAX(id)"},
		{"TOKEN", "system.TOKEN(id)"}, {"TTL", "TTL(value)"}, {"WRITETIME", "WRITETIME(value)"},
		{"UUID", "system.UUID()"}, {"NOW", "system.NOW()"}, {"CURRENTTIMESTAMP", "system.CURRENTTIMESTAMP()"},
		{"CURRENTDATE", "system.CURRENTDATE()"}, {"CURRENTTIME", "system.CURRENTTIME()"}, {"CURRENTTIMEUUID", "system.CURRENTTIMEUUID()"},
		{"TODATE", "system.TODATE(system.CURRENTTIMESTAMP())"}, {"TOTIMESTAMP", "system.TOTIMESTAMP(system.NOW())"},
		{"TOUNIXTIMESTAMP", "system.TOUNIXTIMESTAMP(system.NOW())"},
		{"MINTIMEUUID", "system.MINTIMEUUID(system.CURRENTTIMESTAMP())"}, {"MAXTIMEUUID", "system.MAXTIMEUUID(system.CURRENTTIMESTAMP())"},
		{"CAST", "CAST(id AS text)"}, {"TOJSON", "system.TOJSON(value)"},
	} {
		t.Run(check.name, func(t *testing.T) { liveSQL(t, s, "SELECT "+check.expression+" FROM dbeer.live_functions WHERE id=1") })
	}
}
