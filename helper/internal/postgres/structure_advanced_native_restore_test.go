package postgres

import (
	"context"
	"fmt"
	"reflect"
	"testing"

	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestStructureAdvancedNativeRestoreClosedInput(t *testing.T) {
	if _, err := pgAdvancedNativeStorageOptions("fillfactor=70; SELECT 1"); err == nil {
		t.Fatal("opaque SQL text acquired native storage-option authority")
	}
	if _, err := pgAdvancedNativeStorageOptions([]any{"fillfactor=70"}, "unproved."); err == nil {
		t.Fatal("unknown native option namespace accepted")
	}
	if _, err := pgAdvancedNativeToastIndexCommentSQL(tableedit.Target{Schema: "pg_catalog", Table: "pg_class"}, "value"); err == nil {
		t.Fatal("system target accepted by private user-table restoration")
	}
	if _, err := pgAdvancedNativeStorageOptions([]any{"option.with.namespace=1"}); err == nil {
		t.Fatal("unproven storage option namespace accepted")
	}
}

func TestStructureAdvancedNativeRestoreActualPropertiesLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("secured") + "(id integer PRIMARY KEY,payload text) WITH(toast.autovacuum_enabled=false)")
	f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ROW LEVEL SECURITY")
	f.exec("CREATE INDEX retained_expression ON " + f.table("secured") + "((id+1)) WITH(fillfactor=61)")
	f.exec("CREATE INDEX unset_expression ON " + f.table("secured") + "((id+2))")
	f.exec("ALTER INDEX " + f.table("retained_expression") + " ALTER COLUMN 1 SET STATISTICS 321")
	q := pgCatalogReader(f.conn)
	var toastSchema, toastIndex string
	if q.QueryRow(ctx, `SELECT ns.nspname,ic.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace JOIN pg_catalog.pg_index ix ON ix.indrelid=c.reltoastrelid JOIN pg_catalog.pg_class ic ON ic.oid=ix.indexrelid JOIN pg_catalog.pg_namespace ns ON ns.oid=ic.relnamespace WHERE n.nspname=$1 AND c.relname='secured'`, f.schema).Scan(&toastSchema, &toastIndex) != nil {
		t.Fatal("source native storage identity unavailable")
	}
	comment := "retained %I %s 'quote' \\ path; -- $$ é"
	f.exec("COMMENT ON INDEX " + pgx.Identifier{toastSchema, toastIndex}.Sanitize() + " IS " + postgresTextLiteral(comment))
	probe, err := f.conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	_, rejected := probe.Exec(ctx, "ALTER INDEX "+pgx.Identifier{toastSchema, toastIndex}.Sanitize()+" SET(fillfactor=73)")
	server, ok := rejected.(*pgconn.PgError)
	if !ok || server.Code != "42501" {
		t.Fatal("native internal-index storage-option protection was not observed")
	}
	if probe.Rollback(ctx) != nil {
		t.Fatal("owned native-boundary probe did not cleanly roll back")
	}
	before, err := (&Session{conn: f.conn}).StructureLoad(ctx, tableedit.Target{Schema: f.schema, Table: "secured"})
	if err != nil || pgAdvancedNativeExtras(ctx, f.conn, &before) != nil {
		t.Fatal("complete source native metadata unavailable")
	}
	replacementSchema := f.schema + "_restore"
	f.exec("CREATE SCHEMA " + pgx.Identifier{replacementSchema}.Sanitize())
	defer f.exec("DROP SCHEMA IF EXISTS " + pgx.Identifier{replacementSchema}.Sanitize() + " CASCADE")
	target := tableedit.Target{Schema: replacementSchema, Table: "secured"}
	qualified := pgx.Identifier{target.Schema, target.Table}.Sanitize()
	f.exec("CREATE TABLE " + qualified + "(id integer PRIMARY KEY,payload text)")
	f.exec("ALTER TABLE " + qualified + " ENABLE ROW LEVEL SECURITY")
	f.exec("CREATE INDEX retained_expression ON " + qualified + "((id+1))")
	f.exec("CREATE INDEX unset_expression ON " + qualified + "((id+2))")
	statements, err := pgAdvancedNativeIndexRestoreSQL(before, before.Identity, target)
	if err != nil || len(statements) != 4 {
		t.Fatal("complete native settings/comment restoration unavailable")
	}
	tx, err := f.conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, "SET LOCAL search_path=pg_catalog"); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, "LOCK TABLE ONLY "+qualified+" IN ACCESS EXCLUSIVE MODE"); err != nil {
		t.Fatal(err)
	}
	for _, statement := range statements {
		if _, err = tx.Exec(ctx, statement); err != nil {
			t.Fatal("reviewed native property restoration failed")
		}
	}
	after, err := readStructure(ctx, tx, target)
	if err != nil || pgAdvancedNativeExtras(ctx, tx, &after) != nil {
		t.Fatal("complete restored native properties unavailable")
	}
	if after.Identity == before.Identity {
		t.Fatal("native restoration fixture did not use new relation/storage identities")
	}
	index, toastIndexID := "", ""
	for _, row := range after.AdvancedEvidence.Rows[after.Identity+"/indexes"] {
		class := row["class"].(map[string]any)
		if class["relname"] == "retained_expression" && reflect.DeepEqual(class["reloptions"], []any{"fillfactor=61"}) {
			index = fmt.Sprint(class["oid"])
		}
	}
	for _, row := range after.AdvancedEvidence.Rows[after.Identity+"/toast"] {
		class := row["indexes"].([]any)[0].(map[string]any)["class"].(map[string]any)
		if class["reloptions"] == nil && reflect.DeepEqual(row["class"].(map[string]any)["reloptions"], []any{"autovacuum_enabled=false"}) {
			toastIndexID = fmt.Sprint(class["oid"])
		}
	}
	statistics, restoredComment := false, false
	for _, row := range after.AdvancedEvidence.Rows[after.Identity+"/indexAttributes"] {
		if fmt.Sprint(row["attrelid"]) == index && fmt.Sprint(row["attstattarget"]) == "321" {
			statistics = true
		}
	}
	for _, row := range after.AdvancedEvidence.Rows[after.Identity+"/comments"] {
		if fmt.Sprint(row["objoid"]) == toastIndexID && row["description"] == comment {
			restoredComment = true
		}
	}
	if index == "" || toastIndexID == "" || !statistics || !restoredComment {
		t.Fatal("a retained native statistics/storage/comment property was not restored exactly")
	}
	for _, source := range before.AdvancedEvidence.Rows[before.Identity+"/indexes"] {
		oldClass := source["class"].(map[string]any)
		var newID string
		for _, current := range after.AdvancedEvidence.Rows[after.Identity+"/indexes"] {
			newClass := current["class"].(map[string]any)
			if oldClass["relname"] == newClass["relname"] {
				newID = fmt.Sprint(newClass["oid"])
			}
		}
		if newID == "" {
			t.Fatal("a native expression/simple-key control index was not recreated")
		}
		for _, old := range before.AdvancedEvidence.Rows[before.Identity+"/indexAttributes"] {
			if fmt.Sprint(old["attrelid"]) != fmt.Sprint(oldClass["oid"]) {
				continue
			}
			matched := false
			for _, current := range after.AdvancedEvidence.Rows[after.Identity+"/indexAttributes"] {
				if fmt.Sprint(current["attrelid"]) == newID && old["attnum"] == current["attnum"] {
					matched = reflect.DeepEqual(old["attstattarget"], current["attstattarget"])
				}
			}
			if !matched {
				t.Fatal("an explicit or unset native statistics encoding was normalized or lost")
			}
		}
	}
	bad := before
	bad.AdvancedEvidence = tableedit.CloneAdvancedEvidence(before.AdvancedEvidence)
	bad.AdvancedEvidence.Rows[before.Identity+"/indexAttributes"][0]["attoptions"] = []any{"unknown_option=1"}
	if _, err = pgAdvancedNativeIndexRestoreSQL(bad, before.Identity, target); err == nil {
		t.Fatal("unknown native index-column options were silently discarded")
	}
	bad = before
	bad.AdvancedEvidence = tableedit.CloneAdvancedEvidence(before.AdvancedEvidence)
	bad.AdvancedEvidence.Rows[before.Identity+"/toast"][0]["indexes"].([]any)[0].(map[string]any)["class"].(map[string]any)["reloptions"] = []any{"fillfactor=73"}
	if _, err = pgAdvancedNativeIndexRestoreSQL(bad, before.Identity, target); err == nil {
		t.Fatal("native internal-index storage protection was bypassed or a source property ignored")
	}
	if err = tx.Commit(ctx); err != nil {
		t.Fatal("native property restoration commit failed")
	}
}

