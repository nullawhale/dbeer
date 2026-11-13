package mysql

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"errors"
	"fmt"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"os"
	"testing"
	"time"
)

func TestStructureAdvancedIndexesCreateReadReplaceAndDropLive(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s := integrationSession(t)
	ctx := context.Background()
	store := &tableedit.Store{}
	schema := integrationSettings(t).Database
	name := fmt.Sprintf("advanced_indexes_%d", time.Now().UnixNano())
	table := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
	target := tableedit.Target{Schema: schema, Table: name}
	defer run(t, s, "DROP TABLE IF EXISTS "+table)
	run(t, s, "CREATE TABLE "+table+"(id INT PRIMARY KEY,base INT,word VARCHAR(40) NOT NULL,body TEXT,location POINT NOT NULL SRID 4326)")
	run(t, s, "INSERT INTO "+table+" VALUES(1,10,'Alpha','full text fixture',ST_SRID(POINT(1,2),4326))")
	str := func(v string) *string { return &v }
	flag := func(v bool) *bool { return &v }
	prefix := int64(8)
	definitions := []struct {
		name       string
		definition tableedit.IndexDefinition
	}{
		{"prefix", tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: str("word"), PrefixLength: &prefix, Descending: flag(true)}, {Column: str("base")}}, Options: []tableedit.IndexOption{{Name: "comment", Value: "Exact é"}}}},
		{"functional", tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Expression: str("base * 2")}}, Visible: flag(false)}},
		{"fulltext", tableedit.IndexDefinition{Method: "fulltext", Terms: []tableedit.IndexTerm{{Column: str("body")}}}},
		{"spatial", tableedit.IndexDefinition{Method: "spatial", Terms: []tableedit.IndexTerm{{Column: str("location")}}}},
	}
	apply := func(action, name string, definition *tableedit.IndexDefinition) {
		t.Helper()
		b, err := store.Load(ctx, s, target)
		if err != nil {
			t.Fatal("index baseline unavailable")
		}
		d := tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, AllowDestructive: action != "add", Indexes: []tableedit.IndexEdit{{Action: action, Name: name, Definition: definition}}}
		p, err := store.PreviewContext(ctx, s, b.Baseline.ID, d)
		if err != nil {
			t.Fatalf("index Preview rejected: %v", err)
		}
		if !p.Plan.Destructive {
			t.Fatal("advanced build lost its exact effect confirmation")
		}
		out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
		if err != nil || out.Outcome.State != "applied" || out.Outcome.Observed == nil {
			t.Fatal("advanced index execution failed")
		}
		for _, step := range out.Outcome.Steps {
			if step.Message != "" {
				t.Fatalf("index preservation stopped: %s", step.Message)
			}
		}
		if action != "drop" {
			found := false
			for _, index := range out.Outcome.Observed.Indexes {
				if index.Name == name {
					found = index.Definition != nil && index.Supported && index.Owner == ""
				}
			}
			if !found {
				t.Fatal("index definition was not completely read back")
			}
		}
	}
	for _, definition := range definitions {
		t.Run(definition.name, func(t *testing.T) { apply("add", "advanced_"+definition.name, &definition.definition) })
	}
	capture := func() sc.Capture {
		opened, err := Open(ctx, integrationSettings(t))
		if err != nil {
			t.Fatal("comparison session unavailable")
		}
		defer opened.Close()
		reader := opened.(*Session)
		if err := reader.SetReadOnly(ctx, true); err != nil {
			t.Fatal("readonly comparison setup unavailable")
		}
		c := sc.NewCollector(ctx, sc.DefaultLimits())
		if err := reader.ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{schema}, Limits: sc.DefaultLimits()}, c); err != nil {
			t.Fatal("index comparison capture unavailable")
		}
		if len(c.Capture.Tables) != 1 || c.Capture.Tables[0].Ref.Name != name {
			var codes []string
			for _, issue := range c.Capture.Issues {
				codes = append(codes, issue.Code)
			}
			t.Fatalf("owned comparison table was not captured: tables=%d inventories=%d visibility=%s issues=%v", len(c.Capture.Tables), len(c.Capture.Inventories), c.Capture.Context.Visibility, codes)
		}
		return c.Capture
	}
	mapping := sc.Mappings{Schemas: []sc.NamePair{{Source: schema, Target: schema}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}
	withExpression := capture()
	dependencyUnknown := false
	for _, index := range withExpression.Tables[0].Indexes.Items {
		if index.Ref.Name == "advanced_functional" && len(index.Keys.Items) == 1 {
			expression := index.Keys.Items[0].Expression.Value
			dependencyUnknown = expression != nil && !expression.Dependencies.Complete && expression.Dependencies.Code == "expressionDependencies"
		}
	}
	uncertain, err := sc.Build(ctx, t.TempDir(), withExpression, capture(), mapping)
	if err != nil {
		t.Fatal("functional index comparison unavailable")
	}
	defer uncertain.Close()
	manual := false
	for _, issue := range uncertain.Report.Issues {
		manual = manual || issue.BlocksEquality && issue.Planning == "manual"
	}
	if !dependencyUnknown || uncertain.Report.Summary.FullEquality || uncertain.Report.Summary.Complete || uncertain.Report.Summary.IndeterminateObjects == 0 || !manual {
		t.Fatal("incomplete functional-index dependencies lost their manual comparison boundary")
	}
	apply("drop", "advanced_functional", nil)
	before := capture()
	equal, err := sc.Build(ctx, t.TempDir(), before, capture(), mapping)
	if err != nil {
		t.Fatal("index equality report unavailable")
	}
	defer equal.Close()
	if !equal.Report.Summary.FullEquality {
		t.Fatalf("identical fully represented indexes did not compare equal: complete=%t differences=%d indeterminate=%d issues=%d", equal.Report.Summary.Complete, equal.Report.Summary.DifferenceCount, equal.Report.Summary.IndeterminateObjects, equal.Report.Summary.IssueCount)
	}
	changed := definitions[0].definition
	changed.Options = []tableedit.IndexOption{{Name: "comment", Value: "Replaced"}}
	changed.Terms[0].Descending = flag(false)
	apply("replace", "advanced_prefix", &changed)
	different, err := sc.Build(ctx, t.TempDir(), before, capture(), mapping)
	if err != nil {
		t.Fatal("changed index comparison unavailable")
	}
	defer different.Close()
	if different.Report.Summary.FullEquality || different.Report.Summary.DifferenceCount == 0 {
		t.Fatal("index option/order replacement was absent from comparison")
	}

	values, err := s.work.client.Execute("SELECT count(*) FROM " + table + " WHERE id=1 AND base=10 AND word='Alpha'")
	if err != nil {
		t.Fatal("cannot verify retained values")
	}
	count, _ := values.GetInt(0, 0)
	values.Close()
	if count != 1 {
		t.Fatal("index editing changed existing values")
	}
}

