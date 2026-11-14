package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"os"
	"strings"
	"testing"
)

func TestStructureAdvancedIndexRenderingPreservesSlots(t *testing.T) {
	expression, predicate, column := "lower(value)", "id > 0", "id"
	descending, first, distinct := true, false, false
	d := tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Expression: &expression, Descending: &descending, NullsFirst: &first, Collation: &tableedit.TypeReference{Schema: "pg_catalog", Name: "C"}, Opclass: &tableedit.TypeReference{Schema: "pg_catalog", Name: "text_pattern_ops"}}, {Column: &column}}, Includes: []string{"payload"}, Predicate: &predicate, NullsDistinct: &distinct, Options: []tableedit.IndexOption{{Name: "fillfactor", Value: "80"}}}
	sql, err := renderPGIndex(context.Background(), tableedit.Target{Schema: "public", Table: "items"}, tableedit.IndexEdit{Name: "advanced_idx", Unique: true, Definition: &d})
	if err != nil || !strings.Contains(sql, `(lower(value)) COLLATE "pg_catalog"."C" "pg_catalog"."text_pattern_ops" DESC NULLS LAST`) || !strings.Contains(sql, `INCLUDE ("payload") NULLS NOT DISTINCT WITH ("fillfactor" = E'80') WHERE id > 0;`) {
		t.Fatal("structured index rendering lost selected options")
	}
	for _, expression := range []string{"value); DROP TABLE items;--", "value, other", "value /* comment */"} {
		d.Terms[0].Expression = &expression
		if validatePGIndexDefinition(tableedit.Baseline{}, false, d) == nil {
			t.Fatal("expression escaped its authored slot")
		}
	}
}
func TestStructureAdvancedIndexesCreateReadReplaceAndDropLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: f.schema, Table: "advanced_indexes"}
	f.exec("CREATE TABLE " + f.table(target.Table) + "(id int PRIMARY KEY, base int, value text, payload text, location point, document jsonb)")
	f.exec("INSERT INTO " + f.table(target.Table) + " VALUES (1,10,'Alpha','kept',point(1,2),'{\"a\":1}')")
	str := func(v string) *string { return &v }
	flag := func(v bool) *bool { return &v }
	definitions := []tableedit.IndexDefinition{
		{Method: "btree", Terms: []tableedit.IndexTerm{{Expression: str("lower(value)"), Descending: flag(true), NullsFirst: flag(false), Collation: &tableedit.TypeReference{Schema: "pg_catalog", Name: "C"}, Opclass: &tableedit.TypeReference{Schema: "pg_catalog", Name: "text_pattern_ops"}}, {Column: str("base"), Descending: flag(true)}}, Includes: []string{"payload"}, Predicate: str("base > 0"), Options: []tableedit.IndexOption{{Name: "fillfactor", Value: "80"}}},
		{Method: "hash", Terms: []tableedit.IndexTerm{{Column: str("base")}}, Options: []tableedit.IndexOption{{Name: "fillfactor", Value: "70"}}},
		{Method: "gist", Terms: []tableedit.IndexTerm{{Column: str("location")}}, Includes: []string{"payload"}, Options: []tableedit.IndexOption{{Name: "fillfactor", Value: "80"}}},
		{Method: "spgist", Terms: []tableedit.IndexTerm{{Column: str("location")}}, Includes: []string{"payload"}},
		{Method: "gin", Terms: []tableedit.IndexTerm{{Column: str("document")}}, Options: []tableedit.IndexOption{{Name: "fastupdate", Value: "off"}}},
		{Method: "brin", Terms: []tableedit.IndexTerm{{Column: str("base")}}, Options: []tableedit.IndexOption{{Name: "pages_per_range", Value: "16"}, {Name: "autosummarize", Value: "on"}}},
	}
	for _, definition := range definitions {
		t.Run(definition.Method, func(t *testing.T) {
			out := authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "advanced_" + definition.Method, Definition: &definition}}})
			found := false
			for _, index := range out.Observed.Indexes {
				if index.Name == "advanced_"+definition.Method {
					found = index.Definition != nil && index.Supported && index.Owner == ""
				}
			}
			if !found {
				t.Fatal("new index has no complete editable structured definition")
			}
		})
	}
	capture := func() sc.Capture {
		c := sc.NewCollector(context.Background(), sc.DefaultLimits())
		reader := &Session{conn: f.observer}
		if err := reader.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{f.schema}, Limits: sc.DefaultLimits()}, c); err != nil {
			t.Fatal("index comparison capture unavailable")
		}
		return c.Capture
	}
	before := capture()
	mapping := sc.Mappings{Schemas: []sc.NamePair{{Source: f.schema, Target: f.schema}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}
	equal, err := sc.Build(context.Background(), t.TempDir(), before, capture(), mapping)
	if err != nil {
		t.Fatal("index equality report unavailable")
	}
	defer equal.Close()
	if !equal.Report.Summary.FullEquality {
		t.Fatal("identical fully represented index definitions did not compare equal")
	}
	changed := definitions[0]
	changed.Options = []tableedit.IndexOption{{Name: "fillfactor", Value: "70"}}
	changed.Predicate = str("base >= 0")
	authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, AllowDestructive: true, Indexes: []tableedit.IndexEdit{{Action: "replace", Name: "advanced_btree", Definition: &changed}}})
	different, err := sc.Build(context.Background(), t.TempDir(), before, capture(), mapping)
	if err != nil {
		t.Fatal("changed index comparison unavailable")
	}
	defer different.Close()
	if different.Report.Summary.FullEquality || different.Report.Summary.DifferenceCount == 0 {
		t.Fatal("index predicate/storage replacement was absent from comparison")
	}

	authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, AllowDestructive: true, Indexes: []tableedit.IndexEdit{{Action: "drop", Name: "advanced_hash"}}})
	var count int
	if f.observer.QueryRow(context.Background(), "SELECT count(*) FROM "+f.table(target.Table)+" WHERE id=1 AND base=10 AND value='Alpha' AND payload='kept'").Scan(&count) != nil || count != 1 {
		t.Fatal("index editing changed existing values")
	}
}

