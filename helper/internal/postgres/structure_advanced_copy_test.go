package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"regexp"
	"testing"

	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type pgCopyDiagnosticReader struct {
	structureReader
	err error
}

func TestStructureAdvancedCopyRunnerBoundariesLive(t *testing.T) {
	for _, name := range []string{"PreDropMismatch", "StalePolicy", "MissingBoundTypes", "UncertainCommit", "RetainedGeneratedMismatch"} {
		t.Run(name, func(t *testing.T) {
			f := newChangeFixture(t)
			ctx := context.Background()
			s := &Session{conn: f.conn}
			f.exec("CREATE FUNCTION " + f.table("retained_generation") + "(integer) RETURNS integer LANGUAGE sql IMMUTABLE AS 'SELECT $1*2'")
			f.exec("CREATE TABLE " + f.table("secured") + "(id integer,payload text,g integer GENERATED ALWAYS AS(" + f.table("retained_generation") + "(id)) STORED)")
			f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ROW LEVEL SECURITY")
			f.exec("ALTER TABLE " + f.table("secured") + " FORCE ROW LEVEL SECURITY")
			f.exec("CREATE POLICY retained ON " + f.table("secured") + " USING(id>0)")
			f.exec("INSERT INTO " + f.table("secured") + "(id,payload) VALUES(1,''),(2,'NULL'),(2,'NULL'),(3,NULL)")
			b, err := s.StructureLoad(ctx, tableedit.Target{Schema: f.schema, Table: "secured"})
			if err != nil {
				t.Fatal(err)
			}
			p, err := s.preparePGAdvancedCopy(ctx, b, []string{"payload", "g", "id"})
			if err != nil {
				t.Fatal(err)
			}
			var e pgAdvancedCopyEnvelope
			if json.Unmarshal([]byte(p.Reconstruction.ExpectedDefinition), &e) != nil {
				t.Fatal("retained private copy proof unavailable")
			}
			var mutationError error
			switch name {
			case "PreDropMismatch":
				s.afterStructureStep = func(i int) {
					if i == e.CopyStep {
						_, mutationError = f.conn.Exec(ctx, "UPDATE ONLY "+pgPhysicalName(e.Layout.Temporary[b.Identity])+" SET payload='changed' WHERE id=1")
					}
				}
			case "StalePolicy":
				f.exec("ALTER POLICY retained ON " + f.table("secured") + " USING(id>1)")
			case "MissingBoundTypes":
				p.Reconstruction.AdvancedDataProof = ""
			case "UncertainCommit":
				s.afterStructureStep = func(i int) {
					if i != len(p.SQL)-2 {
						return
					}
					after, err := readStructure(ctx, f.conn, b.Target)
					if err != nil || pgAdvancedCopyMetadata(ctx, f.conn, &after) != nil {
						t.Fatal("post-copy diagnostic metadata unavailable")
					}
					left, right := tableedit.CloneAdvancedEvidence(e.Evidence), tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
					for _, a := range left.Facts {
						for _, z := range right.Facts {
							if a.Table.Ref != z.Table.Ref || pgAdvancedCopyFacts(a, z) == nil {
								continue
							}
							paths := []string{}
							pgCopyGraphDifferencePaths(reflect.ValueOf(a), reflect.ValueOf(z), "Facts", &paths)
							for _, path := range paths {
								t.Log("retained typed metadata differs at " + path)
							}
						}
					}
				}
				s.structureCommitOverride = func(commit func() error) error {
					if err := commit(); err != nil {
						return err
					}
					return errors.New("synthetic lost acknowledgement")
				}
			case "RetainedGeneratedMismatch":
				f.exec("CREATE OR REPLACE FUNCTION " + f.table("retained_generation") + "(integer) RETURNS integer LANGUAGE sql IMMUTABLE AS 'SELECT $1*3'")
			}
			steps := s.applyPGAdvancedCopy(ctx, b, tableedit.Plan{SQL: p.SQL, Reconstruction: p.Reconstruction})
			if mutationError != nil {
				t.Fatal("owned late-copy mutation fixture failed")
			}
			for _, step := range steps {
				switch name {
				case "StalePolicy", "MissingBoundTypes":
					if step.State != "notStarted" {
						t.Fatal("a stale/unbound copy dispatched native DDL")
					}
				case "UncertainCommit":
					if step.State != "unknown" {
						t.Fatalf("lost COMMIT acknowledgement became state=%s message=%s", step.State, step.Message)
					}
				default:
					if step.State != "rolledBack" && step.State != "notStarted" {
						t.Fatal("a complete retained-value mismatch escaped transactional rollback")
					}
				}
			}
			if name == "UncertainCommit" {
				if !f.conn.IsClosed() {
					t.Fatal("uncertain copy COMMIT retained its physical connection")
				}
				return
			}
			var identity string
			if f.observer.QueryRow(ctx, "SELECT c.oid::pg_catalog.text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname='secured'", f.schema).Scan(&identity) != nil || identity != b.Identity {
				t.Fatal("a failed copy dropped or replaced the original source")
			}
			if name == "PreDropMismatch" || name == "RetainedGeneratedMismatch" {
				for _, step := range steps[e.DropStep:] {
					if step.State != "notStarted" {
						t.Fatal("source DROP was dispatched before complete temporary native-value equality")
					}
				}
			}
		})
	}
}

