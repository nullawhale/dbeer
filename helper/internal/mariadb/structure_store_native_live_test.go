package mariadb

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestMariaDBNormalStructureStoreCreateAppendDefaultIndexLive(t *testing.T) {
	s := dataIntegrationSession(t)
	schema := dataIntegrationSettings(t).Database
	name := fmt.Sprintf("g1_store_%d", time.Now().UnixNano())
	q := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
	defer dataRun(t, s, "DROP TABLE IF EXISTS "+q)
	target := tableedit.Target{Schema: schema, Table: name, Create: true}
	var store tableedit.Store
	run := func(d tableedit.Draft) {
		t.Helper()
		loaded, e := store.Load(context.Background(), s, target)
		if e != nil || loaded.Baseline == nil {
			t.Fatalf("normal native structure load failed: %T", e)
		}
		preview, e := store.PreviewContext(context.Background(), s, loaded.Baseline.ID, d)
		if e != nil || preview.Plan == nil {
			t.Fatalf("normal native structure preview failed: %T", e)
		}
		for _, sql := range preview.Plan.SQL {
			if !strings.HasPrefix(sql, mariaDBDDLPrefix) {
				t.Fatal("native timeout scope was omitted from displayed SQL")
			}
		}
		p := preview.Plan
		applied, e := store.Apply(context.Background(), s, tableedit.Apply{ExecutionID: tableedit.Token(), PlanID: p.ID, Digest: p.Digest})
		if e != nil || applied.Outcome == nil || applied.Outcome.State != "applied" {
			t.Fatalf("normal native structure apply failed: %T", e)
		}
		for _, step := range applied.Outcome.Steps {
			if step.State != "applied" || step.Message != "" {
				t.Fatal("acknowledged native DDL did not prove the exact expected preservation")
			}
		}
		if _, e = store.Apply(context.Background(), s, tableedit.Apply{ExecutionID: tableedit.Token(), PlanID: p.ID, Digest: p.Digest}); e == nil {
			t.Fatal("native structure authority replayed")
		}
		target.Create = false
	}
	value := "NULL"
	run(tableedit.Draft{Columns: []tableedit.Column{{Name: "id", Type: tableedit.DataType{Kind: "integer"}, Default: tableedit.Default{Kind: "none"}}, {Name: "note", Type: tableedit.DataType{Kind: "varchar", Length: 30}, Nullable: true, Default: tableedit.Default{Kind: "text", Value: &value}}, {Name: "amount", Type: tableedit.DataType{Kind: "numeric", Precision: 65, Scale: 38}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}})
	dataRun(t, s, "INSERT INTO "+q+" VALUES(1,'',0.12345678901234567890123456789012345678),(2,'NULL',NULL),(3,NULL,-0.00000000000000000000000000000000000001)")
	run(tableedit.Draft{Columns: []tableedit.Column{{Name: "added", Type: tableedit.DataType{Kind: "varchar", Length: 30}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}})
	empty := ""
	run(tableedit.Draft{AuthoringVersion: 2, Changes: []tableedit.ColumnChange{{Name: "note", Default: &tableedit.Default{Kind: "text", Value: &empty}}}})
	run(tableedit.Draft{AuthoringVersion: 2, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "reviewed_idx", Columns: []string{"id"}}}})
	run(tableedit.Draft{AuthoringVersion: 2, AllowDestructive: true, Indexes: []tableedit.IndexEdit{{Action: "drop", Name: "reviewed_idx"}}})
	retained := dataRun(t, s, "SELECT id,note,CAST(amount AS CHAR),added FROM "+q+" ORDER BY id")
	if len(retained.Rows) != 3 || retained.Rows[0][1] == nil || *retained.Rows[0][1] != "" || retained.Rows[1][1] == nil || *retained.Rows[1][1] != "NULL" || retained.Rows[2][1] != nil || retained.Rows[0][2] == nil || *retained.Rows[0][2] != "0.12345678901234567890123456789012345678" || retained.Rows[2][2] == nil || *retained.Rows[2][2] != "-0.00000000000000000000000000000000000001" {
		t.Fatal("native metadata authoring changed retained exact values")
	}
	loaded, e := store.Load(context.Background(), s, target)
	if e != nil {
		t.Fatal("native late-context load failed")
	}
	preview, e := store.PreviewContext(context.Background(), s, loaded.Baseline.ID, tableedit.Draft{Columns: []tableedit.Column{{Name: "late", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}})
	if e != nil {
		t.Fatal("native late-context preview failed")
	}
	dataRun(t, s, "SET SESSION time_zone='+03:00'")
	outcome, e := store.Apply(context.Background(), s, tableedit.Apply{ExecutionID: tableedit.Token(), PlanID: preview.Plan.ID, Digest: preview.Plan.Digest})
	if e != nil || outcome.Outcome == nil || outcome.Outcome.State == "applied" {
		t.Fatal("late native context change retained DDL authority")
	}
}

func TestMariaDBNormalStructureStoreNativeKeysAndRichIndexesLive(t *testing.T) {
	settings := dataIntegrationSettings(t)
	if os.Getenv("DBEER_TEST_MARIADB_ADMIN_USER") == "" {
		t.Skip("native metadata admin fixture not enabled")
	}
	settings.User = os.Getenv("DBEER_TEST_MARIADB_ADMIN_USER")
	settings.Password = os.Getenv("DBEER_TEST_MARIADB_ADMIN_PASSWORD")
	opened, e := Open(context.Background(), settings)
	if e != nil {
		t.Fatal("cannot open native metadata-proof owner")
	}
	s := opened.(*Session)
	defer s.Close()
	prefix := fmt.Sprintf("g1_keys_%d", time.Now().UnixNano())
	parent, child := prefix+"p", prefix+"c"
	q := func(name string) string { return QuoteIdentifier(settings.Database) + "." + QuoteIdentifier(name) }
	dataRun(t, s, "CREATE TABLE "+q(parent)+"(id INT PRIMARY KEY) ENGINE=InnoDB")
	dataRun(t, s, "CREATE TABLE "+q(child)+"(id INT NOT NULL,pid INT,note VARCHAR(50) NOT NULL,g POINT NOT NULL) ENGINE=InnoDB")
	defer dataRun(t, s, "DROP TABLE IF EXISTS "+q(parent))
	defer dataRun(t, s, "DROP TABLE IF EXISTS "+q(child))
	dataRun(t, s, "INSERT INTO "+q(parent)+" VALUES(1),(2)")
	dataRun(t, s, "INSERT INTO "+q(child)+" VALUES(1,1,'first',ST_GeomFromText('POINT(1 2)')),(2,2,'second',ST_GeomFromText('POINT(3 4)'))")
	var store tableedit.Store
	target := tableedit.Target{Schema: settings.Database, Table: child}
	run := func(d tableedit.Draft) {
		t.Helper()
		loaded, e := store.Load(context.Background(), s, target)
		if e != nil || loaded.Baseline == nil || !loaded.Baseline.DependencyProof {
			t.Fatalf("native complete metadata proof missing: %T", e)
		}
		p, e := store.PreviewContext(context.Background(), s, loaded.Baseline.ID, d)
		if e != nil || p.Plan == nil {
			t.Fatalf("native key/index preview failed: %T", e)
		}
		beforeSteps := map[int]tableedit.Baseline{0: *loaded.Baseline}
		s.afterStructureStep = func(i int) {
			if i+1 < len(p.Plan.SQL) {
				b, err := s.StructureLoad(context.Background(), target)
				if err == nil {
					beforeSteps[i+1] = b
				}
			}
		}
		defer func() { s.afterStructureStep = nil }()
		result, e := store.Apply(context.Background(), s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
		if e != nil || result.Outcome == nil || result.Outcome.State != "applied" {
			if result.Outcome != nil {
				for i, step := range result.Outcome.Steps {
					t.Logf("native unit %d state=%s reason=%s", i, step.State, step.Message)
				}
			}
			state := "missing"
			if result.Outcome != nil {
				state = result.Outcome.State
			}
			t.Fatalf("native key/index apply failed state=%s error=%T", state, e)
		}
		for i, step := range result.Outcome.Steps {
			if step.Message != "" {
				actual, err := s.StructureLoad(context.Background(), target)
				if err == nil {
					before := beforeSteps[i]
					condition := p.Plan.Conditions[i]
					normalized, ok := mariaDBExpectedForeignNames(before, actual, before, condition)
					t.Logf("FK diagnostic names=%t scope=%t guard=%t context=%t", ok, before.Scope == actual.Scope, before.Guard == actual.Guard, reflect.DeepEqual(before.Facts.EngineContext, normalized.Facts.EngineContext))
					if condition.Operation.Key != nil {
						k := condition.Operation.Key
						for _, observed := range actual.Keys {
							if observed.Name == k.Name {
								t.Logf("selected key supported=%t columns=%t reference=%t delete=%t update=%t", observed.Supported, reflect.DeepEqual(observed.Columns, k.Columns), reflect.DeepEqual(observed.Reference, k.Reference), observed.OnDelete == k.OnDelete, observed.OnUpdate == k.OnUpdate)
							}
						}
						left, right := mariaDBTestStripKey(before, k.Name), mariaDBTestStripKey(normalized, k.Name)
						for _, path := range mariaDBTestDifferencePaths(reflect.ValueOf(left), reflect.ValueOf(right), "facts") {
							t.Log("difference path", path)
						}
					}
				}
				t.Fatalf("native key/index preservation refused: %s", step.Message)
			}
		}
	}
	run(tableedit.Draft{AuthoringVersion: 2, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "primary", Name: "PRIMARY", Columns: []string{"id"}}}})
	run(tableedit.Draft{AuthoringVersion: 2, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "foreign", Name: "owned_fk", Columns: []string{"pid"}, Reference: &tableedit.Target{Schema: settings.Database, Table: parent}, ReferenceColumns: []string{"id"}, OnDelete: "RESTRICT", OnUpdate: "CASCADE"}}})
	note := "note"
	prefixLength := int64(5)
	desc, ignored := true, false
	run(tableedit.Draft{AuthoringVersion: 3, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "ignored_prefix", Definition: &tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: &note, PrefixLength: &prefixLength, Descending: &desc}}, Visible: &ignored, Options: []tableedit.IndexOption{{Name: "comment", Value: "exact native comment"}}}}}})
	run(tableedit.Draft{AuthoringVersion: 3, AllowDestructive: true, Indexes: []tableedit.IndexEdit{{Action: "drop", Name: "ignored_prefix"}}})
	run(tableedit.Draft{AuthoringVersion: 2, AllowDestructive: true, Keys: []tableedit.KeyEdit{{Action: "drop", Kind: "foreign", Name: "owned_fk"}}})
	rows := dataRun(t, s, "SELECT id,pid,note,HEX(g) FROM "+q(child)+" ORDER BY id")
	if len(rows.Rows) != 2 || *rows.Rows[0][0] != "1" || *rows.Rows[0][1] != "1" || *rows.Rows[0][2] != "first" || *rows.Rows[1][0] != "2" || *rows.Rows[1][2] != "second" || rows.Rows[0][3] == nil || *rows.Rows[0][3] == "" {
		t.Fatal("native key/index authoring changed retained rows")
	}
}