func TestStructureIndexPreviewNeverRunsAuthoredFunctionLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: f.schema, Table: "index_preview_counter"}
	f.exec("CREATE TABLE " + f.table(target.Table) + "(base int)")
	f.exec("INSERT INTO " + f.table(target.Table) + " VALUES(1),(2)")
	f.exec("CREATE SEQUENCE " + f.table("index_counter"))
	f.exec("CREATE FUNCTION " + f.table("index_tick") + "(integer) RETURNS integer LANGUAGE plpgsql IMMUTABLE AS $$BEGIN PERFORM nextval('" + f.table("index_counter") + "'); RETURN $1; END$$")
	expression := f.schema + ".index_tick(base)"
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal("index counter baseline unavailable")
	}
	d := tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "counter_idx", Definition: &tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Expression: &expression}}}}}}
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, d)
	if err != nil || !p.Plan.Destructive {
		t.Fatal("index counter Preview failed")
	}
	var called bool
	var last int64
	if f.observer.QueryRow(ctx, "SELECT last_value,is_called FROM "+f.table("index_counter")).Scan(&last, &called) != nil || called {
		t.Fatal("Preview evaluated the authored index function")
	}
	out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
	if err != nil || out.Outcome.State != "applied" {
		t.Fatal("confirmed index build failed")
	}
	for _, step := range out.Outcome.Steps {
		if step.Message != "" {
			t.Fatalf("index counter preservation: %s", step.Message)
		}
	}
	if f.observer.QueryRow(ctx, "SELECT last_value,is_called FROM "+f.table("index_counter")).Scan(&last, &called) != nil || !called || last != 2 {
		t.Fatal("authored function ran outside the two-row index build")
	}
}

