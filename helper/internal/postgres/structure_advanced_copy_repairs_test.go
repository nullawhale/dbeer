package postgres

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
)

func pgCopyRepairFixture() (*tableedit.AdvancedEvidence, []pgAdvancedCopyRepair) {
	b := pgCopyFixture(100, 200, []string{"id", "note"}, []string{"id", "note"})
	e := b.AdvancedEvidence
	repairs := []pgAdvancedCopyRepair{}
	for _, key := range []struct{ id, name string }{{"90001", "selected_one"}, {"90002", "selected_two"}} {
		row := map[string]any{"oid": key.id, "contype": "f", "conname": key.name, "conrelid": "200", "confrelid": "100", "conparentid": "0", "conislocal": true, "condeferrable": false, "condeferred": false, "convalidated": true, "confmatchtype": "s", "unknown_native": "retained"}
		for _, id := range []string{"100", "200"} {
			e.Rows[id+"/constraints"] = append(e.Rows[id+"/constraints"], row)
			e.Rows[id+"/class"][0]["relhastriggers"] = true
			e.Rows[id+"/triggers"] = append(e.Rows[id+"/triggers"], map[string]any{"oid": key.id + id, "tgrelid": id, "tgconstraint": key.id, "tgisinternal": true, "unknown_native": "exact"})
			e.Rows[id+"/dependencies"] = append(e.Rows[id+"/dependencies"], map[string]any{"classid": "2606", "objid": key.id, "refclassid": "1259", "refobjid": id, "deptype": "n"})
		}
		e.Facts["200"].Table.Constraints.Items = append(e.Facts["200"].Table.Constraints.Items, sc.Constraint{Ref: sc.Ref{Kind: "constraint", Schema: "exact_schema", Table: "child", Name: key.name}})
		e.Facts["100"].Incoming = append(e.Facts["100"].Incoming, tableedit.Incoming{Schema: "exact_schema", Table: "child", Name: key.name, Columns: []string{"id"}})
		repairs = append(repairs, pgAdvancedCopyRepair{Source: tableedit.Target{Schema: "exact_schema", Table: "child"}, SourceID: "200", ConstraintID: key.id, Name: key.name, ReferenceID: "100"})
	}
	return e, repairs
}

func TestAdvancedCopySelectedRepairUnionAndDrift(t *testing.T) {
	before, repairs := pgCopyRepairFixture()
	before.Rows["global/unknown_nil"] = nil
	digest := tableedit.Fingerprint(before)
	after, _, err := pgAdvancedCopyRepairExpected(before, repairs)
	if err != nil || pgAdvancedCopyRepairsPreserved(before, after, repairs) != nil || tableedit.Fingerprint(before) != digest {
		t.Fatal("complete selected removals were not proved on independent clones")
	}
	for _, mutation := range []struct {
		name   string
		change func(*tableedit.AdvancedEvidence)
	}{
		{"retainedConstraint", func(e *tableedit.AdvancedEvidence) { e.Rows["100/constraints"][0]["convalidated"] = false }},
		{"selectedSurvives", func(e *tableedit.AdvancedEvidence) {
			e.Rows["200/constraints"] = append(e.Rows["200/constraints"], before.Rows["200/constraints"][len(before.Rows["200/constraints"])-1])
		}},
		{"policy", func(e *tableedit.AdvancedEvidence) { e.Rows["100/policies"][0]["polpermissive"] = false }},
		{"force", func(e *tableedit.AdvancedEvidence) { e.Rows["100/class"][0]["relforcerowsecurity"] = false }},
		{"owner", func(e *tableedit.AdvancedEvidence) { e.Rows["200/class"][0]["relowner"] = "99" }},
		{"attribute", func(e *tableedit.AdvancedEvidence) { e.Rows["200/attributes"][0]["unknown_native"] = "changed" }},
		{"triggerHint", func(e *tableedit.AdvancedEvidence) { e.Rows["200/class"][0]["relhastriggers"] = false }},
		{"sequence", func(e *tableedit.AdvancedEvidence) {
			e.Rows["200/sequences"][0]["sequence"].(map[string]any)["seqcache"] = 19
		}},
		{"unknownCategory", func(e *tableedit.AdvancedEvidence) { e.Rows["global/unknown"] = nil }},
		{"unknownNilToEmpty", func(e *tableedit.AdvancedEvidence) { e.Rows["global/unknown_nil"] = []map[string]any{} }},
		{"unknownNilCategoryRenamed", func(e *tableedit.AdvancedEvidence) {
			delete(e.Rows, "global/unknown_nil")
			e.Rows["global/other_nil"] = nil
		}},
		{"typedFact", func(e *tableedit.AdvancedEvidence) { e.Facts["200"].Table.Columns.Items[0].Ordinal = sc.Known(10) }},
	} {
		t.Run(mutation.name, func(t *testing.T) {
			next := tableedit.CloneAdvancedEvidence(after)
			mutation.change(next)
			if pgAdvancedCopyRepairsPreserved(before, next, repairs) == nil {
				t.Fatal("an unrelated or incompletely removed native property escaped the union proof")
			}
		})
	}
	annotated := tableedit.CloneAdvancedEvidence(before)
	annotated.Rows["200/comments"] = append(annotated.Rows["200/comments"], map[string]any{"classoid": "2606", "objoid": repairs[0].ConstraintID, "objsubid": 0, "description": "must retain"})
	if _, _, err = pgAdvancedCopyRepairExpected(annotated, repairs); err == nil {
		t.Fatal("an unexposed selected-key annotation was silently lost")
	}
	if _, _, err = pgAdvancedCopyRepairExpected(before, append(repairs, repairs[0])); err == nil {
		t.Fatal("duplicate selected-root authority was accepted")
	}
}

