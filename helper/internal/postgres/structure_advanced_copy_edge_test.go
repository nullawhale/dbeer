package postgres

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/tableedit"
)

func TestAdvancedCopyDependencyAddresses(t *testing.T) {
	b := pgCopyFixture(100, 200, []string{"id", "note"}, []string{"id", "note"})
	l := &pgAdvancedCopyLayout{Targets: map[string]tableedit.Target{}, Replaced: map[string]bool{"100": true, "200": true}}
	for id, facts := range b.AdvancedEvidence.Facts {
		for _, attr := range b.AdvancedEvidence.Rows[id+"/attributes"] {
			if attr["attname"] == "id" {
				attr["attidentity"] = ""
			}
		}
		for _, sequence := range b.AdvancedEvidence.Rows[id+"/sequences"] {
			for _, dependency := range sequence["dependencies"].([]any) {
				dependency.(map[string]any)["deptype"] = "a"
			}
		}
		l.Targets[id] = tableedit.Target{Schema: facts.Table.Ref.Schema, Table: facts.Table.Ref.Name}
		for _, category := range []string{"rules", "statistics", "publication"} {
			b.AdvancedEvidence.Rows[id+"/"+category] = []map[string]any{}
		}
		rows := []map[string]any{}
		for _, row := range b.AdvancedEvidence.Rows[id+"/dependencies"] {
			if fmt.Sprint(row["classid"]) != "9999" {
				rows = append(rows, row)
			}
		}
		b.AdvancedEvidence.Rows[id+"/dependencies"] = rows
	}
	digest := tableedit.Fingerprint(b.AdvancedEvidence)
	if err := pgAdvancedCopyDependencyBoundary(b, l); err != nil || digest != tableedit.Fingerprint(b.AdvancedEvidence) {
		t.Fatal("a complete owned-member graph was changed or refused")
	}
	for _, dependency := range []map[string]any{
		pgCopyDep("2618", 990001, 0, "1259", 100, 1, "n"),
		pgCopyDep("1255", 990002, 0, "1247", 101, 0, "n"),
		pgCopyDep("2606", 110, 0, "1259", 100, 1, "n"),
		pgCopyDep("1259", 100, 0, "3079", 990003, 0, "e"),
	} {
		next := b
		next.AdvancedEvidence = tableedit.CloneAdvancedEvidence(b.AdvancedEvidence)
		next.AdvancedEvidence.Rows["100/dependencies"] = append(next.AdvancedEvidence.Rows["100/dependencies"], dependency)
		if pgAdvancedCopyDependencyBoundary(next, l) == nil {
			t.Fatal("an outside dependent, catalog-OID collision or extension membership gained implicit reconstruction authority")
		}
	}
	retainedSequence := b
	retainedSequence.AdvancedEvidence = tableedit.CloneAdvancedEvidence(b.AdvancedEvidence)
	retainedSequence.AdvancedEvidence.Rows["100/dependencies"] = append(retainedSequence.AdvancedEvidence.Rows["100/dependencies"], pgCopyDep("2618", 990004, 0, "1259", 114, 0, "n"))
	if pgAdvancedCopyDependencyBoundary(retainedSequence, l) != nil {
		t.Fatal("an outside user of a retained physical serial-sequence identity was treated as dropped")
	}
	for _, catalogObject := range []struct {
		catalog string
		object  int
	}{{"3256", 112}, {"2604", 113}, {"2606", 111}, {"1259", 100}} {
		next := b
		next.AdvancedEvidence = tableedit.CloneAdvancedEvidence(b.AdvancedEvidence)
		selectedChild := &pgAdvancedCopyLayout{Targets: l.Targets, Replaced: map[string]bool{"200": true}}
		next.AdvancedEvidence.Rows["100/dependencies"] = append(next.AdvancedEvidence.Rows["100/dependencies"], pgCopyDep(catalogObject.catalog, catalogObject.object, 0, "1259", 200, 1, "n"))
		if pgAdvancedCopyDependencyBoundary(next, selectedChild) == nil {
			t.Fatal("a captured but retained object was treated as explicitly recreated or relinked")
		}
	}
}