func TestStructureAdvancedCopyGenericNativePropertiesLive(t *testing.T) {
	for _, name := range []string{"Permanent", "Unlogged", "IndexStatisticsMutation", "ArrayCommentMutation", "ToastIndexCommentMutation"} {
		t.Run(name, func(t *testing.T) {
			f := newChangeFixture(t)
			ctx := context.Background()
			s := &Session{conn: f.conn}
			persistence := ""
			if name == "Unlogged" {
				persistence = "UNLOGGED "
			}
			f.exec("CREATE " + persistence + "TABLE " + f.table("secured") + "(id integer NOT NULL,payload text DEFAULT 'retained',n numeric(30,4),b bytea,base integer,g integer GENERATED ALWAYS AS(base*2) STORED,CONSTRAINT retained_pk PRIMARY KEY(id)) WITH(fillfactor=70,toast.autovacuum_enabled=false)")
			f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ROW LEVEL SECURITY")
			f.exec("ALTER TABLE " + f.table("secured") + " FORCE ROW LEVEL SECURITY")
			f.exec("CREATE POLICY retained ON " + f.table("secured") + " USING(id>0) WITH CHECK(id>0)")
			f.exec("ALTER TABLE " + f.table("secured") + " ALTER COLUMN payload SET STORAGE EXTERNAL")
			f.exec("ALTER TABLE " + f.table("secured") + " ALTER COLUMN payload SET COMPRESSION pglz")
			f.exec("ALTER TABLE " + f.table("secured") + " ALTER COLUMN payload SET STATISTICS 500")
			f.exec("ALTER TABLE " + f.table("secured") + " ALTER COLUMN payload SET(n_distinct=-0.5)")
			f.exec("CREATE INDEX retained_numeric ON " + f.table("secured") + "((n+0)) WITH(fillfactor=61)")
			f.exec("ALTER INDEX " + f.table("retained_numeric") + " ALTER COLUMN 1 SET STATISTICS 321")
			f.exec("ALTER TABLE " + f.table("secured") + " CLUSTER ON retained_numeric")
			f.exec("ALTER TABLE " + f.table("secured") + " REPLICA IDENTITY USING INDEX retained_pk")
			f.exec("COMMENT ON TABLE " + f.table("secured") + " IS 'retained table'")
			f.exec("COMMENT ON COLUMN " + f.table("secured") + ".payload IS 'retained column'")
			f.exec("COMMENT ON INDEX " + f.table("retained_numeric") + " IS 'retained expression index'")
			f.exec("COMMENT ON TYPE " + f.table("_secured") + " IS 'retained array type'")
			f.exec("GRANT SELECT ON " + f.table("secured") + " TO PUBLIC")
			f.exec("GRANT UPDATE(payload) ON " + f.table("secured") + " TO PUBLIC")
			f.exec("CREATE SEQUENCE " + f.table("trigger_calls"))
			f.exec("CREATE FUNCTION " + f.table("retained_trigger") + "() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN PERFORM pg_catalog.nextval('" + f.table("trigger_calls") + "'::pg_catalog.regclass); RETURN NEW; END$$")
			f.exec("CREATE TRIGGER retained_user BEFORE INSERT ON " + f.table("secured") + " FOR EACH ROW EXECUTE FUNCTION " + f.table("retained_trigger") + "()")
			f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ALWAYS TRIGGER retained_user")
			f.exec("INSERT INTO " + f.table("secured") + "(id,payload,n,b,base) VALUES(1,'',12345678901234567890.1234,decode('00ff','hex'),3),(2,'NULL',NULL,NULL,4),(3,NULL,-123.4000,decode('ff00','hex'),NULL)")
			var toastSchema, toastIndex string
			q := pgCatalogReader(f.conn)
			if q.QueryRow(ctx, `SELECT ns.nspname,ic.relname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace JOIN pg_catalog.pg_index ix ON ix.indrelid=c.reltoastrelid JOIN pg_catalog.pg_class ic ON ic.oid=ix.indexrelid JOIN pg_catalog.pg_namespace ns ON ns.oid=ic.relnamespace WHERE n.nspname=$1 AND c.relname='secured'`, f.schema).Scan(&toastSchema, &toastIndex) != nil {
				t.Fatal("native TOAST-index fixture unavailable")
			}
			f.exec("COMMENT ON INDEX " + pgx.Identifier{toastSchema, toastIndex}.Sanitize() + " IS 'retained toast index'")
			var calls int64
			if f.observer.QueryRow(ctx, "SELECT last_value FROM "+f.table("trigger_calls")).Scan(&calls) != nil || calls != 3 {
				t.Fatal("native trigger positive control unavailable")
			}
			b, err := s.StructureLoad(ctx, tableedit.Target{Schema: f.schema, Table: "secured"})
			if err != nil {
				t.Fatal(err)
			}
			order := []string{"payload", "g", "base", "b", "id", "n"}
			p, err := s.preparePGAdvancedCopy(ctx, b, order)
			if err != nil {
				t.Fatal(err)
			}
			var mutationError error
			if name == "Permanent" {
				s.afterStructureStep = func(i int) {
					if i != len(p.SQL)-2 {
						return
					}
					after, err := readStructure(ctx, f.conn, b.Target)
					if err != nil || pgAdvancedCopyMetadata(ctx, f.conn, &after) != nil {
						t.Fatal("native index diagnostic capture unavailable")
					}
					mapping, ok := pgPhysicalAttributeMap(pgAdvancedRelation(b.Identity+"/", b.AdvancedEvidence), pgAdvancedRelation(after.Identity+"/", after.AdvancedEvidence))
					if !ok {
						t.Fatal("native index diagnostic column map unavailable")
					}
					for _, old := range b.AdvancedEvidence.Rows[b.Identity+"/indexes"] {
						oc, oi := old["class"].(map[string]any), old["index"].(map[string]any)
						for _, next := range after.AdvancedEvidence.Rows[after.Identity+"/indexes"] {
							nc, ni := next["class"].(map[string]any), next["index"].(map[string]any)
							if oc["relname"] != nc["relname"] {
								continue
							}
							for key, value := range oc {
								if key != "oid" && key != "relfilenode" && !reflect.DeepEqual(value, nc[key]) {
									t.Log("native index differs at class." + key)
								}
							}
							for key, value := range oi {
								if key != "indexrelid" && key != "indrelid" && key != "indkey" && key != "indexprs" && key != "indpred" && !reflect.DeepEqual(value, ni[key]) {
									t.Log("native index differs at index." + key)
								}
							}
							for _, key := range []string{"indexprs", "indpred"} {
								left, ok := pgPhysicalMapNode(oi[key], mapping)
								if !ok {
									t.Fatal("native index diagnostic expression map unavailable")
								}
								right := pgPhysicalNodePositions(ni[key])
								if reflect.DeepEqual(left, right) {
									continue
								}
								ls, lok := left.(string)
								rs, rok := right.(string)
								if !lok || !rok {
									t.Log("native index differs at index." + key)
									continue
								}
								fields := regexp.MustCompile(`:[A-Za-z_][A-Za-z_0-9]*`).FindAllStringIndex(ls, -1)
								other := regexp.MustCompile(`:[A-Za-z_][A-Za-z_0-9]*`).FindAllStringIndex(rs, -1)
								if len(fields) != len(other) {
									t.Log("native index differs at index." + key + ".shape")
									continue
								}
								for j, fld := range fields {
									le, re := len(ls), len(rs)
									if j+1 < len(fields) {
										le, re = fields[j+1][0], other[j+1][0]
									}
									if ls[fld[0]:le] != rs[other[j][0]:re] {
										t.Log("native index differs at index." + key + "." + ls[fld[0]+1:fld[1]])
									}
								}
							}
						}
					}
				}
			}
			if name != "Permanent" && name != "Unlogged" {
				s.afterStructureStep = func(i int) {
					if i != len(p.SQL)-2 {
						return
					}
					statement := "ALTER INDEX " + f.table("retained_numeric") + " ALTER COLUMN 1 SET STATISTICS 322"
					if name == "ArrayCommentMutation" {
						statement = "COMMENT ON TYPE " + f.table("secured") + "[] IS 'changed array type'"
					} else if name == "ToastIndexCommentMutation" {
						statement = pgAdvancedCopyToastIndexSQL(b.Target, "COMMENT ON INDEX %I.%I IS %L", "changed toast index")
					}
					_, mutationError = f.conn.Exec(ctx, statement)
				}
			}
			steps := s.applyPGAdvancedCopy(ctx, b, tableedit.Plan{SQL: p.SQL, Reconstruction: p.Reconstruction})
			if mutationError != nil {
				t.Fatal("native-property late mutation fixture failed")
			}
			for i, step := range steps {
				if name == "Permanent" || name == "Unlogged" {
					if step.State != "applied" || step.Message != "" {
						t.Fatalf("native property copy step %d state=%s message=%s", i, step.State, step.Message)
					}
				} else if step.State != "rolledBack" && step.State != "notStarted" {
					t.Fatal("a retained native-property mutation escaped rollback")
				}
			}
			var nextCalls int64
			if f.observer.QueryRow(ctx, "SELECT last_value FROM "+f.table("trigger_calls")).Scan(&nextCalls) != nil || nextCalls != calls {
				t.Fatal("native COPY replayed a retained INSERT trigger")
			}
			fresh, err := s.StructureLoad(ctx, b.Target)
			if err != nil {
				t.Fatal(err)
			}
			if name == "Permanent" || name == "Unlogged" {
				if fresh.Identity == b.Identity || !reflect.DeepEqual(order, func() []string {
					out := []string{}
					for _, c := range fresh.Columns {
						out = append(out, c.Name)
					}
					return out
				}()) {
					t.Fatal("native generic copy did not change only the reviewed physical order")
				}
			} else if fresh.Identity != b.Identity {
				t.Fatal("native-property mismatch replaced the original source")
			}
		})
	}
}

