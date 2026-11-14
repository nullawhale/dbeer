package postgres

import (
	"bytes"
	"context"
	"fmt"
	"reflect"
	"testing"

	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// These reviewed native transactions deliberately bypass the unfinished generic
// composer. They prove the catalog mapper against actual hierarchy transitions.
func pgCopyGraphExec(t *testing.T, tx pgx.Tx, sql string) {
	t.Helper()
	if _, err := tx.Exec(context.Background(), sql); err != nil {
		if server, ok := err.(*pgconn.PgError); ok {
			t.Fatalf("reviewed hierarchy statement failed SQLSTATE %s", server.Code)
		}
		t.Fatal("reviewed hierarchy statement failed")
	}
}

func pgCopyGraphLoad(t *testing.T, tx pgx.Tx, target tableedit.Target) tableedit.Baseline {
	t.Helper()
	b, err := readStructure(context.Background(), tx, target)
	if err != nil || b.Advanced == nil || pgAdvancedCopyMetadata(context.Background(), tx, &b) != nil {
		t.Fatal("complete hierarchy catalog capture failed")
	}
	return b
}

func pgCopyGraphData(t *testing.T, tx pgx.Tx, b tableedit.Baseline) *pgAdvancedDataProof {
	t.Helper()
	p, err := pgAdvancedDataCapture(context.Background(), tx, b, tableedit.Condition{Operation: tableedit.Operation{Kind: "reorder"}})
	if err != nil || p == nil || len(p.Relations) != 2 {
		t.Fatal("complete hierarchy native data capture failed")
	}
	return p
}

func pgCopyGraphFinish(t *testing.T, tx pgx.Tx, before, after tableedit.Baseline, layout *pgAdvancedCopyLayout, data *pgAdvancedDataProof) {
	t.Helper()
	if err := pgAdvancedCopyPreservationError(before, after, layout.Orders, layout.Replaced); err != nil {
		a, b := tableedit.CloneAdvancedEvidence(before.AdvancedEvidence), tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
		for _, left := range a.Facts {
			for _, right := range b.Facts {
				if left.Table.Ref == right.Table.Ref && pgAdvancedCopyFacts(left, right) != nil {
					paths := []string{}
					pgCopyGraphDifferencePaths(reflect.ValueOf(left), reflect.ValueOf(right), "Facts", &paths)
					for _, path := range paths {
						t.Log("retained typed metadata differs at " + path)
					}
				}
			}
		}
		t.Fatal(err)
	}
	for i := range data.Relations {
		found := false
		for id, facts := range after.AdvancedEvidence.Facts {
			if facts.Table.Ref.Schema == data.Relations[i].Target.Schema && facts.Table.Ref.Name == data.Relations[i].Target.Table {
				data.Relations[i].OID, found = id, true
			}
		}
		if !found {
			t.Fatal("a physical data member disappeared")
		}
	}
	if err := data.Verify(context.Background(), tx); err != nil {
		t.Fatal("complete hierarchy native row/counter equality failed")
	}
	for _, category := range []string{"class", "attributes", "policies", "dependencies"} {
		bad := after
		bad.AdvancedEvidence = tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
		rows := bad.AdvancedEvidence.Rows[after.Identity+"/"+category]
		if len(rows) == 0 {
			t.Fatal("native mutation category unexpectedly empty")
		}
		rows[0]["unreviewed_native_property"] = true
		if pgAdvancedCopyPreservationError(before, bad, layout.Orders, layout.Replaced) == nil {
			t.Fatal("an actual captured catalog mutation was accepted")
		}
	}
	for _, property := range []string{"force", "storage", "policy"} {
		bad := after
		bad.AdvancedEvidence = tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
		switch property {
		case "force":
			bad.AdvancedEvidence.Rows[after.Identity+"/class"][0]["relforcerowsecurity"] = false
		case "storage":
			for _, attr := range bad.AdvancedEvidence.Rows[after.Identity+"/attributes"] {
				if attr["attname"] == "payload" {
					attr["attstorage"] = "p"
				}
			}
		case "policy":
			bad.AdvancedEvidence.Rows[after.Identity+"/policies"][0]["polpermissive"] = false
		}
		if pgAdvancedCopyPreservationError(before, bad, layout.Orders, layout.Replaced) == nil {
			t.Fatal("an actual captured security/storage property mutation was accepted")
		}
	}
	pgCopyGraphExec(t, tx, "SAVEPOINT owned_row_mutation")
	var populated tableedit.Target
	for _, relation := range data.Relations {
		if len(relation.Rows) > 0 {
			populated = relation.Target
			break
		}
	}
	if !populated.Valid() {
		t.Fatal("the native row mutation probe has no populated physical member")
	}
	pgCopyGraphExec(t, tx, "UPDATE ONLY "+pgPhysicalName(populated)+" SET payload='late mutation'")
	if data.Verify(context.Background(), tx) == nil {
		t.Fatal("a late unaffected native row mutation was accepted")
	}
	pgCopyGraphExec(t, tx, "ROLLBACK TO SAVEPOINT owned_row_mutation")
	if err := data.Verify(context.Background(), tx); err != nil {
		t.Fatal("native data did not return after the owned mutation rollback")
	}
}

// Diagnostics expose only field paths, never native SQL, catalog values or rows.
func pgCopyGraphDifferencePaths(a, b reflect.Value, path string, out *[]string) {
	if len(*out) >= 24 {
		return
	}
	if !a.IsValid() || !b.IsValid() || a.Type() != b.Type() {
		*out = append(*out, path)
		return
	}
	if reflect.DeepEqual(a.Interface(), b.Interface()) {
		return
	}
	switch a.Kind() {
	case reflect.Pointer, reflect.Interface:
		if a.IsNil() || b.IsNil() {
			*out = append(*out, path)
			return
		}
		pgCopyGraphDifferencePaths(a.Elem(), b.Elem(), path, out)
	case reflect.Struct:
		for i := 0; i < a.NumField(); i++ {
			pgCopyGraphDifferencePaths(a.Field(i), b.Field(i), path+"."+a.Type().Field(i).Name, out)
		}
	case reflect.Map:
		if a.Len() != b.Len() {
			*out = append(*out, path+".length")
		}
		for _, key := range a.MapKeys() {
			pgCopyGraphDifferencePaths(a.MapIndex(key), b.MapIndex(key), path+".entry", out)
		}
	case reflect.Array, reflect.Slice:
		if a.Len() != b.Len() {
			*out = append(*out, path+".length")
		}
		for i := 0; i < a.Len() && i < b.Len(); i++ {
			pgCopyGraphDifferencePaths(a.Index(i), b.Index(i), fmt.Sprintf("%s[%d]", path, i), out)
		}
	default:
		*out = append(*out, path)
	}
}

func pgCopyGraphRestore(t *testing.T, tx pgx.Tx, before tableedit.Baseline, definitions pgAdvancedCopyDefinitions, id string, target tableedit.Target) {
	t.Helper()
	for _, policy := range definitions.Policies[id] {
		pgCopyGraphExec(t, tx, policy.SQL(target))
	}
	for _, trigger := range definitions.Triggers[id] {
		pgCopyGraphExec(t, tx, trigger)
	}
	grants, err := pgAdvancedCopyACL(context.Background(), tx, before, "TABLE", pgPhysicalName(target), fmt.Sprint(before.AdvancedEvidence.Rows[id+"/class"][0]["relowner"]), before.AdvancedEvidence.Rows[id+"/copyPrivileges"])
	if err != nil {
		t.Fatal("complete native ACL replay planning failed")
	}
	for _, sql := range grants {
		pgCopyGraphExec(t, tx, sql)
	}
}

func pgCopyGraphCapturedNotNull(t *testing.T, b tableedit.Baseline, id, column string) string {
	t.Helper()
	if b.Facts.ServerVersion < 180000 {
		return "NOT NULL"
	}
	var number any
	for _, a := range b.AdvancedEvidence.Rows[id+"/attributes"] {
		if a["attname"] == column {
			number = a["attnum"]
		}
	}
	for _, c := range b.AdvancedEvidence.Rows[id+"/constraints"] {
		if c["contype"] == "n" && reflect.DeepEqual(c["conkey"], []any{number}) {
			return "CONSTRAINT " + pgx.Identifier{fmt.Sprint(c["conname"])}.Sanitize() + " NOT NULL"
		}
	}
	t.Fatal("complete original native NOT NULL name unavailable")
	return ""
}

func TestStructureAdvancedCopyGraphTraditionalNativeLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE FUNCTION " + f.table("retained_trigger") + "() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$")
	f.exec("CREATE TABLE " + f.table("parent") + "(id integer NOT NULL,payload text DEFAULT 'default',n numeric(30,4),b bytea,g integer GENERATED ALWAYS AS(id+1) STORED,CONSTRAINT positive CHECK(id>=0)) WITH(fillfactor=70)")
	f.exec("ALTER TABLE " + f.table("parent") + " ALTER COLUMN payload SET STORAGE EXTERNAL")
	f.exec("CREATE TABLE " + f.table("child") + "(local_tag text) INHERITS(" + f.table("parent") + ") WITH(fillfactor=75)")
	for _, name := range []string{"parent", "child"} {
		f.exec("ALTER TABLE " + f.table(name) + " ENABLE ROW LEVEL SECURITY")
		f.exec("ALTER TABLE " + f.table(name) + " FORCE ROW LEVEL SECURITY")
		f.exec("CREATE POLICY retained ON " + f.table(name) + " USING(id>0) WITH CHECK(id>0)")
		f.exec("CREATE INDEX retained_" + name + "_numeric ON " + f.table(name) + "(n)")
		f.exec("CREATE TRIGGER retained_" + name + " BEFORE INSERT ON " + f.table(name) + " FOR EACH ROW WHEN(NEW.id>0) EXECUTE FUNCTION " + f.table("retained_trigger") + "()")
		f.exec("COMMENT ON TABLE " + f.table(name) + " IS 'retained hierarchy table'")
		f.exec("COMMENT ON COLUMN " + f.table(name) + ".payload IS 'retained inherited column'")
		f.exec("GRANT SELECT ON " + f.table(name) + " TO PUBLIC")
		f.exec("GRANT UPDATE(payload) ON " + f.table(name) + " TO PUBLIC")
	}
	f.exec("ALTER TABLE " + f.table("parent") + " ADD CONSTRAINT retained_primary PRIMARY KEY(id)")
	f.exec("COMMENT ON COLUMN " + f.table("child") + ".local_tag IS 'retained local column'")
	f.exec("GRANT UPDATE(local_tag) ON " + f.table("child") + " TO PUBLIC")
	f.exec("INSERT INTO " + f.table("parent") + "(id,payload,n,b) VALUES(1,'',12345678901234567890.1234,decode('00ff','hex')),(2,'NULL',NULL,NULL),(3,NULL,-123.4000,decode('ff00','hex'))")
	f.exec("INSERT INTO " + f.table("child") + "(id,payload,n,b,local_tag) VALUES(4,'NULL',99999999999999999999.0001,decode('0000ff','hex'),'same'),(4,'NULL',99999999999999999999.0001,decode('0000ff','hex'),'same'),(5,NULL,NULL,NULL,'')")
	tx, err := f.conn.Begin(ctx)
	if err != nil {
		t.Fatal("hierarchy transaction could not begin")
	}
	defer tx.Rollback(ctx)
	pgCopyGraphExec(t, tx, "SET LOCAL search_path=pg_catalog")
	pgCopyGraphExec(t, tx, "LOCK TABLE ONLY "+f.table("parent")+", ONLY "+f.table("child")+" IN ACCESS EXCLUSIVE MODE")
	target := tableedit.Target{Schema: f.schema, Table: "parent"}
	before := pgCopyGraphLoad(t, tx, target)
	layout, err := pgAdvancedCopyGraph(before, []string{"payload", "id", "b", "n", "g"})
	if err != nil || len(layout.Replaced) != 2 {
		t.Fatal("reviewed traditional replacement graph is incomplete")
	}
	var childID string
	for id, target := range layout.Targets {
		if target.Table == "child" {
			childID = id
		}
	}
	if childID == "" || !layout.CreateInherits[childID] || !reflect.DeepEqual(layout.Orders[childID], []string{"payload", "id", "b", "n", "g", "local_tag"}) {
		t.Fatal("the nonlocal child order was not explicitly reviewed")
	}
	definitions, err := pgAdvancedCopyReadDefinitions(ctx, tx, before, layout)
	if err != nil {
		t.Fatal("native hierarchy definition capture failed")
	}
	data := pgCopyGraphData(t, tx, before)
	duplicate := false
	for _, relation := range data.Relations {
		if relation.OID == childID {
			for i := 1; i < len(relation.Rows); i++ {
				duplicate = duplicate || bytes.Equal(relation.Rows[i-1], relation.Rows[i])
			}
		}
	}
	if !duplicate {
		t.Fatal("traditional fixture did not retain duplicate rows")
	}
	pgCopyGraphExec(t, tx, "CREATE TABLE "+f.table("copy_parent")+"(payload text DEFAULT 'default',id integer "+pgCopyGraphCapturedNotNull(t, before, before.Identity, "id")+",b bytea,n numeric(30,4),g integer GENERATED ALWAYS AS(id+1) STORED,CONSTRAINT positive CHECK(id>=0)) WITH(fillfactor=70)")
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("copy_parent")+" ALTER COLUMN payload SET STORAGE EXTERNAL")
	newChild, oldChild := "copy_child", "child"
	if before.Facts.ServerVersion >= 180000 {
		// Native inherited NOT NULL constraints cannot be renamed. Creating
		// under the original child name preserves its native generated name.
		pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("child")+" RENAME TO saved_child")
		newChild, oldChild = "child", "saved_child"
	}
	pgCopyGraphExec(t, tx, "CREATE TABLE "+f.table(newChild)+"(local_tag text) INHERITS("+f.table("copy_parent")+") WITH(fillfactor=75)")
	for _, name := range []string{"copy_parent", newChild} {
		pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table(name)+" ENABLE ROW LEVEL SECURITY")
		pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table(name)+" FORCE ROW LEVEL SECURITY")
	}
	pgCopyGraphExec(t, tx, "INSERT INTO "+f.table("copy_parent")+"(id,payload,n,b) SELECT id,payload,n,b FROM ONLY "+f.table("parent"))
	pgCopyGraphExec(t, tx, "INSERT INTO "+f.table(newChild)+"(id,payload,n,b,local_tag) SELECT id,payload,n,b,local_tag FROM ONLY "+f.table(oldChild))
	pgCopyGraphExec(t, tx, "DROP TABLE "+f.table(oldChild)+" RESTRICT")
	pgCopyGraphExec(t, tx, "DROP TABLE "+f.table("parent")+" RESTRICT")
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("copy_parent")+" RENAME TO parent")
	if newChild != "child" {
		pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table(newChild)+" RENAME TO child")
	}
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("parent")+" ADD CONSTRAINT retained_primary PRIMARY KEY(id)")
	for _, name := range []string{"parent", "child"} {
		pgCopyGraphExec(t, tx, "CREATE INDEX retained_"+name+"_numeric ON "+f.table(name)+"(n)")
		pgCopyGraphExec(t, tx, "COMMENT ON TABLE "+f.table(name)+" IS 'retained hierarchy table'")
		pgCopyGraphExec(t, tx, "COMMENT ON COLUMN "+f.table(name)+".payload IS 'retained inherited column'")
	}
	pgCopyGraphExec(t, tx, "COMMENT ON COLUMN "+f.table("child")+".local_tag IS 'retained local column'")
	pgCopyGraphRestore(t, tx, before, definitions, before.Identity, target)
	pgCopyGraphRestore(t, tx, before, definitions, childID, tableedit.Target{Schema: f.schema, Table: "child"})
	after := pgCopyGraphLoad(t, tx, target)
	for id, facts := range after.AdvancedEvidence.Facts {
		for old, previous := range before.AdvancedEvidence.Facts {
			if facts.Table.Ref == previous.Table.Ref && id == old {
				t.Fatal("a reviewed traditional relation was not replaced")
			}
		}
	}
	pgCopyGraphFinish(t, tx, before, after, layout, data)
	if err := tx.Commit(ctx); err != nil {
		t.Fatal("reviewed traditional transaction did not commit")
	}
}

