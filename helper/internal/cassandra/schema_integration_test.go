package cassandra_test

import (
	"context"
	"errors"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/cassandra"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/safety"
	sc "dbeer/helper/internal/schemacompare"
	tc "dbeer/helper/internal/tablecapture"
)

type comparisonRows struct {
	rows [][]*string
	err  error
}

func (s *comparisonRows) Row(row []*string) error {
	if s.err != nil {
		return s.err
	}
	s.rows = append(s.rows, row)
	return nil
}

func TestCassandraLiveSchemaAndDataComparisonTypes(t *testing.T) {
	s := liveOpen(t, liveConnection(t))
	liveSQL(t, s, `DROP KEYSPACE IF EXISTS dbeer_types_compare`)
	t.Cleanup(func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = s.Execute(cleanupCtx, protocol.Command{Type: "execute", RequestID: "cleanup-types", SQL: `DROP KEYSPACE IF EXISTS dbeer_types_compare`})
	})
	liveSQL(t, s, `CREATE KEYSPACE IF NOT EXISTS dbeer_types_compare WITH replication = {'class':'NetworkTopologyStrategy','datacenter1':1}`)
	liveSQL(t, s, `CREATE TYPE IF NOT EXISTS dbeer_types_compare.details (city text,amounts frozen<map<text,decimal>>,pair tuple<int,text>)`)
	vectorDefinition, vectorNames, vectorValues := "", "", ""
	if strings.HasPrefix(os.Getenv("DBEER_TEST_CASSANDRA_VERSION"), "5.") {
		vectorDefinition = ",ve vector<float,3>"
		vectorNames = ",ve"
		vectorValues = ",[1.25,-2.5,0]"
	}
	liveSQL(t, s, `CREATE TABLE dbeer_types_compare.every_type (id int,ck int,static_value text STATIC,a ascii,bi bigint,bl blob,b boolean,da date,de decimal,db double,du duration,fl float,ip inet,sm smallint,tx text,tm time,ts timestamp,tu timeuuid,ti tinyint,ui uuid,vi varint,li list<text>,se set<int>,mp map<text,frozen<tuple<int,text>>>,tp tuple<int,text>,ud frozen<details>`+vectorDefinition+`,PRIMARY KEY(id,ck)) WITH CLUSTERING ORDER BY (ck DESC) AND default_time_to_live=0 AND comment='type '' matrix'`)
	liveSQL(t, s, `INSERT INTO dbeer_types_compare.every_type (id,ck,static_value,a,bi,bl,b,da,de,db,du,fl,ip,sm,tx,tm,ts,tu,ti,ui,vi,li,se,mp,tp,ud`+vectorNames+`) VALUES (1,0,'static','ascii',9223372036854775807,0x00ff,true,'2024-02-29',12345678901234567890.0000012300,1.25,1mo2d3ns,-2.5,'2001:db8::1',32767,'NULL','23:59:59.999999999',-9223372036854775808,50554d6e-29bb-11e5-b345-feff819cdc9f,-128,550e8400-e29b-41d4-a716-446655440000,123456789012345678901234567890,['NULL','','a''b'],{1,2},{'x':(7,'text')},(null,'NULL'),{city:'city',amounts:{'amount':1.0000},pair:(1,null)}`+vectorValues+` )`)
	liveSQL(t, s, `INSERT INTO dbeer_types_compare.every_type (id,ck,bl,tx,tp) VALUES (1,1,0x,'',(null,null))`)
	liveSQL(t, s, `CREATE INDEX every_type_text ON dbeer_types_compare.every_type (tx)`)
	liveSQL(t, s, `CREATE TABLE dbeer_types_compare.view_base (id int,ck int,tx text,PRIMARY KEY(id,ck))`)
	liveSQL(t, s, `CREATE MATERIALIZED VIEW dbeer_types_compare.type_view AS SELECT id,ck,tx FROM dbeer_types_compare.view_base WHERE id IS NOT NULL AND ck IS NOT NULL PRIMARY KEY(id,ck)`)
	liveSQL(t, s, `CREATE TABLE dbeer_types_compare.counters (id int PRIMARY KEY,value counter)`)
	liveSQL(t, s, `UPDATE dbeer_types_compare.counters SET value=value+1 WHERE id=1`)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	reader := s.(adapter.TableDataReader)
	d, err := reader.DescribeTable(ctx, tc.Table{Schema: "dbeer_types_compare", Name: "every_type"})
	if err != nil {
		t.Fatalf("describe Cassandra types: %v", err)
	}
	var names []string
	for _, column := range d.Columns {
		names = append(names, column.Name)
		if column.NativeType == "" || column.TypeLabel == "" {
			t.Fatal("type identity omitted")
		}
	}
	spec := tc.Spec{Table: d.Table, DescriptorDigest: d.Digest, Columns: names, Keys: []string{"id", "ck"}, ReadLimit: 100}
	rows := &comparisonRows{}
	_, out, err := reader.CaptureTable(ctx, spec, rows)
	if err != nil {
		t.Fatalf("capture Cassandra types: %v", err)
	}
	if len(rows.rows) != 2 || out.StoredRows != 2 || out.ObservedAtLeast != 2 || out.Consistency != "bestEffort" || out.Rendering != "cassandraCQLv1" || !reflect.DeepEqual(out.PartialReasons, []string{"nonSnapshot"}) {
		t.Fatal("capture lost rows or non-snapshot disclosure")
	}
	var quoted []string
	for _, name := range names {
		quoted = append(quoted, `"`+strings.ReplaceAll(name, `"`, `""`)+`"`)
	}
	expected := liveSQL(t, s, `SELECT `+strings.Join(quoted, ",")+` FROM dbeer_types_compare.every_type`)
	if !reflect.DeepEqual(rows.rows, expected.Rows) {
		t.Fatal("capture changed lossless CQL values")
	}
	spec.ReadLimit = 1
	limited := &comparisonRows{}
	_, out, err = reader.CaptureTable(ctx, spec, limited)
	if err != nil || out.StoredRows != 1 || out.ObservedAtLeast != 2 || !reflect.DeepEqual(out.PartialReasons, []string{"nonSnapshot", "readLimit"}) {
		t.Fatalf("capture read limit: %v", err)
	}
	spec.ReadLimit = 100
	value := "value"
	spec.Filters = []tc.Filter{{Column: "tx", Operator: "ne", Value: &value}}
	rejected := &comparisonRows{}
	if _, _, err := reader.CaptureTable(ctx, spec, rejected); !errors.Is(err, tc.ErrUnsupported) || len(rejected.rows) != 0 {
		t.Fatal("unsupported filter was not rejected before reading table rows")
	}
	spec.Filters = nil
	quota := &comparisonRows{err: tc.ErrQuota}
	if _, _, err := reader.CaptureTable(ctx, spec, quota); !errors.Is(err, tc.ErrQuota) {
		t.Fatal("sink quota error was lost")
	}
	collector := sc.NewCollector(ctx, sc.DefaultLimits())
	if err := s.(adapter.SchemaReader).ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{d.Table.Schema}, Limits: sc.DefaultLimits()}, collector); err != nil {
		t.Fatalf("schema types: %v", err)
	}
	if len(collector.Capture.Types) != 1 || len(collector.Capture.Tables) != 4 || collector.Capture.Context.Consistency != "bestEffort" {
		t.Fatal("schema capture omitted types/tables/context")
	}
	definition, err := cassandra.RenderSchemaDefinition(ctx, collector.Capture, sc.Ref{Kind: "table", Schema: d.Table.Schema, Name: d.Table.Name})
	if err != nil || definition.Limited || !strings.Contains(definition.SQL, `STATIC`) || !strings.Contains(definition.SQL, `CLUSTERING ORDER BY ("ck" DESC)`) || !strings.Contains(definition.SQL, `CREATE INDEX "every_type_text"`) || !strings.Contains(definition.SQL, `comment = 'type '' matrix'`) {
		t.Fatalf("complete CQL definition unavailable: %v", err)
	}
	if vectorDefinition != "" && !strings.Contains(definition.SQL, `vector<float, 3>`) {
		t.Fatal("vector dimensions lost")
	}
	recreated := strings.ReplaceAll(definition.SQL, `"dbeer_types_compare"."every_type"`, `"dbeer_types_compare"."rendered_type"`)
	recreated = strings.ReplaceAll(recreated, `"every_type_text"`, `"rendered_type_text"`)
	for i, statement := range safety.Classify("cassandra", recreated) {
		response := s.Execute(ctx, protocol.Command{Type: "execute", RequestID: "recreated", SQL: recreated[statement.Start:statement.End]})
		if response.Type != "query.result" {
			t.Fatalf("recreated CQL statement %d rejected: category=%s", i, response.Category)
		}
	}
	viewDefinition, err := cassandra.RenderSchemaDefinition(ctx, collector.Capture, sc.Ref{Kind: "table", Schema: d.Table.Schema, Name: "type_view"})
	if err != nil || viewDefinition.Limited || !strings.Contains(viewDefinition.SQL, "CREATE MATERIALIZED VIEW") || !strings.Contains(viewDefinition.SQL, "IS NOT NULL") {
		t.Fatal("materialized view definition lost")
	}
	liveSQL(t, s, strings.ReplaceAll(viewDefinition.SQL, `"dbeer_types_compare"."type_view"`, `"dbeer_types_compare"."rendered_view"`))
	liveSQL(t, s, `ALTER TYPE dbeer_types_compare.details ADD extra text`)
	fresh, err := reader.DescribeTable(ctx, d.Table)
	if err != nil || fresh.Digest == d.Digest {
		t.Fatal("nested UDT schema drift did not change descriptor")
	}
	if _, _, err := reader.CaptureTable(ctx, spec, &comparisonRows{}); !errors.Is(err, tc.ErrChanged) {
		t.Fatal("stale type descriptor accepted")
	}
	counter, err := reader.DescribeTable(ctx, tc.Table{Schema: d.Table.Schema, Name: "counters"})
	if err != nil || len(counter.Columns) != 2 || !counter.Columns[1].Numeric {
		t.Fatal("counter descriptor unavailable")
	}
	_, out, err = reader.CaptureTable(ctx, tc.Spec{Table: counter.Table, DescriptorDigest: counter.Digest, Columns: []string{"id", "value"}, Keys: []string{"id"}, ReadLimit: 10}, &comparisonRows{})
	if err != nil || out.StoredRows != 1 {
		t.Fatal("counter capture unavailable")
	}
}