func TestStructureIndexModesAndUnsupportedHashLive(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	for _, mode := range []string{"", "ANSI_QUOTES,NO_BACKSLASH_ESCAPES"} {
		t.Run(mode, func(t *testing.T) {
			s := integrationSession(t)
			ctx := context.Background()
			store := &tableedit.Store{}
			schema := integrationSettings(t).Database
			name := fmt.Sprintf("index_modes_%d", time.Now().UnixNano())
			table := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
			target := tableedit.Target{Schema: schema, Table: name}
			defer run(t, s, "DROP TABLE IF EXISTS "+table)
			run(t, s, "SET SESSION sql_mode='"+mode+"'")
			run(t, s, "CREATE TABLE "+table+"(id INT PRIMARY KEY,base INT,word VARCHAR(40))")
			run(t, s, "INSERT INTO "+table+" VALUES(1,10,'Alpha')")
			column := "base"
			hash := tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "unretained_hash", Definition: &tableedit.IndexDefinition{Method: "hash", Terms: []tableedit.IndexTerm{{Column: &column}}}}}}
			b, err := store.Load(ctx, s, target)
			if err != nil {
				t.Fatal("mode baseline unavailable")
			}
			if _, err := store.PreviewContext(ctx, s, b.Baseline.ID, hash); err == nil {
				t.Fatal("InnoDB HASH normalization was silently accepted")
			}
			result, err := s.work.client.Execute("CREATE INDEX `raw_hash` USING HASH ON " + table + " (`base`)")
			if err != nil {
				t.Fatal("owned HASH positive control failed")
			}
			result.Close()
			result, err = s.work.client.Execute("SELECT INDEX_TYPE FROM information_schema.STATISTICS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? AND INDEX_NAME='raw_hash'", schema, name)
			if err != nil {
				t.Fatal("HASH positive control metadata unavailable")
			}
			actual, _ := result.GetString(0, 0)
			result.Close()
			if actual != "BTREE" {
				t.Fatal("actual InnoDB HASH normalization was not reproduced")
			}
			expression := "concat(word,'_safe')"
			d := tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "literal_functional", Definition: &tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Expression: &expression}}, Options: []tableedit.IndexOption{{Name: "comment", Value: "Owner's exact comment"}}}}}}
			b, err = store.Load(ctx, s, target)
			if err != nil {
				t.Fatal("literal baseline unavailable")
			}
			p, err := store.PreviewContext(ctx, s, b.Baseline.ID, d)
			if err != nil {
				t.Fatal("literal index Preview unavailable")
			}
			out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
			if err != nil || out.Outcome.State != "applied" {
				t.Fatal("literal functional index failed")
			}
			for _, step := range out.Outcome.Steps {
				if step.Message != "" {
					t.Fatalf("literal mode preservation stopped: %s", step.Message)
				}
			}
		})
	}
}

