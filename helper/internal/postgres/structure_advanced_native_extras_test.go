package postgres

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"testing"

	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
)

func TestStructureAdvancedNativeExtraMerge(t *testing.T) {
	a := map[string]any{"objid": "100", "value": "retained"}
	b := map[string]any{"objid": "101", "value": "retained"}
	left := []map[string]any{a, b}
	merged, err := pgAdvancedNativeMerge(left, []map[string]any{a}, 2)
	if err != nil || len(merged) != 2 {
		t.Fatal("exact duplicate catalog records were not merged")
	}
	again, err := pgAdvancedNativeMerge(merged, left, 2)
	if err != nil || !reflect.DeepEqual(merged, again) {
		t.Fatal("native enrichment merge was not deterministic/idempotent")
	}
	if _, err = pgAdvancedNativeMerge(left, []map[string]any{{"objid": "100", "value": "changed"}}, 2); err == nil {
		t.Fatal("a distinct native property became a deduplicated record")
	}
	if _, err = pgAdvancedNativeMerge(left, []map[string]any{nil}, 3); err == nil {
		t.Fatal("incomplete native record was accepted")
	}
}

type pgNativeExtrasGuardReader struct{ outputs int }

func (r *pgNativeExtrasGuardReader) Query(context.Context, string, ...any) (pgx.Rows, error) {
	r.outputs++
	return nil, errors.New("native output must not be reached")
}

func (r *pgNativeExtrasGuardReader) QueryRow(context.Context, string, ...any) pgx.Row {
	return pgNativeExtrasGuardRow{}
}

type pgNativeExtrasGuardRow struct{}

func (pgNativeExtrasGuardRow) Scan(dest ...any) error {
	if len(dest) != 1 {
		return errors.New("unexpected guard shape")
	}
	p, ok := dest[0].(*bool)
	if !ok {
		return errors.New("unexpected guard type")
	}
	*p = false
	return nil
}

func TestStructureAdvancedNativeExtrasGuardBeforeOutput(t *testing.T) {
	e := &tableedit.AdvancedEvidence{Targets: []tableedit.Target{{Schema: "fixture", Table: "table"}}, Rows: map[string][]map[string]any{"100/class": {{"oid": "100"}}}}
	b := tableedit.Baseline{AdvancedEvidence: e}
	q := &pgNativeExtrasGuardReader{}
	if pgAdvancedNativeExtras(context.Background(), q, &b) == nil || q.outputs != 0 || b.AdvancedEvidence != e {
		t.Fatal("missing-datum guard invoked native output or retained a partial proof")
	}
}