func TestStructureIndexCustomOpclassDriftRejectsBeforeDDLLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: f.schema, Table: "class_drift"}
	f.exec("CREATE TABLE " + f.table(target.Table) + "(base int)")
	f.exec("CREATE FUNCTION " + f.table("index_compare") + "(integer,integer) RETURNS integer LANGUAGE sql IMMUTABLE STRICT AS 'SELECT CASE WHEN $1<$2 THEN -1 WHEN $1>$2 THEN 1 ELSE 0 END'")
	f.exec("CREATE OPERATOR CLASS " + f.table("index_int_ops") + " FOR TYPE integer USING btree AS OPERATOR 1 <(integer,integer), OPERATOR 2 <=(integer,integer), OPERATOR 3 =(integer,integer), OPERATOR 4 >=(integer,integer), OPERATOR 5 >(integer,integer), FUNCTION 1 " + f.table("index_compare") + "(integer,integer)")
	column := "base"
	d := tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "class_idx", Definition: &tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: &column, Opclass: &tableedit.TypeReference{Schema: f.schema, Name: "index_int_ops"}}}}}}}
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal("class baseline unavailable")
	}
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, d)
	if err != nil {
		t.Fatal("class Preview unavailable")
	}
	f.exec("CREATE OR REPLACE FUNCTION " + f.table("index_compare") + "(integer,integer) RETURNS integer LANGUAGE sql IMMUTABLE STRICT AS 'SELECT CASE WHEN $1<$2 THEN 1 WHEN $1>$2 THEN -1 ELSE 0 END'")
	out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
	if err != nil || out.Outcome.State != "failed" || len(out.Outcome.Steps) != 1 || out.Outcome.Steps[0].State != "notStarted" {
		t.Fatal("changed custom opclass was dispatched")
	}
	var absent bool
	if f.observer.QueryRow(ctx, "SELECT to_regclass($1) IS NULL", f.table("class_idx")).Scan(&absent) != nil || !absent {
		t.Fatal("class drift changed physical schema")
	}
}

func TestStructureUnsafeIndexDeparsersRetainRawProofLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: f.schema, Table: "unsafe_index"}
	f.exec("CREATE TYPE " + f.table("index_opaque"))
	f.exec("CREATE FUNCTION " + f.table("index_opaque_in") + "(cstring) RETURNS " + f.table("index_opaque") + " AS 'int4in' LANGUAGE internal IMMUTABLE STRICT")
	f.exec("CREATE FUNCTION " + f.table("index_opaque_out") + "(" + f.table("index_opaque") + ") RETURNS cstring AS 'int4out' LANGUAGE internal IMMUTABLE STRICT")
	f.exec("CREATE TYPE " + f.table("index_opaque") + "(INPUT=" + f.table("index_opaque_in") + ",OUTPUT=" + f.table("index_opaque_out") + ",INTERNALLENGTH=4,ALIGNMENT=int4,PASSEDBYVALUE)")
	f.exec("CREATE FUNCTION " + f.table("index_opaque_eq") + "(" + f.table("index_opaque") + "," + f.table("index_opaque") + ") RETURNS boolean AS 'int4eq' LANGUAGE internal IMMUTABLE STRICT")
	f.exec("CREATE OPERATOR " + f.schema + ".= (LEFTARG=" + f.table("index_opaque") + ",RIGHTARG=" + f.table("index_opaque") + ",FUNCTION=" + f.table("index_opaque_eq") + ")")
	f.exec("CREATE TABLE " + f.table(target.Table) + "(base int,probe " + f.table("index_opaque") + ")")
	f.exec("CREATE INDEX " + `"opaque_idx"` + " ON " + f.table(target.Table) + " ((probe OPERATOR(" + f.schema + ".=) '7'::" + f.table("index_opaque") + "))")
	// The owned catalog mutation makes any output-function entry fail, including
	// cstring interpreter rejection; direct deparse below is the positive control.
	f.exec("UPDATE pg_catalog.pg_proc SET prolang=(SELECT oid FROM pg_catalog.pg_language WHERE lanname='plpgsql'),prosrc='BEGIN RAISE EXCEPTION ''owned index output support executed''; END' WHERE pronamespace='" + f.schema + "'::regnamespace AND proname='index_opaque_out'")
	b, err := store.Load(ctx, s, target)
	if err != nil || len(b.Baseline.Facts.RawExpressions) == 0 {
		t.Fatal("unsafe index load invoked support code or lost raw proof")
	}
	for _, index := range b.Baseline.Indexes {
		if index.Name == "opaque_idx" && (index.Supported || index.Definition != nil) {
			t.Fatal("unsafe index was presented as complete executable authoring")
		}
	}
	column := "base"
	d := tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "safe_idx", Definition: &tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: &column}}}}}}
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, d)
	if err != nil {
		t.Fatal("safe index Preview evaluated opaque metadata")
	}
	out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
	if err != nil || out.Outcome.State != "applied" || out.Outcome.Steps[0].Message != "" {
		t.Fatal("safe index build failed to preserve unavailable raw metadata")
	}
	var text string
	if f.observer.QueryRow(ctx, "SELECT pg_catalog.pg_get_indexdef($1::regclass,1,false)", f.table("opaque_idx")).Scan(&text) == nil {
		t.Fatal("unsafe index deparser positive control did not enter custom support")
	}
}