func TestStructureUnmodeledIndexAttributesBlockReplacementAndPreserveAdditiveLive(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s := integrationSession(t)
	ctx := context.Background()
	store := &tableedit.Store{}
	schema := integrationSettings(t).Database
	name := fmt.Sprintf("index_attributes_%d", time.Now().UnixNano())
	table := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
	target := tableedit.Target{Schema: schema, Table: name}
	defer run(t, s, "DROP TABLE IF EXISTS "+table)
	run(t, s, "CREATE TABLE "+table+"(id INT PRIMARY KEY,base INT,body TEXT,FULLTEXT KEY parsed_idx(body) WITH PARSER ngram)")
	engineExists := false
	result, engineErr := s.work.client.Execute("CREATE INDEX engine_idx ON " + table + "(base) ENGINE_ATTRIBUTE='{\"kept\":1}' SECONDARY_ENGINE_ATTRIBUTE='{\"kept\":2}'")
	if engineErr != nil {
		var server *wire.MyError
		if !errors.As(engineErr, &server) {
			t.Fatal("engine attribute probe had a transport failure")
		}
		if server.Code != 3981 || server.State != "HY000" {
			t.Fatal("engine attribute probe failed for a reason other than ER_ENGINE_ATTRIBUTE_NOT_SUPPORTED")
		}
		// MySQL 8.4 InnoDB rejects this reserved engine option (3981/HY000).
		absent, err := s.work.client.Execute("SELECT count(*) FROM information_schema.STATISTICS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? AND INDEX_NAME='engine_idx'", schema, name)
		if err != nil {
			t.Fatal("cannot confirm rejected engine attribute left no index")
		}
		count, _ := absent.GetInt(0, 0)
		absent.Close()
		if count != 0 {
			t.Fatal("rejected engine attribute created an index unexpectedly")
		}
	} else {
		engineExists = true
		result.Close()
	}

	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal("parser attribute baseline unavailable")
	}
	if b.Baseline.Facts.IndexAttributes["parsed_idx"]["reason"] != "FULLTEXT parser" {
		t.Fatal("FULLTEXT parser raw evidence was not retained")
	}
	if engineExists && b.Baseline.Facts.IndexAttributes["engine_idx"]["reason"] != "index engine attributes" {
		t.Fatal("engine attribute raw evidence was not retained")
	}
	for _, index := range b.Baseline.Indexes {
		if (index.Name == "parsed_idx" || index.Name == "engine_idx") && (index.Supported || index.Definition != nil) {
			t.Fatal("partial parser metadata was offered as fully editable")
		}
	}
	column := "body"
	definition := tableedit.IndexDefinition{Method: "fulltext", Terms: []tableedit.IndexTerm{{Column: &column}}}
	if _, err := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, AllowDestructive: true, Indexes: []tableedit.IndexEdit{{Action: "replace", Name: "parsed_idx", Definition: &definition}}}); err == nil {
		t.Fatal("replacement could silently lose its parser")
	}
	column = "base"
	engineDefinition := tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: &column}}}
	if engineExists {
		if _, err := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, AllowDestructive: true, Indexes: []tableedit.IndexEdit{{Action: "replace", Name: "engine_idx", Definition: &engineDefinition}}}); err == nil {
			t.Fatal("replacement could silently lose its engine attributes")
		}
	}
	definition = tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: &column}}}
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "safe_new_idx", Definition: &definition}}})
	if err != nil {
		t.Fatal("additive index Preview unavailable")
	}
	out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
	if err != nil || out.Outcome.State != "applied" || out.Outcome.Steps[0].Message != "" {
		t.Fatal("additive index creation failed to preserve parser evidence")
	}
	names := []string{"parsed_idx"}
	if engineExists {
		names = append(names, "engine_idx")
	}
	for _, name := range names {
		if out.Outcome.Observed.Facts.IndexAttributes[name]["definition"] != b.Baseline.Facts.IndexAttributes[name]["definition"] {
			t.Fatal("untouched index attribute definition changed")
		}
	}
}