func mariaDBTestStripKey(b tableedit.Baseline, name string) *tableedit.Facts {
	raw, _ := json.Marshal(b.Facts)
	var f tableedit.Facts
	_ = json.Unmarshal(raw, &f)
	keys := []sc.Constraint{}
	for _, k := range f.Table.Constraints.Items {
		if k.Ref.Name != name {
			keys = append(keys, k)
		}
	}
	f.Table.Constraints.Items = keys
	f.Table.Dependencies = sc.DerivedDependencies(f.Table)
	return &f
}
func mariaDBTestDifferencePaths(a, b reflect.Value, path string) []string {
	if !a.IsValid() || !b.IsValid() {
		if a.IsValid() != b.IsValid() {
			return []string{path}
		}
		return nil
	}
	if a.Type() != b.Type() {
		return []string{path}
	}
	if a.CanInterface() && b.CanInterface() && reflect.DeepEqual(a.Interface(), b.Interface()) {
		return nil
	}
	switch a.Kind() {
	case reflect.Pointer:
		if a.IsNil() || b.IsNil() {
			return []string{path}
		}
		return mariaDBTestDifferencePaths(a.Elem(), b.Elem(), path)
	case reflect.Struct:
		out := []string{}
		for i := 0; i < a.NumField(); i++ {
			out = append(out, mariaDBTestDifferencePaths(a.Field(i), b.Field(i), path+"."+a.Type().Field(i).Name)...)
		}
		return out
	case reflect.Slice:
		if a.Len() != b.Len() {
			return []string{path + ".length"}
		}
		out := []string{}
		for i := 0; i < a.Len(); i++ {
			out = append(out, mariaDBTestDifferencePaths(a.Index(i), b.Index(i), fmt.Sprintf("%s[%d]", path, i))...)
		}
		if len(out) == 0 {
			return []string{path + ".nilPresence"}
		}
		return out
	case reflect.Map:
		return []string{path}
	default:
		return []string{path}
	}
}
