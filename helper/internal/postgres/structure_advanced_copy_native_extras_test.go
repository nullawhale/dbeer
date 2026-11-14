package postgres

import (
	"context"
	"strings"
	"testing"

	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
)

func pgCopyExtrasToastIndex(t *testing.T, b tableedit.Baseline) string {
	t.Helper()
	toast := b.AdvancedEvidence.Rows[b.Identity+"/toast"]
	if len(toast) != 1 {
		t.Fatal("the owned native TOAST graph is incomplete")
	}
	indexes, ok := pgAdvancedCopyRecordRows(toast[0]["indexes"])
	if !ok || len(indexes) != 1 {
		t.Fatal("the owned native TOAST index is incomplete")
	}
	class, ok := indexes[0]["class"].(map[string]any)
	name, valid := class["relname"].(string)
	if !ok || !valid || !tableedit.Identifier(name) || pgPhysicalOID(class["relnamespace"]) != "99" {
		t.Fatal("the native TOAST index origin is unavailable")
	}
	return pgx.Identifier{"pg_toast", name}.Sanitize()
}

// The ancestor and its cached bigint sequence remain unchanged. Only the local
// child is recreated, proving new index/TOAST/array addresses and retained ones.
func TestStructureAdvancedCopyNativeExtrasPreservationLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("ancestor") + "(id integer NOT NULL,payload text DEFAULT 'default',n numeric(30,4),b bytea,g integer GENERATED ALWAYS AS(id+1) STORED,CONSTRAINT positive CHECK(id>=0),CONSTRAINT ancestor_primary PRIMARY KEY(id)) WITH(fillfactor=72)")
	f.exec("ALTER TABLE " + f.table("ancestor") + " ALTER COLUMN payload SET STORAGE EXTERNAL")
	f.exec("CREATE SEQUENCE " + f.table("ancestor_seq") + " AS bigint START WITH 9007199254740993 INCREMENT BY 7 CACHE 17 OWNED BY " + f.table("ancestor") + ".id")
	f.exec("ALTER TABLE ONLY " + f.table("ancestor") + " ALTER COLUMN id SET DEFAULT nextval(" + postgresTextLiteral(f.table("ancestor_seq")) + "::pg_catalog.regclass)")
	f.exec("SELECT pg_catalog.nextval(" + postgresTextLiteral(f.table("ancestor_seq")) + "::pg_catalog.regclass)")
	f.exec("CREATE TABLE " + f.table("child") + "(id integer NOT NULL,payload text DEFAULT 'default',n numeric(30,4),b bytea,g integer GENERATED ALWAYS AS(id+1) STORED,CONSTRAINT positive CHECK(id>=0)) WITH(fillfactor=70)")
	f.exec("ALTER TABLE " + f.table("child") + " ALTER COLUMN payload SET STORAGE EXTERNAL")
	f.exec("ALTER TABLE " + f.table("child") + " INHERIT " + f.table("ancestor"))
	f.exec("ALTER TABLE " + f.table("child") + " ENABLE ROW LEVEL SECURITY")
	f.exec("ALTER TABLE " + f.table("child") + " FORCE ROW LEVEL SECURITY")
	f.exec("CREATE POLICY retained ON " + f.table("child") + " USING(id>0) WITH CHECK(id>0)")
	f.exec("CREATE INDEX retained_expression ON " + f.table("child") + "((length(payload))) WITH(fillfactor=83)")
	f.exec("ALTER INDEX " + f.table("retained_expression") + " ALTER COLUMN 1 SET STATISTICS 321")
	f.exec("CREATE INDEX retained_payload ON " + f.table("child") + "(payload)")
	f.exec("COMMENT ON TYPE " + f.table("_child") + " IS 'retained automatic row array'")
	f.exec("COMMENT ON TABLE " + f.table("child") + " IS 'retained child'")
	f.exec("COMMENT ON COLUMN " + f.table("child") + ".payload IS 'retained payload'")
	f.exec("GRANT SELECT ON " + f.table("child") + " TO PUBLIC")
	f.exec("GRANT UPDATE(payload) ON " + f.table("child") + " TO PUBLIC")
	f.exec("INSERT INTO " + f.table("ancestor") + "(id,payload,n,b) VALUES(1,'ancestor',12345678901234567890.1234,decode('00ff','hex'))")
	f.exec("INSERT INTO " + f.table("child") + "(id,payload,n,b) VALUES(10,'',12345678901234567890.1234,decode('00ff','hex')),(11,'NULL',NULL,NULL),(11,'NULL',NULL,NULL),(12,NULL,-123.4000,decode('ff00','hex'))")
	tx, err := f.conn.Begin(ctx)
	if err != nil {
		t.Fatal("native extras transaction could not begin")
	}
	defer tx.Rollback(ctx)
	pgCopyGraphExec(t, tx, "SET LOCAL search_path=pg_catalog")
	pgCopyGraphExec(t, tx, "LOCK TABLE ONLY "+f.table("ancestor")+", ONLY "+f.table("child")+" IN ACCESS EXCLUSIVE MODE")
	target := tableedit.Target{Schema: f.schema, Table: "child"}
	pre := pgCopyGraphLoad(t, tx, target)
	pgCopyGraphExec(t, tx, "COMMENT ON INDEX "+pgCopyExtrasToastIndex(t, pre)+" IS 'retained internal index'")
	before := pgCopyGraphLoad(t, tx, target)
	layout, err := pgAdvancedCopyGraph(before, []string{"payload", "g", "id", "b", "n"})
	if err != nil || len(layout.Replaced) != 1 || !layout.Replaced[before.Identity] || layout.CreateInherits[before.Identity] {
		t.Fatal("the selected local child graph was not exactly reviewed")
	}
	var ancestorID string
	for id, target := range layout.Targets {
		if target.Table == "ancestor" {
			ancestorID = id
		}
	}
	if ancestorID == "" || ancestorID == before.Identity {
		t.Fatal("the retained ancestor identity is absent")
	}
	definitions, err := pgAdvancedCopyReadDefinitions(ctx, tx, before, layout)
	if err != nil {
		t.Fatal("native extras definitions unavailable")
	}
	data := pgCopyGraphData(t, tx, before)
	if len(data.Sequences) != 1 {
		t.Fatal("the retained cached sequence was not captured")
	}
	for _, sequence := range data.Sequences {
		native, ok := sequence.Definition["sequence"].(map[string]any)
		if !ok || native["seqcache"] != "17" || sequence.Value != "9007199254741105" || !sequence.Called {
			t.Fatal("exact cached bigint sequence state was not captured")
		}
	}
	if len(before.AdvancedEvidence.Rows[before.Identity+"/indexAttributes"]) != 4 {
		t.Fatal("complete user/TOAST index term metadata is unavailable")
	}
	pgCopyGraphExec(t, tx, "CREATE TABLE "+f.table("copy_child")+"(payload text DEFAULT 'default',g integer GENERATED ALWAYS AS(id+1) STORED,id integer NOT NULL,b bytea,n numeric(30,4),CONSTRAINT positive CHECK(id>=0)) WITH(fillfactor=70)")
	if before.Facts.ServerVersion >= 180000 {
		// Restore the captured local NOT NULL name before inheritance makes
		// it non-renamable. The generic writer can declare it in CREATE.
		pgCopyGraphExec(t, tx, "ALTER TABLE ONLY "+f.table("copy_child")+" RENAME CONSTRAINT copy_child_id_not_null TO child_id_not_null")
	}
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("copy_child")+" ALTER COLUMN payload SET STORAGE EXTERNAL")
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("copy_child")+" INHERIT "+f.table("ancestor"))
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("copy_child")+" ENABLE ROW LEVEL SECURITY")
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("copy_child")+" FORCE ROW LEVEL SECURITY")
	pgCopyGraphExec(t, tx, "INSERT INTO "+f.table("copy_child")+"(id,payload,n,b) SELECT id,payload,n,b FROM ONLY "+f.table("child"))
	pgCopyGraphExec(t, tx, "DROP TABLE "+f.table("child")+" RESTRICT")
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("copy_child")+" RENAME TO child")
	pgCopyGraphExec(t, tx, "CREATE INDEX retained_expression ON "+f.table("child")+"((length(payload))) WITH(fillfactor=83)")
	pgCopyGraphExec(t, tx, "CREATE INDEX retained_payload ON "+f.table("child")+"(payload)")
	pgCopyGraphExec(t, tx, "COMMENT ON TYPE "+f.table("_child")+" IS 'retained automatic row array'")
	pgCopyGraphExec(t, tx, "COMMENT ON TABLE "+f.table("child")+" IS 'retained child'")
	pgCopyGraphExec(t, tx, "COMMENT ON COLUMN "+f.table("child")+".payload IS 'retained payload'")
	pgCopyGraphRestore(t, tx, before, definitions, before.Identity, target)
	current := pgCopyGraphLoad(t, tx, target)
	pgCopyGraphExec(t, tx, "COMMENT ON INDEX "+pgCopyExtrasToastIndex(t, current)+" IS 'retained internal index'")
	withoutStatistics := pgCopyGraphLoad(t, tx, target)
	if err := pgAdvancedCopyPreservationError(before, withoutStatistics, layout.Orders, layout.Replaced); err == nil {
		t.Fatal("missing native index-column statistics were not rejected")
	}
	pgCopyGraphExec(t, tx, "ALTER INDEX "+f.table("retained_expression")+" ALTER COLUMN 1 SET STATISTICS 321")
	after := pgCopyGraphLoad(t, tx, target)
	if after.Identity == before.Identity || after.AdvancedEvidence.Facts[ancestorID] == nil {
		t.Fatal("the selected child/retained ancestor identities were not respected")
	}
	badIndex := after
	badIndex.AdvancedEvidence = tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
	changed := false
	for _, attr := range badIndex.AdvancedEvidence.Rows[after.Identity+"/indexAttributes"] {
		if n, ok := pgPhysicalNumber(attr["attstattarget"]); ok && n == 321 {
			attr["attstattarget"] = float64(322)
			changed = true
		}
	}
	if !changed {
		t.Fatal("the restored native index-column statistics were not captured")
	}
	if err := pgAdvancedCopyPreservationError(before, badIndex, layout.Orders, layout.Replaced); err == nil || !strings.Contains(err.Error(), "indexAttributes") {
		t.Fatal("the full raw native index attribute guard accepted a changed property")
	}
	for _, category := range []string{"comments", "labels", "dependencies", "indexAttributes"} {
		bad := after
		bad.AdvancedEvidence = tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
		bad.AdvancedEvidence.Rows[after.Identity+"/"+category] = append(bad.AdvancedEvidence.Rows[after.Identity+"/"+category], map[string]any{"future_native_property": true})
		if pgAdvancedCopyPreservationError(before, bad, layout.Orders, layout.Replaced) == nil {
			t.Fatal("an actual captured native extra category mutation was accepted")
		}
	}
	bad := after
	bad.AdvancedEvidence = tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
	bad.AdvancedEvidence.Rows[ancestorID+"/sequences"][0]["sequence"].(map[string]any)["seqcache"] = "18"
	if pgAdvancedCopyPreservationError(before, bad, layout.Orders, layout.Replaced) == nil {
		t.Fatal("changed retained sequence cache metadata was accepted")
	}
	pgCopyGraphFinish(t, tx, before, after, layout, data)
	if err := tx.Commit(ctx); err != nil {
		t.Fatal("the complete native extras transaction did not commit")
	}
}
