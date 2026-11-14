package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/tableedit"
)

func pgFamilyPureFixture(t *testing.T, version int, nonlocal bool) tableedit.Baseline {
	t.Helper()
	b := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
	b.Fingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	for id, facts := range b.AdvancedEvidence.Facts {
		facts.ServerVersion = version
		for _, a := range b.AdvancedEvidence.Rows[id+"/attributes"] {
			if id == "120" {
				a["attinhcount"] = 1
				a["attislocal"] = !nonlocal
			}
			if version >= 180000 && a["attnotnull"] == true {
				b.AdvancedEvidence.Rows[id+"/constraints"] = append(b.AdvancedEvidence.Rows[id+"/constraints"], map[string]any{"oid": id + "9", "conrelid": id, "contype": "n", "conname": func() string {
					if id == "120" && nonlocal {
						return b.AdvancedEvidence.Facts["100"].Table.Ref.Name + "_id_not_null"
					}
					return facts.Table.Ref.Name + "_id_not_null"
				}(), "conkey": []any{a["attnum"]}, "conislocal": id == "100" || !nonlocal, "connoinherit": false, "convalidated": true})
			}
		}
	}
	return b
}

func TestAdvancedCopyFamilyPurePlan(t *testing.T) {
	for _, version := range []int{140000, 170000, 180000} {
		t.Run(fmt.Sprint(version), func(t *testing.T) {
			b := pgFamilyPureFixture(t, version, true)
			layout, err := pgAdvancedCopyGraph(b, []string{"note", "id"})
			if err != nil {
				t.Fatal(err)
			}
			before := pgAdvancedCopyJSON([]any{b.AdvancedEvidence, layout})
			plan, err := pgAdvancedCopyFamilyPlan(b, layout, pgAdvancedCopyDefinitions{})
			if err != nil {
				t.Fatal(err)
			}
			if before != pgAdvancedCopyJSON([]any{b.AdvancedEvidence, layout}) {
				t.Fatal("family planning mutated its input")
			}
			if len(plan.Destinations) != 2 || len(plan.RowSources) != 2 || len(plan.BeforeDrop) != 0 || len(plan.AfterIndexes) != 0 {
				t.Fatal("traditional family lifecycle was not exact")
			}
			if plan.Destinations["120"] != layout.Temporary["120"] || plan.RowSources["120"] != layout.Targets["120"] || len(plan.BeforeCreate) != 0 || len(plan.AfterDrop) != 2 {
				t.Fatal("family source identity/name lifecycle was changed unnecessarily")
			}
		})
	}
	b := pgFamilyPureFixture(t, 180000, false)
	b.Identity = "120"
	b.Target = tableedit.Target{Schema: "exact_schema", Table: "child"}
	b.Facts = b.AdvancedEvidence.Facts["120"]
	l, err := pgAdvancedCopyGraph(b, []string{"note", "id"})
	if err != nil {
		t.Fatal(err)
	}
	p, err := pgAdvancedCopyFamilyPlan(b, l, pgAdvancedCopyDefinitions{})
	if err != nil || len(p.AfterIndexes) != 1 || !strings.Contains(p.AfterIndexes[0], " INHERIT ") || len(p.Destinations) != 1 {
		t.Fatal("all-local child inheritance was not restored after native definitions")
	}
	if !strings.Contains(p.InlineNotNull["120"]["id"], `"child_id_not_null"`) {
		t.Fatal("the captured local NOT NULL name was not declared")
	}
	partition, _ := pgCopyPartitionTriggerFixture(170000)
	partition.Fingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	partLayout, err := pgAdvancedCopyGraph(partition, []string{"note", "id"})
	if err != nil {
		t.Fatal(err)
	}
	part, err := pgAdvancedCopyFamilyPlan(partition, partLayout, pgAdvancedCopyDefinitions{PartitionBound: map[string]string{"120": "FOR VALUES FROM (0) TO (100)"}})
	if err != nil || len(part.Destinations) != 1 || len(part.BeforeDrop) != 1 || len(part.AfterIndexes) != 1 || !strings.Contains(part.BeforeDrop[0], " DETACH PARTITION ") || !strings.Contains(part.AfterIndexes[0], " ATTACH PARTITION ") {
		t.Fatal("retained partition lifecycle was not exact")
	}
	if _, err := pgAdvancedCopyFamilyPlan(partition, partLayout, pgAdvancedCopyDefinitions{}); err == nil {
		t.Fatal("missing partition bound acquired family authority")
	}
	seeded := pgFamilyPureFixture(t, 170000, true)
	seedLayout, err := pgAdvancedCopyGraph(seeded, []string{"note", "id"})
	if err != nil {
		t.Fatal(err)
	}
	seeded.Fingerprint = strings.Repeat("f", 64)
	if preserved, err := pgAdvancedCopyFamilyPlan(seeded, seedLayout, pgAdvancedCopyDefinitions{}); err != nil || preserved.Destinations["100"] != seedLayout.Temporary["100"] {
		t.Fatal("the reviewed name seed was incorrectly used as observation freshness")
	}
}