func TestStructureIndexOpclassParametersAndNullsVersionLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: f.schema, Table: "index_options"}
	f.exec("CREATE TABLE " + f.table(target.Table) + "(base int)")
	f.exec("INSERT INTO " + f.table(target.Table) + " VALUES(1),(NULL)")
	column := "base"
	definition := tableedit.IndexDefinition{Method: "brin", Terms: []tableedit.IndexTerm{{Column: &column, Opclass: &tableedit.TypeReference{Schema: "pg_catalog", Name: "int4_minmax_multi_ops"}, Options: []tableedit.IndexOption{{Name: "values_per_range", Value: "32"}}}}, Options: []tableedit.IndexOption{{Name: "pages_per_range", Value: "16"}}}
	authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "parameter_idx", Definition: &definition}}})
	distinct := false
	definition = tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: &column}}, NullsDistinct: &distinct}
	d := tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "null_semantics_idx", Unique: true, Definition: &definition}}}
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal("NULL semantics baseline unavailable")
	}
	if b.Baseline.Facts.ServerVersion < 150000 {
		if _, err = store.PreviewContext(ctx, s, b.Baseline.ID, d); err == nil {
			t.Fatal("pre15 NULLS NOT DISTINCT was admitted")
		}
		if _, err = f.conn.Exec(ctx, "CREATE UNIQUE INDEX null_boundary ON "+f.table(target.Table)+"(base) NULLS NOT DISTINCT"); err == nil {
			t.Fatal("actual server did not enforce its NULL syntax version boundary")
		}
		return
	}
	authoringApply(t, s, store, target, d)
	if _, err = f.conn.Exec(ctx, "INSERT INTO "+f.table(target.Table)+" VALUES(NULL)"); err == nil {
		t.Fatal("NULLS NOT DISTINCT did not retain requested uniqueness")
	}
}

// Legitimate extension/operator-class metadata coverage. This does not assert
// that arbitrary extension AM support routines cannot be entered by the planner.
func TestStructureCustomAccessMethodNativeCatalogsLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: f.schema, Table: "custom_am"}
	f.exec("CREATE EXTENSION bloom WITH SCHEMA " + `"` + f.schema + `"`)
	defer f.exec("DROP EXTENSION IF EXISTS bloom CASCADE")
	f.exec("CREATE TABLE " + f.table(target.Table) + "(base int)")
	f.exec("INSERT INTO " + f.table(target.Table) + " VALUES(1)")
	column := "base"
	definition := tableedit.IndexDefinition{Method: "bloom", Terms: []tableedit.IndexTerm{{Column: &column}}, Options: []tableedit.IndexOption{{Name: "length", Value: "80"}}}
	authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "bloom_idx", Definition: &definition}}})
	for _, native := range []struct{ typ, support string }{{"oid", "hashoid"}, {"name", "hashname"}, {"int2", "hashint2"}, {"int8", "hashint8"}} {
		typ := "pg_catalog." + native.typ
		f.exec("CREATE OPERATOR CLASS " + f.table("native_"+native.typ+"_ops") + " FOR TYPE " + typ + " USING bloom AS OPERATOR 1 pg_catalog.=(" + typ + "," + typ + "), FUNCTION 1 pg_catalog." + native.support + "(" + typ + ")")
	}
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal("legitimate extension metadata load failed")
	}
	plain := tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: &column}}}
	if _, err = store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "not_dispatched", Definition: &plain}}}); err != nil {
		t.Fatal("legitimate extension catalog preview failed")
	}
	collector := sc.NewCollector(ctx, sc.DefaultLimits())
	if err = s.ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{f.schema}, Limits: sc.DefaultLimits()}, collector); err != nil {
		t.Fatal("legitimate extension schema capture failed")
	}
	var value int
	if f.observer.QueryRow(ctx, "SELECT base FROM "+f.table(target.Table)).Scan(&value) != nil || value != 1 {
		t.Fatal("catalog observation changed retained data")
	}
}

