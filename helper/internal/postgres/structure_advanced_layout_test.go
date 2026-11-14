package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"reflect"
	"testing"
)

func TestStructureAdvancedNativeTypeLayoutLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("native_layout") + "(id integer,payload text)")
	f.exec("ALTER TABLE " + f.table("native_layout") + " ENABLE ROW LEVEL SECURITY")
	f.exec("INSERT INTO " + f.table("native_layout") + " VALUES(7,'retained'),(8,NULL)")
	target := tableedit.Target{Schema: f.schema, Table: "native_layout"}
	b, err := readStructure(ctx, f.conn, target)
	if err != nil {
		t.Fatal(err)
	}
	tx, err := f.conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer structureRollback(tx)
	if _, err = tx.Exec(ctx, "ALTER TABLE ONLY "+f.table("native_layout")+" ALTER COLUMN id TYPE pg_catalog.int8"); err != nil {
		t.Fatal("native widening failed")
	}
	after, err := readStructure(ctx, tx, target)
	if err != nil {
		t.Fatal(err)
	}
	for name, attrs := range b.Attributes {
		if !reflect.DeepEqual(tableedit.SemanticPostgresAttributeOptions(attrs["attoptions"]), tableedit.SemanticPostgresAttributeOptions(after.Attributes[name]["attoptions"])) {
			t.Fatal("native rewrite changed semantic attribute options")
		}
	}
	condition := tableedit.Condition{Operation: tableedit.Operation{Kind: "changeColumn", Change: &tableedit.ColumnChange{Name: "id", Type: &tableedit.DataType{Kind: "bigint"}}}}
	beforeRaw, afterRaw := tableedit.Fingerprint(b.AdvancedEvidence), tableedit.Fingerprint(after.AdvancedEvidence)
	if err = pgAdvancedPreservationError(b, after, condition); err != nil {
		t.Fatal(err)
	}
	if beforeRaw != tableedit.Fingerprint(b.AdvancedEvidence) || afterRaw != tableedit.Fingerprint(after.AdvancedEvidence) {
		t.Fatal("semantic comparison mutated the raw staleness evidence")
	}
	for _, options := range []any{[]any{"n_distinct=0.5"}, []any{"unmodeled=true"}, []any{"pg_attver=invalid"}, []any{"pg_attver=1", "pg_attver=2"}, "pg_attver=1"} {
		changed := after
		changed.AdvancedEvidence = tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
		for _, row := range changed.AdvancedEvidence.Rows[after.Identity+"/attributes"] {
			if row["attname"] == "payload" {
				row["attoptions"] = options
			}
		}
		if pgAdvancedPreservationError(b, changed, condition) == nil {
			t.Fatal("semantic, unknown or malformed native option drift was accepted")
		}
	}
}
