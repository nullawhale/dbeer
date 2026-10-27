package mysql

import (
	"context"
	"dbeer/helper/internal/comparisonjob"
	"dbeer/helper/internal/resultcompare"
	"dbeer/helper/internal/syncplan"
	tc "dbeer/helper/internal/tablecapture"
	"reflect"
	"strings"
	"testing"
)

func mySynchronizationInput(t *testing.T, reader *Session, name string) (syncplan.DataSide, resultcompare.Source) {
	t.Helper()
	ctx := context.Background()
	table := tc.Table{Schema: integrationSettings(t).Database, Name: name}
	d, e := reader.DescribeTable(ctx, table)
	if e != nil {
		t.Fatalf("describe failed (%T)", e)
	}
	w, e := tc.NewWriter(t.TempDir(), d.Columns, d.Engine, &tc.Budget{Limit: 16 << 20})
	if e != nil {
		t.Fatal("capture storage failed")
	}
	defer w.Close()
	names := []string{}
	for _, c := range d.Columns {
		names = append(names, c.Name)
	}
	_, out, e := reader.CaptureTable(ctx, tc.Spec{Table: table, DescriptorDigest: d.Digest, Columns: names, Keys: []string{"id"}, ReadLimit: 100}, w)
	if e != nil {
		t.Fatalf("capture failed (%T)", e)
	}
	out.FullOriginals = true
	a, e := w.Publish(ctx, out)
	if e != nil {
		t.Fatal("capture publication failed")
	}
	source := comparisonjob.FromArtifact(a)
	t.Cleanup(func() { _ = source.Close() })
	return syncplan.DataSide{Descriptor: d, Outcome: out, Filters: []tc.Filter{}}, source
}

func TestDataSynchronizationMySQLLiveExactRoundTripAndStaleGuards(t *testing.T) {
	writer := integrationSession(t)
	run(t, writer, "DROP TABLE IF EXISTS sync_data_source,sync_data_target")
	defer run(t, writer, "DROP TABLE IF EXISTS sync_data_source,sync_data_target")
	run(t, writer, "CREATE TABLE sync_data_source(id bigint unsigned PRIMARY KEY,amount decimal(65,30),note text,bytes blob,moment datetime(6),document json,hidden int INVISIBLE) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4")
	run(t, writer, "CREATE TABLE sync_data_target LIKE sync_data_source")
	run(t, writer, "INSERT INTO sync_data_source(id,amount,note,bytes,moment,document,hidden) VALUES(1,9007199254740993.123456789012345678901234567890,'',X'00ff80','2026-10-27 12:34:56.123456',JSON_OBJECT('x',1),7),(18446744073709551615,1.00,'NULL',X'','2020-02-29 00:00:00',NULL,NULL)")
	run(t, writer, "INSERT INTO sync_data_target(id,amount,note,bytes,moment,document,hidden) VALUES(1,1.00,'old',X'ff','2020-01-01 00:00:00',NULL,7),(3,NULL,NULL,NULL,NULL,NULL,8)")
	reader := integrationSession(t)
	if e := reader.SetReadOnly(context.Background(), true); e != nil {
		t.Fatal("readonly capture setup failed")
	}
	left, a := mySynchronizationInput(t, reader, "sync_data_source")
	right, b := mySynchronizationInput(t, reader, "sync_data_target")
	mappings := []tc.Mapping{}
	compared := []resultcompare.Mapping{}
	for i, c := range left.Descriptor.Columns {
		mappings = append(mappings, tc.Mapping{Source: c.Name, Target: c.Name, Key: i == 0})
		compared = append(compared, resultcompare.Mapping{Left: i, Right: i, Key: i == 0})
	}
	ctx := context.Background()
	r, e := resultcompare.Compare(ctx, a, b, resultcompare.Options{Mode: "key", Columns: compared, ScratchDir: t.TempDir()})
	if e != nil {
		t.Fatal("comparison failed")
	}
	defer r.Close()
	p, e := syncplan.BuildData(ctx, syncplan.DataInput{Source: left, Target: right, Mappings: mappings, Originals: "allColumns"}, r, strings.Repeat("a", 64), RenderDataSynchronization)
	if e != nil || len(p.Steps) != 3 {
		t.Fatalf("plan generation failed (%T)", e)
	}
	var update, remove string
	for _, step := range p.Steps {
		if step.Manual {
			t.Fatal("supported captured row unexpectedly requires manual SQL")
		}
		if strings.HasPrefix(step.SQL, "UPDATE") {
			update = step.SQL
		}
		if strings.HasPrefix(step.SQL, "DELETE") {
			remove = step.SQL
		}
	}
	if update == "" || remove == "" {
		t.Fatal("plan direction incorrect")
	}
	run(t, writer, "UPDATE sync_data_target SET note='concurrent' WHERE id=1")
	if run(t, writer, update).RowCount != 0 {
		t.Fatal("stale original update was not skipped")
	}
	run(t, writer, "UPDATE sync_data_target SET note='old' WHERE id=1")
	run(t, writer, "UPDATE sync_data_target SET note='concurrent' WHERE id=3")
	if run(t, writer, remove).RowCount != 0 {
		t.Fatal("stale original delete was not skipped")
	}
	run(t, writer, "UPDATE sync_data_target SET note=NULL WHERE id=3")
	run(t, writer, "SET SESSION sql_mode='NO_BACKSLASH_ESCAPES,ANSI_QUOTES,STRICT_TRANS_TABLES'")
	run(t, writer, "SET SESSION time_zone='-10:00'")
	for _, step := range p.Steps {
		run(t, writer, step.SQL)
	}
	_, final := mySynchronizationInput(t, reader, "sync_data_target")
	expected, actual := [][]*string{}, [][]*string{}
	if e = a.Scan(ctx, func(_ resultcompare.RowRef, row []*string) error { expected = append(expected, row); return nil }); e != nil {
		t.Fatal("source artifact unavailable")
	}
	if e = final.Scan(ctx, func(_ resultcompare.RowRef, row []*string) error { actual = append(actual, row); return nil }); e != nil {
		t.Fatal("final capture unavailable")
	}
	if !reflect.DeepEqual(expected, actual) {
		t.Fatal("generated SQL changed exact stored values")
	}
}