func (r *pgCopyDiagnosticReader) Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
	rows, err := r.structureReader.Query(ctx, sql, args...)
	if err != nil {
		r.err = err
		return rows, err
	}
	return &pgCopyDiagnosticRows{Rows: rows, reader: r}, nil
}

type pgCopyDiagnosticRows struct {
	pgx.Rows
	reader *pgCopyDiagnosticReader
}

func (r *pgCopyDiagnosticRows) Err() error {
	err := r.Rows.Err()
	if err != nil {
		r.reader.err = err
	}
	return err
}

func (r *pgCopyDiagnosticRows) Scan(dest ...any) error {
	err := r.Rows.Scan(dest...)
	if err != nil {
		r.reader.err = err
	}
	return err
}

func TestStructureAdvancedCopyGraphAndEffectivePrivilegesLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("parent") + "(id integer,payload text)")
	f.exec("CREATE TABLE " + f.table("child") + "(first_local text,second_local integer) INHERITS(" + f.table("parent") + ")")
	f.exec("CREATE TABLE " + f.table("parts") + "(id integer,payload text) PARTITION BY RANGE(id)")
	f.exec("CREATE TABLE " + f.table("leaf") + " PARTITION OF " + f.table("parts") + " FOR VALUES FROM(0) TO(100)")
	f.exec("CREATE TABLE " + f.table("secured") + "(id integer,payload text)")
	f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ROW LEVEL SECURITY")
	f.exec("ALTER TABLE " + f.table("secured") + " FORCE ROW LEVEL SECURITY")
	f.exec("CREATE POLICY retained ON " + f.table("secured") + " USING(id>0)")
	f.exec("GRANT SELECT ON " + f.table("secured") + " TO PUBLIC")
	f.exec("GRANT UPDATE(payload) ON " + f.table("secured") + " TO PUBLIC")
	load := func(name string) tableedit.Baseline {
		t.Helper()
		b, err := s.StructureLoad(ctx, tableedit.Target{Schema: f.schema, Table: name})
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	t.Run("TraditionalParentExplicitDescendantOrder", func(t *testing.T) {
		b := load("parent")
		layout, err := pgAdvancedCopyGraph(b, []string{"payload", "id"})
		if err != nil || len(layout.Replaced) != 2 || len(layout.CreateOrder) != 2 || layout.CreateOrder[0] != b.Identity {
			t.Fatalf("complete traditional recreation graph: %v", err)
		}
		for id, target := range layout.Targets {
			if target.Table == "child" && (!layout.CreateInherits[id] || !reflect.DeepEqual(layout.Orders[id], []string{"payload", "id", "first_local", "second_local"})) {
				t.Fatal("nonlocal child declaration order or explicit inherited state was lost")
			}
		}
	})
	t.Run("TraditionalChildLocalOrder", func(t *testing.T) {
		b := load("child")
		layout, err := pgAdvancedCopyGraph(b, []string{"id", "payload", "second_local", "first_local"})
		if err != nil || len(layout.Replaced) != 1 || !layout.CreateInherits[b.Identity] {
			t.Fatalf("local inherited-child order: %v", err)
		}
		if _, err = pgAdvancedCopyGraph(b, []string{"payload", "id", "second_local", "first_local"}); err == nil {
			t.Fatal("a nonlocal declaration was silently reordered outside its declaring parent")
		}
	})
	t.Run("DeclarativeParentRetainsChildIdentity", func(t *testing.T) {
		b := load("parts")
		layout, err := pgAdvancedCopyGraph(b, []string{"payload", "id"})
		if err != nil || len(layout.Replaced) != 1 || !layout.Replaced[b.Identity] {
			t.Fatalf("declarative target recreation graph: %v", err)
		}
		for id, target := range layout.Targets {
			if target.Table == "leaf" && !reflect.DeepEqual(layout.Orders[id], []string{"id", "payload"}) {
				t.Fatal("an unaffected partition physical order was changed")
			}
		}
	})
	t.Run("MetadataOnlyEffectivePrivileges", func(t *testing.T) {
		b := load("secured")
		b.AdvancedEvidence = tableedit.CloneAdvancedEvidence(b.AdvancedEvidence)
		if pgAdvancedCopyMetadata(ctx, f.conn, &b) == nil {
			t.Fatal("copy metadata accepted an unverified catalog resolution context")
		}
		tx, err := f.conn.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx)
		if _, err = tx.Exec(ctx, "SET LOCAL search_path=pg_catalog"); err != nil {
			t.Fatal(err)
		}
		reader := &pgCopyDiagnosticReader{structureReader: tx}
		if err := pgAdvancedCopyMetadata(ctx, reader, &b); err != nil {
			if server, ok := reader.err.(*pgconn.PgError); ok {
				t.Fatalf("copy metadata rejection SQLSTATE %s position %d", server.Code, server.Position)
			}
			t.Fatal(err)
		}
		if len(b.AdvancedEvidence.Rows["global/copyRIFunctions"]) != 12 {
			t.Fatal("native RI function proof is incomplete")
		}
		tableGrant, columnGrant := false, false
		for _, grant := range b.AdvancedEvidence.Rows[b.Identity+"/copyPrivileges"] {
			if grant["grantee"] == "0" && grant["grantable"] == false {
				tableGrant = tableGrant || grant["column"] == "" && grant["privilege"] == "SELECT"
				columnGrant = columnGrant || grant["column"] == "payload" && grant["privilege"] == "UPDATE"
			}
		}
		if !tableGrant || !columnGrant {
			t.Fatal("complete table/column grant identities were not captured")
		}
	})
}