func TestStructureAdvancedNativeRestorePartitionedIndexLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("parts") + "(id integer NOT NULL,n numeric(30,4),payload text) PARTITION BY RANGE(id)")
	f.exec("CREATE TABLE " + f.table("leaf") + " PARTITION OF " + f.table("parts") + " FOR VALUES FROM(0) TO(100)")
	f.exec("CREATE INDEX retained_expression ON " + f.table("parts") + "((n+0)) WITH(fillfactor=61)")
	f.exec("ALTER INDEX " + f.table("retained_expression") + " ALTER COLUMN 1 SET STATISTICS 321")
	f.exec("INSERT INTO " + f.table("parts") + " VALUES(1,12345678901234567890.1234,''),(2,NULL,'NULL'),(3,-123.4000,NULL)")
	probe, err := f.conn.Begin(ctx)
	if err != nil {
		t.Fatal("native partitioned-index boundary probe unavailable")
	}
	_, nativeError := probe.Exec(ctx, "ALTER INDEX "+f.table("retained_expression")+" SET(fillfactor=62)")
	server, ok := nativeError.(*pgconn.PgError)
	rollbackError := probe.Rollback(ctx)
	if !ok || server.Code != "42809" || rollbackError != nil {
		if ok {
			t.Logf("native boundary SQLSTATE=%s routine=%s", server.Code, server.Routine)
		}
		t.Fatal("the native partitioned-index ALTER storage boundary was not observed cleanly")
	}
	before, err := (&Session{conn: f.conn}).StructureLoad(ctx, tableedit.Target{Schema: f.schema, Table: "parts"})
	if err != nil || pgAdvancedNativeExtras(ctx, f.conn, &before) != nil {
		t.Fatal("complete source partitioned-index metadata unavailable")
	}
	replacementSchema := f.schema + "_partition_restore"
	f.exec("CREATE SCHEMA " + pgx.Identifier{replacementSchema}.Sanitize())
	defer f.exec("DROP SCHEMA IF EXISTS " + pgx.Identifier{replacementSchema}.Sanitize() + " CASCADE")
	target := tableedit.Target{Schema: replacementSchema, Table: "parts"}
	qualified := pgx.Identifier{target.Schema, target.Table}.Sanitize()
	indexName := pgx.Identifier{target.Schema, "retained_expression"}.Sanitize()
	f.exec("CREATE TABLE " + qualified + "(id integer NOT NULL,n numeric(30,4),payload text) PARTITION BY RANGE(id)")
	f.exec("CREATE TABLE " + pgx.Identifier{target.Schema, "leaf"}.Sanitize() + " PARTITION OF " + qualified + " FOR VALUES FROM(0) TO(100)")
	f.exec("CREATE INDEX retained_expression ON " + qualified + "((n+0)) WITH(fillfactor=61)")
	f.exec("INSERT INTO " + qualified + " SELECT * FROM " + f.table("parts"))
	statements, err := pgAdvancedNativeIndexRestoreSQL(before, before.Identity, target)
	if err != nil || len(statements) != 2 {
		t.Fatal("partitioned-index definition assertion/statistics restoration unavailable")
	}
	tx, err := f.conn.Begin(ctx)
	if err != nil {
		t.Fatal("native partitioned-index restoration transaction unavailable")
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, "SET LOCAL search_path=pg_catalog"); err != nil {
		t.Fatal("fixed native restoration context unavailable")
	}
	for _, statement := range statements {
		if _, err = tx.Exec(ctx, statement); err != nil {
			t.Fatal("native partitioned-index properties were not preserved/restored")
		}
	}
	after, err := readStructure(ctx, tx, target)
	if err != nil || pgAdvancedNativeExtras(ctx, tx, &after) != nil {
		t.Fatal("complete restored partitioned-index metadata unavailable")
	}
	oldIndex := before.AdvancedEvidence.Rows[before.Identity+"/indexes"][0]
	newIndex := after.AdvancedEvidence.Rows[after.Identity+"/indexes"][0]
	oldClass, newClass := oldIndex["class"].(map[string]any), newIndex["class"].(map[string]any)
	if oldClass["relkind"] != "I" || newClass["relkind"] != "I" || !reflect.DeepEqual(oldClass["reloptions"], newClass["reloptions"]) {
		t.Fatal("native partitioned-index kind/options changed")
	}
	oldAttrs, newAttrs := map[string]map[string]any{}, map[string]map[string]any{}
	for _, pair := range []struct {
		b   tableedit.Baseline
		id  any
		out map[string]map[string]any
	}{{before, oldClass["oid"], oldAttrs}, {after, newClass["oid"], newAttrs}} {
		for _, a := range pair.b.AdvancedEvidence.Rows[pair.b.Identity+"/indexAttributes"] {
			if a["attrelid"] == pair.id {
				copy := map[string]any{}
				for key, value := range a {
					if key != "attrelid" {
						copy[key] = value
					}
				}
				pair.out[fmt.Sprint(a["attnum"])] = copy
			}
		}
	}
	if len(oldAttrs) != 1 || !reflect.DeepEqual(oldAttrs, newAttrs) || tx.Commit(ctx) != nil {
		t.Fatal("complete native partitioned-index attributes were not retained through COMMIT")
	}
	negative, err := f.conn.Begin(ctx)
	if err != nil {
		t.Fatal("native partitioned-index mutation transaction unavailable")
	}
	if _, err = negative.Exec(ctx, "SET LOCAL search_path=pg_catalog"); err != nil {
		t.Fatal("native mutation context unavailable")
	}
	if _, err = negative.Exec(ctx, "DROP INDEX "+indexName); err != nil {
		t.Fatal("owned partitioned-index mutation unavailable")
	}
	if _, err = negative.Exec(ctx, "CREATE INDEX retained_expression ON "+qualified+"((n+0)) WITH(fillfactor=62)"); err != nil {
		t.Fatal("owned partitioned-index changed-option fixture unavailable")
	}
	_, rejected := negative.Exec(ctx, statements[0])
	server, ok = rejected.(*pgconn.PgError)
	if !ok || server.Code != "P0001" || negative.Rollback(ctx) != nil {
		t.Fatal("a changed partitioned-index option escaped the reviewed assertion")
	}
}