func TestAdvancedCopyRetainedPolicyDependencyPreviewLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("parent") + "(id integer,payload text)")
	f.exec("CREATE TABLE " + f.table("child") + "(id integer,payload text)")
	f.exec("ALTER TABLE " + f.table("child") + " INHERIT " + f.table("parent"))
	f.exec("INSERT INTO " + f.table("child") + " VALUES(1,''),(1,''),(NULL,'NULL'),(NULL,NULL)")
	f.exec("CREATE SEQUENCE " + f.table("inspection_calls"))
	f.exec("CREATE FUNCTION " + f.table("inspection_marker") + "() RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$BEGIN PERFORM pg_catalog.nextval('" + f.table("inspection_calls") + "'::pg_catalog.regclass); RETURN true; END$$")
	f.exec("ALTER TABLE " + f.table("parent") + " ENABLE ROW LEVEL SECURITY")
	f.exec("ALTER TABLE " + f.table("parent") + " FORCE ROW LEVEL SECURITY")
	f.exec("CREATE POLICY retained ON " + f.table("parent") + " USING(" + f.table("inspection_marker") + "() AND EXISTS(SELECT 1 FROM ONLY " + f.table("child") + " c WHERE c.id=parent.id))")
	s := &Session{conn: f.conn}
	b, err := s.StructureLoad(ctx, tableedit.Target{Schema: f.schema, Table: "child"})
	if err != nil {
		t.Fatal("retained-parent policy fixture metadata unavailable")
	}
	if _, err = s.preparePGAdvancedCopy(ctx, b, []string{"payload", "id"}); err == nil || !strings.Contains(err.Error(), "This client does not yet reconstruct an outside object") {
		t.Fatal("a retained parent's dependency on the selected child was not refused during Preview")
	}
	var value string
	var called bool
	if f.observer.QueryRow(ctx, "SELECT last_value::pg_catalog.text,is_called FROM "+f.table("inspection_calls")).Scan(&value, &called) != nil || value != "1" || called {
		t.Fatal("Preview invoked the retained policy's authored routine")
	}
	fresh, err := s.StructureLoad(ctx, b.Target)
	if err != nil || fresh.Identity != b.Identity || fresh.Fingerprint != b.Fingerprint {
		t.Fatal("retained-policy Preview changed the original complete structure")
	}
}

func TestAdvancedCopyOutsideDependencyPreviewLive(t *testing.T) {
	for _, mode := range []string{"View", "RowTypeFunction"} {
		t.Run(mode, func(t *testing.T) {
			f := newChangeFixture(t)
			ctx := context.Background()
			f.exec("CREATE TABLE " + f.table("secured") + "(id integer,payload text)")
			f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ROW LEVEL SECURITY")
			f.exec("INSERT INTO " + f.table("secured") + " VALUES(1,''),(1,''),(NULL,'NULL'),(NULL,NULL)")
			f.exec("CREATE SEQUENCE " + f.table("inspection_calls"))
			if mode == "View" {
				f.exec("CREATE VIEW " + f.table("outside_view") + " AS SELECT id,payload FROM " + f.table("secured"))
			} else {
				f.exec("CREATE FUNCTION " + f.table("outside_function") + "(value " + f.table("secured") + ") RETURNS integer LANGUAGE plpgsql IMMUTABLE AS $$BEGIN PERFORM pg_catalog.nextval('" + f.table("inspection_calls") + "'::pg_catalog.regclass); RETURN value.id; END$$")
			}
			s := &Session{conn: f.conn}
			b, err := s.StructureLoad(ctx, tableedit.Target{Schema: f.schema, Table: "secured"})
			if err != nil {
				t.Fatal("outside-dependency fixture metadata unavailable")
			}
			if _, err = s.preparePGAdvancedCopy(ctx, b, []string{"payload", "id"}); err == nil || !strings.Contains(err.Error(), "This client does not yet reconstruct an outside object") {
				t.Fatal("an unsupported outside dependency was not refused precisely during catalog-only Preview")
			}
			var called bool
			var value string
			if f.observer.QueryRow(ctx, "SELECT last_value::pg_catalog.text,is_called FROM "+f.table("inspection_calls")).Scan(&value, &called) != nil || value != "1" || called {
				t.Fatal("Preview evaluated an outside user routine")
			}
			fresh, err := s.StructureLoad(ctx, b.Target)
			if err != nil || fresh.Identity != b.Identity || fresh.Fingerprint != b.Fingerprint {
				t.Fatal("outside-dependency Preview changed the observed structure")
			}
		})
	}
}