func TestStructureIndexVarcharExpressionNormalizationLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: f.schema, Table: "varchar_expression"}
	f.exec("CREATE TABLE " + f.table(target.Table) + "(value varchar(40))")
	f.exec("INSERT INTO " + f.table(target.Table) + " VALUES('Alpha')")
	expression := "lower(value)"
	authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "varchar_idx", Definition: &tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Expression: &expression}}}}}})
}

func TestStructureUnmodeledIndexAttributesBlockReplacementAndPreserveAdditiveLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: f.schema, Table: "index_attributes"}
	f.exec("CREATE TABLE " + f.table(target.Table) + "(id int NOT NULL,base int)")
	f.exec("INSERT INTO " + f.table(target.Table) + " VALUES(1,10),(2,20)")
	f.exec("CREATE INDEX comment_idx ON " + f.table(target.Table) + "(base)")
	f.exec("COMMENT ON INDEX " + f.table("comment_idx") + " IS 'kept exact comment'")
	f.exec("CREATE INDEX stats_idx ON " + f.table(target.Table) + "((base*2))")
	f.exec("ALTER INDEX " + f.table("stats_idx") + " ALTER COLUMN 1 SET STATISTICS 300")
	f.exec("CREATE INDEX cluster_idx ON " + f.table(target.Table) + "(base)")
	f.exec("CLUSTER " + f.table(target.Table) + " USING cluster_idx")
	f.exec("CREATE UNIQUE INDEX replica_idx ON " + f.table(target.Table) + "(id)")
	f.exec("ALTER TABLE " + f.table(target.Table) + " REPLICA IDENTITY USING INDEX replica_idx")
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal("attribute baseline unavailable")
	}
	names := []string{"comment_idx", "stats_idx", "cluster_idx", "replica_idx"}
	if location := os.Getenv("DBEER_TEST_POSTGRES_INDEX_TABLESPACE_PATH"); location != "" {
		space := f.schema + "_space"
		if _, err := f.conn.Exec(ctx, "CREATE TABLESPACE "+`"`+space+`"`+" LOCATION '"+strings.ReplaceAll(location, "'", "''")+"'"); err != nil {
			t.Fatal("owned tablespace fixture unavailable")
		}
		f.exec("CREATE INDEX space_idx ON " + f.table(target.Table) + "(base) TABLESPACE " + `"` + space + `"`)
		defer func() {
			f.exec("DROP INDEX IF EXISTS " + f.table("space_idx"))
			f.exec("DROP TABLESPACE " + `"` + space + `"`)
		}()
		names = append(names, "space_idx")
		b, err = store.Load(ctx, s, target)
		if err != nil {
			t.Fatal("tablespace attribute baseline unavailable")
		}
	}
	for _, name := range names {
		t.Run(name, func(t *testing.T) {
			if len(b.Baseline.Facts.IndexAttributes[name]) == 0 {
				t.Fatal("unmodeled index attributes were not bound to the baseline")
			}
			for _, index := range b.Baseline.Indexes {
				if index.Name == name && (index.Supported || index.Definition != nil) {
					t.Fatal("partial attribute evidence was presented as an editable complete index")
				}
			}
			column := "base"
			d := tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, AllowDestructive: true, Indexes: []tableedit.IndexEdit{{Action: "replace", Name: name, Definition: &tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: &column}}}}}}
			if _, err := store.PreviewContext(ctx, s, b.Baseline.ID, d); err == nil {
				t.Fatal("replacement could discard unexposed index attributes")
			}
		})
	}
	column := "base"
	out := authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "safe_new_idx", Definition: &tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: &column}}}}}})
	if len(out.Observed.Facts.IndexAttributes) != len(names) {
		t.Fatal("additive index creation changed untouched attribute evidence")
	}
}