func TestAdvancedCopyFamilyPlanRejectsUnreviewedState(t *testing.T) {
	b := pgFamilyPureFixture(t, 180000, true)
	l, err := pgAdvancedCopyGraph(b, []string{"note", "id"})
	if err != nil {
		t.Fatal(err)
	}
	l.Orders["120"] = []string{"id", "note"}
	if _, err := pgAdvancedCopyFamilyPlan(b, l, pgAdvancedCopyDefinitions{}); err == nil {
		t.Fatal("changed child order acquired family authority")
	}
	l, err = pgAdvancedCopyGraph(b, []string{"note", "id"})
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range b.AdvancedEvidence.Rows["120/constraints"] {
		if c["contype"] == "n" {
			c["conname"] = "custom_inherited_name"
		}
	}
	if _, err := pgAdvancedCopyFamilyPlan(b, l, pgAdvancedCopyDefinitions{}); err == nil || !strings.Contains(err.Error(), "client") {
		t.Fatal("an unsupported inherited native name was silently normalized")
	}
}

type pgFamilyEnvelope struct {
	Layout             *pgAdvancedCopyLayout
	Family             *pgAdvancedCopyFamilySteps
	Evidence           *tableedit.AdvancedEvidence
	CopyStep, DropStep int
}

func pgFamilyRichProperties(t *testing.T, f *changeFixture, name string) {
	t.Helper()
	f.exec("ALTER TABLE ONLY " + f.table(name) + " ENABLE ROW LEVEL SECURITY")
	f.exec("ALTER TABLE ONLY " + f.table(name) + " FORCE ROW LEVEL SECURITY")
	f.exec("CREATE POLICY retained ON " + f.table(name) + " USING(id>0) WITH CHECK(id>0)")
	f.exec("ALTER TABLE ONLY " + f.table(name) + " ALTER COLUMN payload SET STORAGE EXTERNAL")
	f.exec("ALTER TABLE ONLY " + f.table(name) + " ALTER COLUMN payload SET COMPRESSION pglz")
	f.exec("ALTER TABLE ONLY " + f.table(name) + " ALTER COLUMN payload SET STATISTICS 500")
	f.exec("ALTER TABLE ONLY " + f.table(name) + " ALTER COLUMN payload SET(n_distinct=-0.5)")
	f.exec("CREATE INDEX keep_" + name + "_numeric ON " + f.table(name) + "((n+0)) WITH(fillfactor=61)")
	f.exec("ALTER INDEX " + f.table("keep_"+name+"_numeric") + " ALTER COLUMN 1 SET STATISTICS 321")
	f.exec("CREATE TRIGGER keep_" + name + " BEFORE INSERT ON " + f.table(name) + " FOR EACH ROW EXECUTE FUNCTION " + f.table("retained_trigger") + "()")
	f.exec("COMMENT ON TABLE " + f.table(name) + " IS 'retained family table'")
	f.exec("COMMENT ON COLUMN " + f.table(name) + ".payload IS 'retained family column'")
	f.exec("COMMENT ON TYPE " + f.table("_"+name) + " IS 'retained family array'")
	f.exec("COMMENT ON INDEX " + f.table("keep_"+name+"_numeric") + " IS 'retained expression index'")
	f.exec("GRANT SELECT ON " + f.table(name) + " TO PUBLIC")
	f.exec("GRANT UPDATE(payload) ON " + f.table(name) + " TO PUBLIC")
	b, err := (&Session{conn: f.conn}).StructureLoad(context.Background(), tableedit.Target{Schema: f.schema, Table: name})
	if err != nil {
		t.Fatal("native family setup capture failed")
	}
	if len(b.AdvancedEvidence.Rows[b.Identity+"/toast"]) > 0 {
		f.exec("COMMENT ON INDEX " + pgCopyExtrasToastIndex(t, b) + " IS 'retained family toast index'")
	}
}