func TestStructureAdvancedNativeExtrasCatalogLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("secured") + "(id integer,payload text)")
	f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ROW LEVEL SECURITY")
	f.exec("INSERT INTO " + f.table("secured") + " VALUES(1,''),(2,'NULL'),(3,NULL)")
	f.exec("CREATE INDEX retained_expression ON " + f.table("secured") + "((id+1))")
	f.exec("ALTER INDEX " + f.table("retained_expression") + " ALTER COLUMN 1 SET STATISTICS 321")
	f.exec("COMMENT ON TYPE " + f.table("_secured") + " IS 'retained native array type'")
	q := pgCatalogReader(f.conn)
	var toastSchema, toastName, arrayID, toastID, indexID, toastIndexID, toastIndexName string
	if q.QueryRow(ctx, `SELECT tn.nspname,tc.relname,c.reltoastrelid::pg_catalog.text,t.typarray::pg_catalog.text,ti.indexrelid::pg_catalog.text,tic.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace JOIN pg_catalog.pg_type t ON t.oid=c.reltype JOIN pg_catalog.pg_class tc ON tc.oid=c.reltoastrelid JOIN pg_catalog.pg_namespace tn ON tn.oid=tc.relnamespace JOIN pg_catalog.pg_index ti ON ti.indrelid=tc.oid JOIN pg_catalog.pg_class tic ON tic.oid=ti.indexrelid WHERE n.nspname=$1 AND c.relname='secured'`, f.schema).Scan(&toastSchema, &toastName, &toastID, &arrayID, &toastIndexID, &toastIndexName) != nil {
		t.Fatal("owned native storage identities unavailable")
	}
	if q.QueryRow(ctx, `SELECT c.oid::pg_catalog.text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname='retained_expression'`, f.schema).Scan(&indexID) != nil {
		t.Fatal("owned native expression-index identity unavailable")
	}
	f.exec("COMMENT ON INDEX " + pgx.Identifier{toastSchema, toastIndexName}.Sanitize() + " IS 'retained native toast'")
	f.exec("CREATE SEQUENCE " + f.table("extra_operator_calls"))
	f.exec("CREATE FUNCTION " + f.table("extra_oid_equal") + "(pg_catalog.oid,pg_catalog.oid) RETURNS pg_catalog.bool LANGUAGE plpgsql VOLATILE AS $$BEGIN PERFORM pg_catalog.nextval('" + f.table("extra_operator_calls") + "'::pg_catalog.regclass); RETURN $1 OPERATOR(pg_catalog.=) $2; END$$")
	f.exec("CREATE OPERATOR " + f.schema + ".= (LEFTARG=pg_catalog.oid,RIGHTARG=pg_catalog.oid,FUNCTION=" + f.table("extra_oid_equal") + ")")
	f.exec("SET search_path TO " + pgx.Identifier{f.schema}.Sanitize() + ",pg_catalog")
	var control bool
	if f.conn.QueryRow(ctx, "SELECT 1::pg_catalog.oid=1::pg_catalog.oid").Scan(&control) != nil || !control {
		t.Fatal("shadow-operator positive control unavailable")
	}
	var calls int64
	if f.observer.QueryRow(ctx, "SELECT last_value FROM "+f.table("extra_operator_calls")).Scan(&calls) != nil || calls < 1 {
		t.Fatal("shadow-operator positive control was not invoked")
	}
	b, err := (&Session{conn: f.conn}).StructureLoad(ctx, tableedit.Target{Schema: f.schema, Table: "secured"})
	if err != nil {
		t.Fatal(err)
	}
	find := func(category, field, id string) bool {
		for _, row := range b.AdvancedEvidence.Rows[b.Identity+"/"+category] {
			if fmt.Sprint(row[field]) == id {
				return true
			}
		}
		return false
	}
	if !find("comments", "objoid", arrayID) || !find("comments", "objoid", toastIndexID) {
		t.Fatal("StructureLoad omitted complete native metadata enrichment")
	}
	var actor, path string
	if q.QueryRow(ctx, "SELECT current_user,pg_catalog.current_setting('search_path')").Scan(&actor, &path) != nil || pgAdvancedNativeExtras(ctx, f.conn, &b) != nil {
		t.Fatal("complete native extras unavailable")
	}
	if !find("comments", "objoid", arrayID) || !find("comments", "objoid", toastIndexID) || !find("dependencies", "objid", arrayID) || !find("dependencies", "objid", toastID) || !find("dependencies", "objid", toastIndexID) || !find("indexAttributes", "attrelid", indexID) || !find("indexAttributes", "attrelid", toastIndexID) {
		t.Fatal("complete native array/storage/index addresses were not captured")
	}
	foundStatistics := false
	for _, row := range b.AdvancedEvidence.Rows[b.Identity+"/indexAttributes"] {
		if fmt.Sprint(row["attrelid"]) == indexID && fmt.Sprint(row["attstattarget"]) == "321" {
			foundStatistics = true
		}
	}
	if !foundStatistics {
		t.Fatal("native index-column statistics target was lost")
	}
	fingerprint := tableedit.Fingerprint(b.AdvancedEvidence)
	if pgAdvancedNativeExtras(ctx, f.conn, &b) != nil || tableedit.Fingerprint(b.AdvancedEvidence) != fingerprint {
		t.Fatal("native enrichment was not idempotent")
	}
	var nextActor, nextPath string
	var nextCalls int64
	if q.QueryRow(ctx, "SELECT current_user,pg_catalog.current_setting('search_path')").Scan(&nextActor, &nextPath) != nil || nextActor != actor || nextPath != path || f.observer.QueryRow(ctx, "SELECT last_value FROM "+f.table("extra_operator_calls")).Scan(&nextCalls) != nil || nextCalls != calls {
		t.Fatal("native capture invoked a shadow operator or changed execution context")
	}
}