func TestStructureIndexMetadataIgnoresSearchPathShadowsLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: f.schema, Table: "metadata_shadow"}
	f.exec("CREATE TABLE " + f.table(target.Table) + "(base pg_catalog.int4)")
	f.exec("CREATE INDEX shadow_stats_idx ON " + f.table(target.Table) + "((base*2))")
	f.exec("ALTER INDEX " + f.table("shadow_stats_idx") + " ALTER COLUMN 1 SET STATISTICS 300")
	f.exec("CREATE SEQUENCE " + f.table("metadata_counter"))
	body := " LANGUAGE plpgsql VOLATILE AS $$BEGIN PERFORM pg_catalog.nextval('" + f.table("metadata_counter") + "'); RETURN '[]'::pg_catalog.json; END$$"
	for _, signature := range []string{"(pg_catalog.int2,pg_catalog.int2)", "(pg_catalog.int2,pg_catalog.int4)"} {
		f.exec("CREATE FUNCTION " + f.table("json_build_array") + signature + " RETURNS pg_catalog.json" + body)
	}
	f.exec("CREATE FUNCTION " + f.table("json_agg") + "(pg_catalog.json) RETURNS pg_catalog.json" + body)
	f.exec("CREATE FUNCTION " + f.table("current_setting") + "(pg_catalog.text) RETURNS pg_catalog.text LANGUAGE plpgsql VOLATILE AS $$BEGIN PERFORM pg_catalog.nextval('" + f.table("metadata_counter") + "'); RETURN '170000'; END$$")
	f.exec("CREATE FUNCTION " + f.table("current_database") + "() RETURNS pg_catalog.name LANGUAGE plpgsql VOLATILE AS $$BEGIN PERFORM pg_catalog.nextval('" + f.table("metadata_counter") + "'); RETURN 'shadow'; END$$")
	f.exec("CREATE FUNCTION " + f.table("shadow_type_check") + "(pg_catalog.text) RETURNS pg_catalog.bool LANGUAGE plpgsql VOLATILE AS $$BEGIN PERFORM pg_catalog.nextval('" + f.table("metadata_counter") + "'); RETURN true; END$$")
	f.exec("CREATE DOMAIN " + f.table("text") + " AS pg_catalog.text CHECK (" + f.table("shadow_type_check") + "(VALUE))")
	f.exec("SET search_path TO " + `"` + f.schema + `"` + ",pg_catalog")
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal("shadowed search_path prevented trusted catalog loading")
	}
	if b.Baseline.Facts.IndexAttributes["shadow_stats_idx"]["statisticsTargets"] == "" {
		t.Fatal("shadowed helpers fabricated absence of index statistics")
	}
	column := "base"
	definition := tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: &column, Collation: nil}}}
	if _, err = store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "not_dispatched", Definition: &definition}}}); err != nil {
		t.Fatal("shadowed search_path prevented metadata-only Preview")
	}
	var called bool
	if f.observer.QueryRow(ctx, "SELECT is_called FROM "+f.table("metadata_counter")).Scan(&called) != nil || called {
		t.Fatal("metadata loading invoked a shadow function/type check")
	}
	var text string
	if f.observer.QueryRow(ctx, "SELECT "+f.table("json_build_array")+"(1::pg_catalog.int2,300::pg_catalog.int2)").Scan(&text) != nil {
		t.Fatal("owned shadow positive control unavailable")
	}
	if f.observer.QueryRow(ctx, "SELECT is_called FROM "+f.table("metadata_counter")).Scan(&called) != nil || !called {
		t.Fatal("owned shadow positive control did not execute")
	}
}