func TestAdvancedCopyGeneratedOnlyMultiplicityLive(t *testing.T) {
	for _, mode := range []string{"Preserved", "LateGeneratedValue"} {
		t.Run(mode, func(t *testing.T) {
			f := newChangeFixture(t)
			ctx := context.Background()
			f.exec("CREATE FUNCTION " + f.table("retained_value") + "() RETURNS integer LANGUAGE plpgsql IMMUTABLE AS $$BEGIN RETURN 1; END$$")
			f.exec("CREATE TABLE " + f.table("secured") + "(a integer GENERATED ALWAYS AS(" + f.table("retained_value") + "()) STORED,b integer GENERATED ALWAYS AS(2) STORED)")
			f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ROW LEVEL SECURITY")
			f.exec("ALTER TABLE " + f.table("secured") + " FORCE ROW LEVEL SECURITY")
			for i := 0; i < 4; i++ {
				f.exec("INSERT INTO " + f.table("secured") + " DEFAULT VALUES")
			}
			s := &Session{conn: f.conn}
			b, err := s.StructureLoad(ctx, tableedit.Target{Schema: f.schema, Table: "secured"})
			if err != nil {
				t.Fatal("generated-only fixture metadata unavailable")
			}
			p, err := s.preparePGAdvancedCopy(ctx, b, []string{"b", "a"})
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(strings.Join(p.SQL, "\n"), " () SELECT ") {
				t.Fatal("generated-only Preview contains an empty explicit target list")
			}
			var envelope pgAdvancedCopyEnvelope
			if json.Unmarshal([]byte(p.Reconstruction.ExpectedDefinition), &envelope) != nil {
				t.Fatal("generated-only private plan unavailable")
			}
			mutated := false
			var mutationError error
			if mode == "LateGeneratedValue" {
				s.afterStructureStep = func(i int) {
					if i == envelope.CopyStep {
						mutated = true
						if _, mutationError = f.conn.Exec(ctx, "CREATE OR REPLACE FUNCTION "+f.table("retained_value")+"() RETURNS integer LANGUAGE plpgsql IMMUTABLE AS $$BEGIN RETURN 7; END$$"); mutationError == nil {
							_, mutationError = f.conn.Exec(ctx, "DELETE FROM ONLY "+pgPhysicalName(envelope.Family.Destinations[b.Identity]))
						}
						if mutationError == nil {
							_, mutationError = f.conn.Exec(ctx, "INSERT INTO "+pgPhysicalName(envelope.Family.Destinations[b.Identity])+" SELECT FROM ONLY "+pgPhysicalName(b.Target))
						}
					}
				}
			}
			steps := s.applyPGAdvancedCopy(ctx, b, tableedit.Plan{SQL: p.SQL, Reconstruction: p.Reconstruction})
			if mutationError != nil {
				t.Fatal("the owned generated-only late mutation failed")
			}
			for i, step := range steps {
				if mode == "Preserved" && (step.State != "applied" || step.Message != "") {
					t.Fatalf("generated-only copy step %d state=%s message=%s", i, step.State, step.Message)
				}
				if mode == "LateGeneratedValue" && (step.State != "rolledBack" && step.State != "notStarted") {
					t.Fatal("generated-only retained-value mismatch escaped rollback")
				}
			}
			if mode == "LateGeneratedValue" {
				if !mutated {
					t.Fatal("the intended generated-only mismatch boundary was not reached")
				}
				for _, step := range steps[envelope.DropStep:] {
					if step.State != "notStarted" {
						t.Fatal("source DROP was sent before exact generated-only multiplicity/value proof")
					}
				}
			}
			var count int
			if f.observer.QueryRow(ctx, "SELECT count(*) FROM "+f.table("secured")+" WHERE a=1 AND b=2").Scan(&count) != nil || count != 4 {
				t.Fatal("generated-only row values or duplicate multiplicity changed")
			}
		})
	}
}