func TestAdvancedCopySelectedRepairTriggerHint(t *testing.T) {
	fixture := func() (tableedit.Baseline, tableedit.Baseline, tableedit.Baseline, tableedit.Baseline) {
		a := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
		b := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
		a.AdvancedEvidence.Rows["100/triggers"] = []map[string]any{}
		b.AdvancedEvidence.Rows["200/triggers"] = []map[string]any{}
		a.AdvancedEvidence.Rows["100/class"][0]["relhastriggers"] = true
		b.AdvancedEvidence.Rows["200/class"][0]["relhastriggers"] = false
		x, y := a, b
		x.AdvancedEvidence = tableedit.CloneAdvancedEvidence(a.AdvancedEvidence)
		y.AdvancedEvidence = tableedit.CloneAdvancedEvidence(b.AdvancedEvidence)
		x.AdvancedEvidence.Rows["100/copyTriggerCoverage"] = []map[string]any{{"catalog": "pg_catalog.pg_trigger", "allRows": true, "count": float64(0)}}
		y.AdvancedEvidence.Rows["200/copyTriggerCoverage"] = []map[string]any{{"catalog": "pg_catalog.pg_trigger", "allRows": true, "count": float64(0)}}
		return a, b, x, y
	}
	orders := map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}
	a, b, x, y := fixture()
	original := tableedit.Fingerprint(a.AdvancedEvidence)
	if err := pgAdvancedCopyRepairPropertiesPreserved(a, b, x, y, orders, map[string]bool{"100": true}); err != nil || tableedit.Fingerprint(a.AdvancedEvidence) != original {
		t.Fatal("a replaced relation's complete empty trigger catalog did not prove only a stale true-to-false hint reset")
	}
	mutations := []struct {
		name     string
		change   func(*tableedit.Baseline, *tableedit.Baseline, *tableedit.Baseline, *tableedit.Baseline)
		replaced map[string]bool
	}{
		{"missingCoverage", func(a, b, x, y *tableedit.Baseline) { delete(x.AdvancedEvidence.Rows, "100/copyTriggerCoverage") }, map[string]bool{"100": true}},
		{"nullCatalog", func(a, b, x, y *tableedit.Baseline) { x.AdvancedEvidence.Rows["100/triggers"] = nil }, map[string]bool{"100": true}},
		{"partialCatalog", func(a, b, x, y *tableedit.Baseline) {
			x.AdvancedEvidence.Rows["100/copyTriggerCoverage"][0]["allRows"] = false
		}, map[string]bool{"100": true}},
		{"unknownCoverage", func(a, b, x, y *tableedit.Baseline) {
			x.AdvancedEvidence.Rows["100/copyTriggerCoverage"][0]["unknown"] = true
		}, map[string]bool{"100": true}},
		{"nativeInternalTrigger", func(a, b, x, y *tableedit.Baseline) {
			x.AdvancedEvidence.Rows["100/triggers"] = []map[string]any{{"tgisinternal": true}}
		}, map[string]bool{"100": true}},
		{"newTrigger", func(a, b, x, y *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/triggers"] = []map[string]any{{"tgisinternal": false}}
		}, map[string]bool{"100": true}},
		{"notReplaced", func(a, b, x, y *tableedit.Baseline) {}, nil},
		{"falseToTrue", func(a, b, x, y *tableedit.Baseline) {
			a.AdvancedEvidence.Rows["100/class"][0]["relhastriggers"] = false
			b.AdvancedEvidence.Rows["200/class"][0]["relhastriggers"] = true
		}, map[string]bool{"100": true}},
		{"unknownProperty", func(a, b, x, y *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/class"][0]["unknown_native"] = true }, map[string]bool{"100": true}},

		{"sameOIDClaimedReplacement", func(a, b, x, y *tableedit.Baseline) {
			a.AdvancedEvidence.Rows["120/class"][0]["relhastriggers"] = true
			b.AdvancedEvidence.Rows["120/class"][0]["relhastriggers"] = false
			for _, v := range []*tableedit.Baseline{a, b, x, y} {
				v.AdvancedEvidence.Rows["120/triggers"] = []map[string]any{}
			}
			for _, v := range []*tableedit.Baseline{x, y} {
				v.AdvancedEvidence.Rows["120/copyTriggerCoverage"] = []map[string]any{{"catalog": "pg_catalog.pg_trigger", "allRows": true, "count": float64(0)}}
			}
		}, map[string]bool{"100": true, "120": true}},
		{"retainedRelationHint", func(a, b, x, y *tableedit.Baseline) {
			a.AdvancedEvidence.Rows["120/class"][0]["relhastriggers"] = true
			b.AdvancedEvidence.Rows["120/class"][0]["relhastriggers"] = false
		}, map[string]bool{"100": true}},
	}
	for _, m := range mutations {
		t.Run(m.name, func(t *testing.T) {
			a, b, x, y := fixture()
			m.change(&a, &b, &x, &y)
			if pgAdvancedCopyRepairPropertiesPreserved(a, b, x, y, orders, m.replaced) == nil {
				t.Fatal("an unproved hint or native-property change was accepted")
			}
		})
	}
}

func pgCopyRepairProjection(b tableedit.Baseline, name string) tableedit.Baseline {
	b.Facts = tableedit.CloneAdvancedEvidence(&tableedit.AdvancedEvidence{Facts: map[string]*tableedit.Facts{b.Identity: b.Facts}}).Facts[b.Identity]
	keys := []tableedit.Key{}
	for _, k := range b.Keys {
		if k.Name != name {
			keys = append(keys, k)
		}
	}
	b.Keys = keys
	constraints := []sc.Constraint{}
	for _, c := range b.Facts.Table.Constraints.Items {
		if c.Ref.Name != name {
			constraints = append(constraints, c)
		}
	}
	b.Facts.Table.Constraints.Items = constraints
	b.Facts.Table.Dependencies = sc.DerivedDependencies(b.Facts.Table)
	return b
}

// The repair units use normal Store Preview/Apply. Only the new copy method is
// called directly here; the outer MigrationStore wiring is verified separately.
func TestAdvancedCopySelectedRepairPipelineLive(t *testing.T) {
	for _, mode := range []string{"MultipleSelected", "Unlogged", "Unselected", "MissingRemoval", "OwnerDrift", "LateOwnerDrift"} {
		t.Run(mode, func(t *testing.T) {
			f := newChangeFixture(t)
			ctx := context.Background()
			s := &Session{conn: f.conn}
			persistence := ""
			if mode == "Unlogged" {
				persistence = "UNLOGGED "
			}
			f.exec("CREATE " + persistence + "TABLE " + f.table("secured") + "(id integer PRIMARY KEY,payload text,n numeric(30,4),b bytea)")
			f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ROW LEVEL SECURITY")
			f.exec("ALTER TABLE " + f.table("secured") + " FORCE ROW LEVEL SECURITY")
			f.exec("CREATE POLICY retained ON " + f.table("secured") + " USING(id>0) WITH CHECK(id>0)")
			f.exec("INSERT INTO " + f.table("secured") + " VALUES(1,'',12345678901234567890.1234,decode('00ff','hex')),(2,'NULL',NULL,NULL),(3,NULL,-123.4000,decode('ff00','hex'))")
			target := tableedit.Target{Schema: f.schema, Table: "secured"}
			virtual := map[tableedit.Target]tableedit.Baseline{}
			for _, name := range []string{"owner_one", "owner_two"} {
				f.exec("CREATE " + persistence + "TABLE " + f.table(name) + "(ref integer,payload text,CONSTRAINT selected FOREIGN KEY(ref) REFERENCES " + f.table("secured") + "(id))")
				f.exec("INSERT INTO " + f.table(name) + " VALUES(1,''),(1,''),(NULL,'NULL'),(NULL,NULL)")
				owner := tableedit.Target{Schema: f.schema, Table: name}
				b, err := s.StructureLoad(ctx, owner)
				if err != nil {
					t.Fatal("selected repair owner capture unavailable")
				}
				virtual[owner] = pgCopyRepairProjection(b, "selected")
				if mode == "Unselected" && name == "owner_two" {
					virtual[owner] = b
				}
			}
			before, err := s.StructureLoad(ctx, target)
			if err != nil {
				t.Fatal("complete advanced copy source unavailable")
			}
			order := []string{"payload", "n", "b", "id"}
			if _, err = s.preparePGAdvancedCopy(ctx, before, order); err == nil {
				t.Fatal("ordinary copy entry accepted an unselected outside foreign key")
			}
			p, err := s.preparePGAdvancedCopyMigration(ctx, before, order, func(t tableedit.Target) (tableedit.Baseline, error) {
				return virtual[t], nil
			})
			if mode == "Unselected" {
				if err == nil {
					t.Fatal("an unselected incoming owner was accepted by migration Preview")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			var envelope pgAdvancedCopyEnvelope
			if json.Unmarshal([]byte(p.Reconstruction.ExpectedDefinition), &envelope) != nil || len(envelope.Repairs) != 2 || envelope.RepairEvidence == nil || envelope.Evidence == nil || len(envelope.Layout.NameSeed) != 64 || strings.Trim(envelope.Layout.NameSeed, "0123456789abcdef") != "" || len(envelope.RepairEvidence.Facts[before.Identity].Incoming) != 2 {
				t.Fatal("the original catalog/selected roots/name seed were not bound privately")
			}
			for _, sql := range p.SQL {
				if strings.Contains(sql, "DROP CONSTRAINT") || strings.Contains(sql, "CASCADE") {
					t.Fatal("copy Preview silently removed an outside dependency")
				}
			}
			for _, name := range []string{"owner_one", "owner_two"} {
				if mode == "MissingRemoval" && name == "owner_two" {
					continue
				}
				authoringApply(t, s, &tableedit.Store{}, tableedit.Target{Schema: f.schema, Table: name}, tableedit.Draft{AuthoringVersion: 2, AllowDestructive: true, Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{{Action: "drop", Kind: "foreign", Name: "selected"}}})
			}
			if mode == "OwnerDrift" {
				f.exec("COMMENT ON COLUMN " + f.table("owner_one") + ".payload IS 'changed retained owner property'")
			}
			fresh, err := s.StructureLoad(ctx, target)
			if err != nil {
				t.Fatal("actual post-repair source unavailable")
			}
			if mode != "MissingRemoval" && fresh.Fingerprint == before.Fingerprint {
				t.Fatal("the actual native FK removal did not change the observed fingerprint")
			}
			if mode == "MultipleSelected" {
				tx, e := f.conn.Begin(ctx)
				if e != nil {
					t.Fatal("repair metadata diagnostic unavailable")
				}
				if _, e = tx.Exec(ctx, "SET LOCAL search_path=pg_catalog"); e != nil {
					t.Fatal("repair metadata diagnostic context unavailable")
				}
				actual, e := pgAdvancedCopyRepairLoad(ctx, tx, target)
				if e == nil {
					actual, e = pgAdvancedCopyRepairCapture(ctx, tx, actual, envelope.Repairs)
				}
				if e == nil {
					e = pgAdvancedCopyRepairsPreserved(envelope.RepairEvidence, actual.AdvancedEvidence, envelope.Repairs)
				}
				if e != nil {
					t.Log("selected-repair diagnostic category:", e)
					expected, _, _ := pgAdvancedCopyRepairExpected(envelope.RepairEvidence, envelope.Repairs)
					paths := []string{}
					if actual.AdvancedEvidence != nil {
						for _, f := range actual.AdvancedEvidence.Facts {
							f.Incoming = append([]tableedit.Incoming{}, f.Incoming...)
							f.Table.Constraints.Items = append([]sc.Constraint{}, f.Table.Constraints.Items...)
						}
						pgCopyGraphDifferencePaths(reflect.ValueOf(expected.Facts), reflect.ValueOf(actual.AdvancedEvidence.Facts), "facts", &paths)
						t.Log("selected-repair diagnostic field paths:", paths)
					}
				}
				if tx.Rollback(ctx) != nil {
					t.Fatal("repair metadata diagnostic rollback unavailable")
				}
			}
			mutated := false
			var mutationError error
			if mode == "MultipleSelected" {
				s.afterStructureStep = func(i int) {
					if i == len(p.SQL)-2 {
						after, e := pgAdvancedCopyRepairLoad(ctx, f.conn, target)
						if e != nil {
							t.Fatal("native class diagnostic unavailable")
						}
						old := envelope.RepairEvidence.Rows[before.Identity+"/class"][0]
						next := after.AdvancedEvidence.Rows[after.Identity+"/class"][0]
						for key, value := range old {
							if key != "oid" && key != "reltype" && key != "reltoastrelid" && key != "relfilenode" && !reflect.DeepEqual(value, next[key]) {
								t.Log("selected-repair native class differs at", key)
							}
						}
					}
				}
			}
			if mode == "LateOwnerDrift" {
				s.afterStructureStep = func(i int) {
					if i == len(p.SQL)-2 {
						mutated = true
						_, mutationError = f.conn.Exec(ctx, "COMMENT ON COLUMN "+f.table("owner_one")+".payload IS 'changed retained owner property'")
					}
				}
			}
			plan := tableedit.Plan{ID: tableedit.Token(), Digest: tableedit.Fingerprint(p.SQL), Target: target, SQL: p.SQL, Reconstruction: p.Reconstruction, Created: time.Now()}
			s.advancedCopyCheckpoint = &pgAdvancedCopyCheckpoint{}
			steps := s.applyPGAdvancedCopy(ctx, fresh, plan)
			if mutationError != nil {
				t.Fatal("the intended retained-owner late mutation failed")
			}
			positive := mode == "MultipleSelected" || mode == "Unlogged"
			if mode == "LateOwnerDrift" && !mutated {
				t.Fatal("the intended retained-owner late mutation boundary was not reached")
			}
			for i, step := range steps {
				if positive && (step.State != "applied" || step.Message != "") {
					t.Fatalf("selected repair copy step %d state=%s message=%s", i, step.State, step.Message)
				}
				if !positive && step.State != "notStarted" && step.State != "rolledBack" {
					t.Fatal("an incomplete selected repair or unrelated owner drift escaped the copy guard")
				}
			}
			after, err := s.StructureLoad(ctx, target)
			if err != nil || positive == (after.Identity == before.Identity) {
				t.Fatal("copy outcome did not retain the correct actual source identity")
			}
			if !positive {
				if s.advancedCopyCheckpoint != nil {
					t.Fatal("a refused or rolled-back copy emitted an acknowledged checkpoint")
				}
				return
			}
			checkpoint, err := s.pgAdvancedCopyConsumeCheckpoint(plan)
			if err != nil || checkpoint == nil {
				t.Fatal("acknowledged selected-repair copy has no sealed checkpoint")
			}
			if _, err = s.pgAdvancedCopyConsumeCheckpoint(plan); err == nil {
				t.Fatal("an acknowledged checkpoint was consumed twice")
			}
			observed, combined, err := s.pgAdvancedCopyObserveCheckpoint(ctx, after, checkpoint)
			if err != nil {
				t.Fatal("acknowledged checkpoint could not be reobserved in its original fixed metadata context")
			}
			if err = pgAdvancedCopyCheckpointPreserved(checkpoint, observed, combined); err != nil {
				t.Fatal(err)
			}
			for _, name := range []string{"owner_one", "owner_two"} {
				key := tableedit.KeyEdit{Action: "add", Kind: "foreign", Name: "selected", Columns: []string{"ref"}, Reference: &target, ReferenceColumns: []string{"id"}, OnUpdate: "NO ACTION", OnDelete: "NO ACTION"}
				authoringApply(t, s, &tableedit.Store{}, tableedit.Target{Schema: f.schema, Table: name}, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{key}})
				var count int
				if f.observer.QueryRow(ctx, "SELECT count(*) FROM "+f.table(name)).Scan(&count) != nil || count != 4 {
					t.Fatal("a selected repair changed retained owner rows or duplicate multiplicity")
				}
			}
			restored, err := s.StructureLoad(ctx, target)
			if err != nil || len(restored.Facts.Incoming) != 2 || !reflect.DeepEqual(order, func() []string {
				out := []string{}
				for _, c := range restored.Columns {
					out = append(out, c.Name)
				}
				return out
			}()) {
				t.Fatal("the explicit repaired keys or reviewed physical order were not observed")
			}
		})
	}
}