func pgFamilyReadSequence(t *testing.T, s *Session, target tableedit.Target) pgAdvancedSequenceValue {
	t.Helper()
	tx, err := s.conn.Begin(context.Background())
	if err != nil {
		t.Fatal("owned sequence observation could not begin")
	}
	defer tx.Rollback(context.Background())
	v, err := pgAdvancedReadSequence(context.Background(), tx, target)
	if err != nil {
		t.Fatal("complete native sequence/session observation unavailable")
	}
	if err := tx.Commit(context.Background()); err != nil {
		t.Fatal("owned sequence observation did not finish")
	}
	return v
}

func TestAdvancedCopyFamilyGenericLive(t *testing.T) {
	for _, mode := range []string{"Traditional", "LocalChild", "Partition", "SerialDefined", "SerialUndefined", "LateChildRow", "LateChildSecurity", "LateChildProperty", "CachedCounterMutation", "UnknownCommit"} {
		t.Run(mode, func(t *testing.T) {
			f := newChangeFixture(t)
			ctx := context.Background()
			s := &Session{conn: f.conn}
			if mode == "Partition" {
				if _, err := f.conn.Exec(ctx, "SET default_tablespace='pg_default'"); err != nil {
					t.Fatal("owned nonempty creation context setup failed")
				}
			}
			f.exec("CREATE SEQUENCE " + f.table("trigger_calls"))
			f.exec("CREATE FUNCTION " + f.table("retained_trigger") + "() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN PERFORM pg_catalog.nextval('" + f.table("trigger_calls") + "'::pg_catalog.regclass); RETURN NEW; END$$")
			serial := strings.HasPrefix(mode, "Serial") || mode == "CachedCounterMutation"
			selected := "parent"
			order := []string{"payload", "g", "id", "b", "n"}
			if serial {
				selected = "serial_source"
				f.exec("CREATE SEQUENCE " + f.table("owned_seq") + " AS bigint START WITH 9007199254740993 INCREMENT BY 7 CACHE 17")
				f.exec("CREATE TABLE " + f.table(selected) + "(id bigint NOT NULL DEFAULT nextval(" + postgresTextLiteral(f.table("owned_seq")) + "::pg_catalog.regclass),payload text DEFAULT 'default',n numeric(30,4),b bytea,g bigint GENERATED ALWAYS AS(id+1) STORED,CONSTRAINT positive CHECK(id>=0),CONSTRAINT serial_primary PRIMARY KEY(id)) WITH(fillfactor=70)")
				f.exec("ALTER SEQUENCE " + f.table("owned_seq") + " OWNED BY " + f.table(selected) + ".id")
				f.exec("COMMENT ON SEQUENCE " + f.table("owned_seq") + " IS 'retained cached serial'")
				f.exec("GRANT USAGE ON SEQUENCE " + f.table("owned_seq") + " TO PUBLIC")
				if mode != "SerialUndefined" {
					if _, err := f.conn.Exec(ctx, "SELECT pg_catalog.nextval("+postgresTextLiteral(f.table("owned_seq"))+"::pg_catalog.regclass)"); err != nil {
						t.Fatal("owned sequence cache setup failed")
					}
				}
				pgFamilyRichProperties(t, f, selected)
				f.exec("INSERT INTO " + f.table(selected) + "(id,payload,n,b) VALUES(1,'',12345678901234567890.1234,decode('00ff','hex')),(2,'NULL',NULL,NULL),(3,NULL,-123.4000,decode('ff00','hex'))")
			} else if mode == "Partition" {
				f.exec("CREATE TABLE " + f.table("parent") + "(id integer NOT NULL,payload text DEFAULT 'default',n numeric(30,4),b bytea,g integer GENERATED ALWAYS AS(id+1) STORED,CONSTRAINT positive CHECK(id>=0)) PARTITION BY RANGE(id)")
				f.exec("CREATE TABLE " + f.table("child") + " PARTITION OF " + f.table("parent") + " FOR VALUES FROM(0) TO(100) WITH(fillfactor=75)")
				f.exec("ALTER TABLE " + f.table("parent") + " ADD CONSTRAINT parent_primary PRIMARY KEY(id)")
				pgFamilyRichProperties(t, f, "parent")
				pgFamilyRichProperties(t, f, "child")
				f.exec("CREATE SEQUENCE " + f.table("owned_seq") + " AS bigint START WITH 9007199254740993 INCREMENT BY 7 CACHE 17 OWNED BY " + f.table("child") + ".id")
				f.exec("ALTER TABLE ONLY " + f.table("child") + " ALTER COLUMN id SET DEFAULT nextval(" + postgresTextLiteral(f.table("owned_seq")) + "::pg_catalog.regclass)")
				f.exec("INSERT INTO " + f.table("parent") + "(id,payload,n,b) VALUES(1,'',12345678901234567890.1234,decode('00ff','hex')),(2,'NULL',NULL,NULL),(3,NULL,-123.4000,decode('ff00','hex'))")
			} else {
				f.exec("CREATE TABLE " + f.table("parent") + "(id integer NOT NULL,payload text DEFAULT 'default',n numeric(30,4),b bytea,g integer GENERATED ALWAYS AS(id+1) STORED,CONSTRAINT positive CHECK(id>=0),CONSTRAINT parent_primary PRIMARY KEY(id)) WITH(fillfactor=70)")
				if mode == "LocalChild" {
					f.exec("CREATE TABLE " + f.table("child") + "(id integer NOT NULL,payload text DEFAULT 'default',n numeric(30,4),b bytea,g integer GENERATED ALWAYS AS(id+1) STORED,CONSTRAINT positive CHECK(id>=0)) WITH(fillfactor=75)")
					f.exec("ALTER TABLE " + f.table("child") + " INHERIT " + f.table("parent"))
					selected = "child"
				} else {
					f.exec("CREATE TABLE " + f.table("child") + "(local_tag text) INHERITS(" + f.table("parent") + ") WITH(fillfactor=75)")
				}
				pgFamilyRichProperties(t, f, "parent")
				pgFamilyRichProperties(t, f, "child")
				f.exec("INSERT INTO " + f.table("parent") + "(id,payload,n,b) VALUES(1,'',12345678901234567890.1234,decode('00ff','hex')),(2,'NULL',NULL,NULL),(3,NULL,-123.4000,decode('ff00','hex'))")
				if mode == "LocalChild" {
					f.exec("INSERT INTO " + f.table("child") + "(id,payload,n,b) VALUES(4,'NULL',99999999999999999999.0001,decode('00ff00','hex')),(4,'NULL',99999999999999999999.0001,decode('00ff00','hex')),(5,NULL,NULL,NULL)")
				} else {
					f.exec("INSERT INTO " + f.table("child") + "(id,payload,n,b,local_tag) VALUES(4,'NULL',99999999999999999999.0001,decode('00ff00','hex'),'same'),(4,'NULL',99999999999999999999.0001,decode('00ff00','hex'),'same'),(5,NULL,NULL,NULL,'')")
				}
			}
			b, err := s.StructureLoad(ctx, tableedit.Target{Schema: f.schema, Table: selected})
			if err != nil {
				t.Fatal("complete generic family source unavailable")
			}
			var oldSequence pgAdvancedSequenceValue
			seqTarget := tableedit.Target{Schema: f.schema, Table: "owned_seq"}
			if serial || mode == "Partition" {
				oldSequence = pgFamilyReadSequence(t, s, seqTarget)
			}
			var calls string
			if f.observer.QueryRow(ctx, "SELECT last_value::pg_catalog.text FROM "+f.table("trigger_calls")).Scan(&calls) != nil {
				t.Fatal("native trigger positive control unavailable")
			}
			p, err := s.preparePGAdvancedCopy(ctx, b, order)
			if err != nil {
				t.Fatal(err)
			}
			var envelope pgFamilyEnvelope
			if p.Reconstruction == nil || json.Unmarshal([]byte(p.Reconstruction.ExpectedDefinition), &envelope) != nil || envelope.Layout == nil || envelope.Family == nil || envelope.DropStep <= envelope.CopyStep {
				t.Fatal("the generic reviewed family plan is not bound in Preview")
			}
			for _, group := range [][]string{envelope.Family.BeforeCreate, envelope.Family.BeforeCopy, envelope.Family.BeforeDrop, envelope.Family.AfterDrop, envelope.Family.AfterIndexes, envelope.Family.AfterRestore} {
				for _, sql := range group {
					if !strings.Contains(strings.Join(p.SQL, "\n"), sql) {
						t.Fatal("family lifecycle SQL is hidden from Preview")
					}
				}
			}
			childID := ""
			for id, target := range envelope.Layout.Targets {
				if target.Table == "child" {
					childID = id
				}
			}
			attachPhase := -1
			if mode == "Partition" {
				for i, group := range p.SQL {
					for _, link := range envelope.Family.AfterIndexes {
						if strings.Contains(link, " ATTACH PARTITION ") && strings.Contains(group, link) {
							if attachPhase != -1 && attachPhase != i {
								t.Fatal("a native ATTACH was duplicated in Preview")
							}
							attachPhase = i
						}
					}
				}
				if attachPhase < 1 {
					t.Fatal("the native family ATTACH phase is missing")
				}
			}
			var mutationError error
			mutated, commitAttempted, lastStep := false, false, 0
			s.afterStructureStep = func(i int) {
				lastStep = i
				statement := ""
				if i == envelope.CopyStep {
					if mode == "LateChildRow" {
						statement = "UPDATE ONLY " + pgPhysicalName(envelope.Family.Destinations[childID]) + " SET payload='late mutation'"
					}
					if mode == "CachedCounterMutation" {
						statement = "SELECT pg_catalog.nextval(" + postgresTextLiteral(f.table("owned_seq")) + "::pg_catalog.regclass)"
					}
				}
				if i == len(p.SQL)-2 {
					if mode == "LateChildSecurity" {
						statement = "ALTER TABLE ONLY " + f.table("child") + " NO FORCE ROW LEVEL SECURITY"
					}
					if mode == "LateChildProperty" {
						statement = "ALTER INDEX " + f.table("keep_child_numeric") + " ALTER COLUMN 1 SET STATISTICS 322"
					}
				}
				if mode == "Partition" && i == attachPhase-1 {
					q := pgCatalogReader(f.conn)
					var parentKind bool
					if q.QueryRow(ctx, `SELECT c.relkind='p' FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname='parent'`, f.schema).Scan(&parentKind) != nil || !parentKind {
						t.Fatal("the reviewed ATTACH parent is not a native partitioned table")
					}
					var ordinary, detached, untyped, noParent, noChildren, persistent bool
					if q.QueryRow(ctx, `SELECT c.relkind='r',NOT c.relispartition,c.reloftype=0,NOT EXISTS(SELECT 1 FROM pg_catalog.pg_inherits i WHERE i.inhrelid=c.oid),NOT EXISTS(SELECT 1 FROM pg_catalog.pg_inherits i WHERE i.inhparent=c.oid),c.relpersistence='p' FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname='child'`, f.schema).Scan(&ordinary, &detached, &untyped, &noParent, &noChildren, &persistent) != nil {
						t.Fatal("native ATTACH precondition capture failed")
					}
					if !ordinary {
						t.Fatal("the retained ATTACH leaf is not an ordinary native table")
					}
					if !detached {
						t.Fatal("the retained ATTACH leaf is already a partition")
					}
					if !untyped {
						t.Fatal("the retained ATTACH leaf has a typed binding")
					}
					if !noParent {
						t.Fatal("the retained ATTACH leaf still inherits a table")
					}
					if !noChildren {
						t.Fatal("the retained ATTACH leaf has inheritance children")
					}
					if !persistent {
						t.Fatal("native ATTACH persistence does not match")
					}
				}
				if statement != "" {
					mutated = true
					_, mutationError = f.conn.Exec(ctx, statement)
				}
			}
			if mode == "UnknownCommit" {
				s.structureCommitOverride = func(commit func() error) error {
					commitAttempted = true
					if err := commit(); err != nil {
						return err
					}
					return errors.New("owned synthetic lost COMMIT acknowledgement")
				}
			}
			steps := s.applyPGAdvancedCopy(ctx, b, tableedit.Plan{SQL: p.SQL, Reconstruction: p.Reconstruction})
			for i, step := range steps {
				if strings.Contains(step.Message, "reviewed graph-copy statement failed") {
					t.Logf("native statement failure at phase %d; last completed phase %d; copy boundary %d; drop boundary %d", i, lastStep, envelope.CopyStep, envelope.DropStep)
					t.Log(step.Message)
				}
			}
			if mutationError != nil {
				t.Fatal("the owned late family mutation failed")
			}
			if mode == "UnknownCommit" {
				if !commitAttempted {
					t.Fatal("the family COMMIT boundary was not reached")
				}
				for _, step := range steps {
					if step.State != "unknown" {
						t.Fatal("lost family COMMIT acknowledgement became execution authority")
					}
				}
				if !f.conn.IsClosed() {
					t.Fatal("uncertain family COMMIT retained its physical connection")
				}
				return
			}
			negative := strings.HasPrefix(mode, "Late") || mode == "CachedCounterMutation"
			if negative {
				if !mutated {
					t.Fatal("the intended owned family mutation boundary was not reached")
				}
				for _, step := range steps {
					if step.State != "rolledBack" && step.State != "notStarted" {
						t.Fatalf("a family preservation failure escaped rollback: state=%s message=%s", step.State, step.Message)
					}
				}
				var oid string
				if f.observer.QueryRow(ctx, `SELECT c.oid::pg_catalog.text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2`, f.schema, selected).Scan(&oid) != nil || oid != b.Identity {
					t.Fatal("a failed generic family plan replaced its source")
				}
				if mode == "LateChildRow" || mode == "CachedCounterMutation" {
					for _, step := range steps[envelope.DropStep:] {
						if step.State != "notStarted" {
							t.Fatal("source DROP was sent before full family row/counter proof")
						}
					}
				}
				if mode == "CachedCounterMutation" {
					next := pgFamilyReadSequence(t, s, seqTarget)
					if next.Value != oldSequence.Value || next.Called != oldSequence.Called || next.Session == oldSequence.Session {
						t.Fatal("the cached counter control did not isolate owning-session currval state")
					}
				}
				return
			}
			for i, step := range steps {
				if step.State != "applied" || step.Message != "" {
					t.Fatalf("generic family copy step %d state=%s message=%s", i, step.State, step.Message)
				}
			}
			fresh, err := s.StructureLoad(ctx, b.Target)
			if err != nil || fresh.Identity == b.Identity {
				t.Fatal("generic family replacement was not observed")
			}
			if mode == "Partition" {
				var space string
				if f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('default_tablespace')").Scan(&space) != nil || space != "pg_default" {
					t.Fatal("generic family copy did not restore its exact owning creation context")
				}
			}
			if mode == "Partition" {
				if fresh.AdvancedEvidence.Facts[childID] == nil {
					t.Fatal("the generic parent copy replaced its retained leaf identity")
				}
			} else if mode == "Traditional" {
				for id := range envelope.Layout.Replaced {
					if fresh.AdvancedEvidence.Facts[id] != nil {
						t.Fatal("a reviewed traditional relation was not replaced")
					}
				}
			}
			if serial || mode == "Partition" {
				next := pgFamilyReadSequence(t, s, seqTarget)
				if next.Value != oldSequence.Value || next.Called != oldSequence.Called || next.Session != oldSequence.Session || !reflect.DeepEqual(next.Definition["class"], oldSequence.Definition["class"]) || !reflect.DeepEqual(next.Definition["sequence"], oldSequence.Definition["sequence"]) {
					t.Fatal("generic family copy changed retained sequence identity/configuration/cache/session state")
				}
			}
			var nextCalls string
			if f.observer.QueryRow(ctx, "SELECT last_value::pg_catalog.text FROM "+f.table("trigger_calls")).Scan(&nextCalls) != nil || nextCalls != calls {
				t.Fatal("generic family COPY replayed a retained INSERT trigger")
			}
		})
	}
}