func TestAdvancedCopyPartitionLeafConstraintsLive(t *testing.T) {
	for _, mode := range []string{"Check", "PrimaryKey"} {
		t.Run(mode, func(t *testing.T) {
			f := newChangeFixture(t)
			ctx := context.Background()
			f.exec("CREATE SEQUENCE " + f.table("trigger_calls"))
			f.exec("CREATE FUNCTION " + f.table("retained_trigger") + "() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN PERFORM pg_catalog.nextval('" + f.table("trigger_calls") + "'::pg_catalog.regclass); RETURN NEW; END$$")
			key := ""
			if mode == "PrimaryKey" {
				key = ",CONSTRAINT retained_primary PRIMARY KEY(id)"
			}
			f.exec("CREATE TABLE " + f.table("parent") + "(id integer NOT NULL,payload text,n numeric(30,4),b bytea,g integer GENERATED ALWAYS AS(id+1) STORED,CONSTRAINT positive CHECK(id>=0)" + key + ") PARTITION BY RANGE(id)")
			leaf := "leaf"
			if mode == "PrimaryKey" {
				leaf = "former_leaf"
			}
			f.exec("CREATE TABLE " + f.table(leaf) + " PARTITION OF " + f.table("parent") + " FOR VALUES FROM(0) TO(100)")
			if leaf != "leaf" {
				f.exec("ALTER TABLE " + f.table(leaf) + " RENAME TO leaf")
			}
			pgFamilyRichProperties(t, f, "parent")
			pgFamilyRichProperties(t, f, "leaf")
			f.exec("INSERT INTO " + f.table("parent") + "(id,payload,n,b) VALUES(1,'',12345678901234567890.1234,decode('00ff','hex')),(2,'NULL',NULL,NULL),(3,NULL,-123.4000,decode('ff00','hex'))")
			var calls string
			if f.observer.QueryRow(ctx, "SELECT last_value::pg_catalog.text FROM "+f.table("trigger_calls")).Scan(&calls) != nil {
				t.Fatal("retained trigger positive control unavailable")
			}
			s := &Session{conn: f.conn}
			before, err := s.StructureLoad(ctx, tableedit.Target{Schema: f.schema, Table: "leaf"})
			if err != nil {
				t.Fatal("partition-leaf fixture metadata unavailable")
			}
			p, err := s.preparePGAdvancedCopy(ctx, before, []string{"payload", "g", "id", "b", "n"})
			if err != nil {
				t.Fatal(err)
			}
			if mode == "PrimaryKey" {
				s.afterStructureStep = func(i int) {
					if i != len(p.SQL)-2 {
						return
					}
					after, e := readStructure(ctx, f.conn, before.Target)
					if e != nil || pgAdvancedCopyMetadata(ctx, f.conn, &after) != nil {
						t.Fatal("partition-leaf diagnostic metadata unavailable")
					}
					old := tableedit.CloneAdvancedEvidence(before.AdvancedEvidence)
					next := tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
					for _, left := range old.Facts {
						for _, right := range next.Facts {
							if left.Table.Ref == right.Table.Ref && pgAdvancedCopyFacts(left, right) != nil {
								paths := []string{}
								pgCopyGraphDifferencePaths(reflect.ValueOf(left), reflect.ValueOf(right), "facts", &paths)
								t.Log("partition-leaf diagnostic field paths:", paths)
							}
						}
					}
				}
			}
			steps := s.applyPGAdvancedCopy(ctx, before, tableedit.Plan{SQL: p.SQL, Reconstruction: p.Reconstruction})
			for i, step := range steps {
				if step.State != "applied" || step.Message != "" {
					t.Fatalf("partition-leaf copy step %d state=%s message=%s", i, step.State, step.Message)
				}
			}
			after, err := s.StructureLoad(ctx, before.Target)
			if err != nil || after.Identity == before.Identity {
				t.Fatal("the reviewed partition leaf was not replaced")
			}
			var nextCalls string
			if f.observer.QueryRow(ctx, "SELECT last_value::pg_catalog.text FROM "+f.table("trigger_calls")).Scan(&nextCalls) != nil || nextCalls != calls {
				t.Fatal("partition-leaf copy replayed local or cloned parent INSERT triggers")
			}
		})
	}
}