func TestStructureAdvancedCopyGraphDeclarativeNativeLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE FUNCTION " + f.table("retained_trigger") + "() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$")
	f.exec("CREATE TABLE " + f.table("parts") + "(id integer NOT NULL,payload text DEFAULT 'default',n numeric(30,4),b bytea,g integer GENERATED ALWAYS AS(id+1) STORED,CONSTRAINT positive CHECK(id>=0)) PARTITION BY RANGE(id)")
	f.exec("ALTER TABLE " + f.table("parts") + " ALTER COLUMN payload SET STORAGE EXTERNAL")
	f.exec("CREATE TABLE " + f.table("leaf") + " PARTITION OF " + f.table("parts") + " FOR VALUES FROM(0) TO(100) WITH(fillfactor=75)")
	f.exec("ALTER TABLE " + f.table("parts") + " ADD CONSTRAINT retained_primary PRIMARY KEY(id)")
	f.exec("CREATE INDEX retained_parts_numeric ON " + f.table("parts") + "(n)")
	f.exec("CREATE TRIGGER retained_parent BEFORE INSERT ON " + f.table("parts") + " FOR EACH ROW WHEN(NEW.id>0) EXECUTE FUNCTION " + f.table("retained_trigger") + "()")
	f.exec("CREATE TRIGGER retained_leaf BEFORE UPDATE ON " + f.table("leaf") + " FOR EACH ROW WHEN(NEW.id>0) EXECUTE FUNCTION " + f.table("retained_trigger") + "()")
	for _, name := range []string{"parts", "leaf"} {
		f.exec("ALTER TABLE " + f.table(name) + " ENABLE ROW LEVEL SECURITY")
		f.exec("ALTER TABLE " + f.table(name) + " FORCE ROW LEVEL SECURITY")
		f.exec("CREATE POLICY retained ON " + f.table(name) + " USING(id>0) WITH CHECK(id>0)")
		f.exec("COMMENT ON TABLE " + f.table(name) + " IS 'retained partition table'")
		f.exec("COMMENT ON COLUMN " + f.table(name) + ".payload IS 'retained partition column'")
		f.exec("GRANT SELECT ON " + f.table(name) + " TO PUBLIC")
		f.exec("GRANT UPDATE(payload) ON " + f.table(name) + " TO PUBLIC")
	}
	f.exec("CREATE SEQUENCE " + f.table("leaf_seq") + " AS integer START WITH 1000 INCREMENT BY 7 CACHE 1 OWNED BY " + f.table("leaf") + ".id")
	f.exec("ALTER TABLE " + f.table("leaf") + " ALTER COLUMN id SET DEFAULT nextval(" + postgresTextLiteral(f.table("leaf_seq")) + "::pg_catalog.regclass)")
	f.exec("COMMENT ON SEQUENCE " + f.table("leaf_seq") + " IS 'retained leaf counter'")
	f.exec("GRANT USAGE ON SEQUENCE " + f.table("leaf_seq") + " TO PUBLIC")
	f.exec("INSERT INTO " + f.table("parts") + "(id,payload,n,b) VALUES(1,'',12345678901234567890.1234,decode('00ff','hex')),(2,'NULL',NULL,NULL),(3,NULL,-123.4000,decode('ff00','hex'))")
	tx, err := f.conn.Begin(ctx)
	if err != nil {
		t.Fatal("hierarchy transaction could not begin")
	}
	defer tx.Rollback(ctx)
	pgCopyGraphExec(t, tx, "SET LOCAL search_path=pg_catalog")
	pgCopyGraphExec(t, tx, "LOCK TABLE ONLY "+f.table("parts")+", ONLY "+f.table("leaf")+" IN ACCESS EXCLUSIVE MODE")
	target := tableedit.Target{Schema: f.schema, Table: "parts"}
	before := pgCopyGraphLoad(t, tx, target)
	layout, err := pgAdvancedCopyGraph(before, []string{"payload", "id", "b", "n", "g"})
	if err != nil || len(layout.Replaced) != 1 || !layout.Replaced[before.Identity] {
		t.Fatal("reviewed declarative replacement graph is incomplete")
	}
	var leafID string
	for id, target := range layout.Targets {
		if target.Table == "leaf" {
			leafID = id
		}
	}
	if leafID == "" || !reflect.DeepEqual(layout.Orders[leafID], []string{"id", "payload", "n", "b", "g"}) {
		t.Fatal("retained leaf physical order was not explicitly reviewed")
	}
	definitions, err := pgAdvancedCopyReadDefinitions(ctx, tx, before, layout)
	if err != nil {
		t.Fatal("native hierarchy definition capture failed")
	}
	data := pgCopyGraphData(t, tx, before)
	if len(data.Sequences) != 1 {
		t.Fatal("the retained leaf sequence counter was not captured")
	}
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("parts")+" DETACH PARTITION "+f.table("leaf"))
	pgCopyGraphExec(t, tx, "CREATE TABLE "+f.table("copy_parts")+"(payload text DEFAULT 'default',id integer "+pgCopyGraphCapturedNotNull(t, before, before.Identity, "id")+",b bytea,n numeric(30,4),g integer GENERATED ALWAYS AS(id+1) STORED,CONSTRAINT positive CHECK(id>=0)) PARTITION BY RANGE(id)")
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("copy_parts")+" ALTER COLUMN payload SET STORAGE EXTERNAL")
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("copy_parts")+" ENABLE ROW LEVEL SECURITY")
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("copy_parts")+" FORCE ROW LEVEL SECURITY")
	pgCopyGraphExec(t, tx, "DROP TABLE "+f.table("parts")+" RESTRICT")
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("copy_parts")+" RENAME TO parts")
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("parts")+" ADD CONSTRAINT retained_primary PRIMARY KEY(id)")
	pgCopyGraphExec(t, tx, "CREATE INDEX retained_parts_numeric ON "+f.table("parts")+"(n)")
	pgCopyGraphExec(t, tx, "COMMENT ON TABLE "+f.table("parts")+" IS 'retained partition table'")
	pgCopyGraphExec(t, tx, "COMMENT ON COLUMN "+f.table("parts")+".payload IS 'retained partition column'")
	pgCopyGraphRestore(t, tx, before, definitions, before.Identity, target)
	pgCopyGraphExec(t, tx, "ALTER TABLE "+f.table("parts")+" ATTACH PARTITION "+f.table("leaf")+" FOR VALUES FROM(0) TO(100)")
	after := pgCopyGraphLoad(t, tx, target)
	if after.Identity == before.Identity || after.AdvancedEvidence.Facts[leafID] == nil {
		t.Fatal("the selected parent/retained leaf identities were not respected")
	}
	pgCopyGraphFinish(t, tx, before, after, layout, data)
	if err := tx.Commit(ctx); err != nil {
		t.Fatal("reviewed declarative transaction did not commit")
	}
	probe, err := f.conn.Begin(ctx)
	if err != nil {
		t.Fatal("owned late counter probe could not begin")
	}
	defer probe.Rollback(ctx)
	pgCopyGraphExec(t, probe, "SET LOCAL search_path=pg_catalog")
	pgCopyGraphExec(t, probe, "SELECT pg_catalog.setval("+postgresTextLiteral(f.table("leaf_seq"))+"::pg_catalog.regclass,1001,true)")
	if data.Verify(ctx, probe) == nil {
		t.Fatal("a late retained sequence counter mutation was accepted")
	}
}