func TestStructureAdvancedCopyNativeRLSCatalogAndValuesLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("secured") + "(id integer,payload text DEFAULT 'default',n numeric(30,4),b bytea) WITH(fillfactor=70)")
	f.exec("ALTER TABLE " + f.table("secured") + " ALTER COLUMN payload SET STORAGE EXTERNAL")
	f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ROW LEVEL SECURITY")
	f.exec("ALTER TABLE " + f.table("secured") + " FORCE ROW LEVEL SECURITY")
	f.exec("CREATE POLICY retained ON " + f.table("secured") + " USING(id>0) WITH CHECK(id>0)")
	f.exec("ALTER TABLE " + f.table("secured") + " ADD CONSTRAINT retained_pk PRIMARY KEY(id)")
	f.exec("CREATE INDEX retained_numeric ON " + f.table("secured") + "(n)")
	f.exec("COMMENT ON TABLE " + f.table("secured") + " IS 'retained table'")
	f.exec("COMMENT ON COLUMN " + f.table("secured") + ".payload IS 'retained column'")
	f.exec("GRANT SELECT ON " + f.table("secured") + " TO PUBLIC")
	f.exec("GRANT UPDATE(payload) ON " + f.table("secured") + " TO PUBLIC")
	f.exec("INSERT INTO " + f.table("secured") + " VALUES(1,'',12345678901234567890.1234,decode('00ff','hex')),(2,'NULL',NULL,NULL),(3,NULL,-123.4000,decode('ff00','hex'))")
	tx, err := f.conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	exec := func(sql string) {
		t.Helper()
		if _, err := tx.Exec(ctx, sql); err != nil {
			if server, ok := err.(*pgconn.PgError); ok {
				t.Fatalf("reviewed native copy failed SQLSTATE %s", server.Code)
			}
			t.Fatal("reviewed native copy failed")
		}
	}
	exec("SET LOCAL search_path=pg_catalog")
	exec("LOCK TABLE ONLY " + f.table("secured") + " IN ACCESS EXCLUSIVE MODE")
	target := tableedit.Target{Schema: f.schema, Table: "secured"}
	load := func() tableedit.Baseline {
		t.Helper()
		b, err := readStructure(ctx, tx, target)
		if err != nil || pgAdvancedCopyMetadata(ctx, tx, &b) != nil {
			t.Fatal("complete native copy catalog unavailable")
		}
		return b
	}
	before := load()
	layout, err := pgAdvancedCopyGraph(before, []string{"payload", "id", "b", "n"})
	if err != nil {
		t.Fatal(err)
	}
	definitions, err := pgAdvancedCopyReadDefinitions(ctx, tx, before, layout)
	if err != nil {
		t.Fatal(err)
	}
	proof, err := pgAdvancedDataCapture(ctx, tx, before, tableedit.Condition{Operation: tableedit.Operation{Kind: "reorder"}})
	if err != nil {
		t.Fatal(err)
	}
	temporary := tableedit.Target{Schema: f.schema, Table: "copy_secured"}
	exec("CREATE TABLE " + pgPhysicalName(temporary) + "(payload text DEFAULT 'default',id integer,b bytea,n numeric(30,4)) WITH(fillfactor=70)")
	exec("ALTER TABLE " + pgPhysicalName(temporary) + " ALTER COLUMN payload SET STORAGE EXTERNAL")
	exec("ALTER TABLE " + pgPhysicalName(temporary) + " ENABLE ROW LEVEL SECURITY")
	exec("ALTER TABLE " + pgPhysicalName(temporary) + " FORCE ROW LEVEL SECURITY")
	for _, p := range definitions.Policies[before.Identity] {
		exec(p.SQL(temporary))
	}
	exec("INSERT INTO " + pgPhysicalName(temporary) + "(id,payload,n,b) SELECT id,payload,n,b FROM ONLY " + f.table("secured"))
	remaining := pgAdvancedDataMaxBytes
	rows, err := pgAdvancedReadData(ctx, tx, temporary, proof.Relations[0].Columns, &remaining)
	if err != nil || !reflect.DeepEqual(rows, proof.Relations[0].Rows) {
		t.Fatal("temporary native copy did not preserve every value")
	}
	exec("DROP TABLE " + f.table("secured") + " RESTRICT")
	exec("ALTER TABLE " + pgPhysicalName(temporary) + " RENAME TO secured")
	exec("ALTER TABLE " + f.table("secured") + " ADD CONSTRAINT retained_pk PRIMARY KEY(id)")
	exec("CREATE INDEX retained_numeric ON " + f.table("secured") + "(n)")
	exec("COMMENT ON TABLE " + f.table("secured") + " IS 'retained table'")
	exec("COMMENT ON COLUMN " + f.table("secured") + ".payload IS 'retained column'")
	acl, err := pgAdvancedCopyACL(ctx, tx, before, "TABLE", f.table("secured"), fmt.Sprint(before.AdvancedEvidence.Rows[before.Identity+"/class"][0]["relowner"]), before.AdvancedEvidence.Rows[before.Identity+"/copyPrivileges"])
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range acl {
		exec(statement)
	}
	after := load()
	if err = pgAdvancedCopyPreservationError(before, after, layout.Orders, layout.Replaced); err != nil {
		t.Fatal(err)
	}
	proof.Relations[0].OID = after.Identity
	if err = proof.Verify(ctx, tx); err != nil {
		t.Fatal(err)
	}
	if err = tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	s := &Session{conn: f.conn}
	baseline, err := s.StructureLoad(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	prepared, err := s.preparePGAdvancedCopy(ctx, baseline, []string{"payload", "id", "b", "n"})
	if err != nil {
		t.Fatal(err)
	}
	for i, step := range s.applyPGAdvancedCopy(ctx, baseline, tableedit.Plan{SQL: prepared.SQL, Reconstruction: prepared.Reconstruction}) {
		if step.State != "applied" || step.Message != "" {
			t.Fatalf("generic native copy step %d state=%s message=%s", i, step.State, step.Message)
		}
	}
}
