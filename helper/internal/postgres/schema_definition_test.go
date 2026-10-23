package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/textdiff"
	"errors"
	"strings"
	"testing"
	"unicode/utf8"
)

func definitionBuiltin(name string, m sc.TypeModifiers) sc.TypeUse {
	return sc.TypeUse{Ref: sc.Ref{Kind: "type", Schema: "pg_catalog", Name: name}, Kind: "builtin", Modifiers: sc.Known(m), Labels: sc.Complete[string](nil)}
}
func definitionExpression(text string) sc.Expression {
	return sc.Expression{Text: text, Dependencies: sc.Complete[sc.Ref](nil)}
}
func definitionColumn(name string, u sc.TypeUse) sc.Column {
	return sc.Column{Ref: sc.Ref{Kind: "column", Schema: "public", Table: "items", Name: name}, Ordinal: sc.Known(0), Type: sc.Known(u), Nullable: sc.Known(true), Default: sc.Known(sc.Default{Kind: "none"}), Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(true), Comment: sc.Known(""), OnUpdate: sc.Absent[sc.Expression]()}
}
func definitionTable(columns ...sc.Column) sc.Table {
	return sc.Table{Ref: sc.Ref{Kind: "table", Schema: "public", Name: "items"}, Kind: sc.Known("r"), Storage: sc.Known("p"), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Options: sc.Complete[sc.Option](nil), Columns: sc.Complete(columns), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}
}
func definitionIndexKey(name string) sc.IndexKey {
	return sc.IndexKey{Column: sc.Known(sc.Ref{Kind: "column", Schema: "public", Table: "items", Name: name}), Expression: sc.Absent[sc.Expression](), Opclass: sc.Absent[sc.Ref](), Collation: sc.Absent[sc.Ref](), Descending: sc.Known(false), NullsFirst: sc.Known(false), PrefixLength: sc.Absent[int64](), Options: sc.Complete[sc.Option](nil)}
}
func definitionIndex(name string, keys ...sc.IndexKey) sc.Index {
	return sc.Index{Ref: sc.Ref{Kind: "index", Schema: "public", Table: "items", Name: name}, Method: sc.Known("btree"), Unique: sc.Known(false), NullsDistinct: sc.Known(true), Keys: sc.Complete(keys), Includes: sc.Complete[sc.Ref](nil), Predicate: sc.Absent[sc.Expression](), Options: sc.Complete[sc.Option](nil), Visible: sc.Known(true), Valid: sc.Known(true), Ready: sc.Known(true), Constraint: sc.Absent[sc.Ref]()}
}
func renderDefinitionTable(t *testing.T, table sc.Table) sc.Definition {
	t.Helper()
	got, e := RenderSchemaDefinition(context.Background(), sc.Capture{Tables: []sc.Table{table}}, table.Ref)
	if e != nil {
		t.Fatal(e)
	}
	return got
}
func requireDefinitionText(t *testing.T, got string, parts ...string) {
	t.Helper()
	for _, part := range parts {
		if !strings.Contains(got, part) {
			t.Fatalf("definition missing %q:\n%s", part, got)
		}
	}
}
func TestSchemaDefinitionQuotesAndDefaults(t *testing.T) {
	text := definitionBuiltin("text", sc.TypeModifiers{})
	literal := `quote' slash\ and NULL`
	c := definitionColumn(`a"b`, text)
	c.Default = sc.Known(sc.Default{Kind: "literal", Encoding: "text", Value: &literal})
	c.Comment = sc.Known("column's\ncomment")
	expr := definitionExpression(`nextval('original."odd''sequence"'::regclass) + length('source.column')`)
	e := definitionColumn("expression", text)
	e.Default = sc.Known(sc.Default{Kind: "expression", Expression: &expr})
	n := definitionColumn("null", text)
	n.Default = sc.Known(sc.Default{Kind: "sqlNull"})
	empty := ""
	z := definitionColumn("empty", text)
	z.Default = sc.Known(sc.Default{Kind: "literal", Value: &empty})
	binary := "AP8="
	b := definitionColumn("binary", definitionBuiltin("bytea", sc.TypeModifiers{}))
	b.Default = sc.Known(sc.Default{Kind: "literal", Encoding: "base64", Value: &binary})
	seq := definitionColumn("serial", definitionBuiltin("int8", sc.TypeModifiers{}))
	seq.Default = sc.Known(sc.Default{Kind: "sequence", Sequence: &sc.Ref{Kind: "sequence", Schema: `s"chema`, Name: `seq'"`}})
	table := definitionTable(c, e, n, z, b, seq)
	table.Ref.Schema = `s"chema`
	table.Ref.Name = `t"able`
	got := renderDefinitionTable(t, table)
	if got.Limited {
		t.Fatalf("fully captured definition is limited:\n%s", got.SQL)
	}
	requireDefinitionText(t, got.SQL, `CREATE TABLE "s""chema"."t""able" (`, `"a""b" "pg_catalog"."text" DEFAULT E'quote'' slash\\ and NULL'`, expr.Text, `"null" "pg_catalog"."text" DEFAULT NULL`, `"empty" "pg_catalog"."text" DEFAULT E''`, `DEFAULT E'\\x00ff'::bytea`, `COMMENT ON COLUMN "s""chema"."t""able"."a""b" IS E'column''s\ncomment';`, `DEFAULT nextval(E'"s""chema"."seq''"""'::regclass)`)
}
func TestSchemaDefinitionGeneratedIdentityAndStorage(t *testing.T) {
	c := definitionColumn("generated", definitionBuiltin("int4", sc.TypeModifiers{}))
	e := definitionExpression(`"old"."quantity" * 2`)
	c.Generated = sc.Known(sc.Generated{Kind: "stored", Expression: &e})
	i := definitionColumn("id", definitionBuiltin("int8", sc.TypeModifiers{}))
	i.Nullable = sc.Known(false)
	i.Identity = sc.Known(sc.Identity{Kind: "byDefault", Sequence: &sc.Ref{Schema: "public", Name: "items_id_seq"}})
	table := definitionTable(c, i)
	table.Storage = sc.Known("u")
	table.Options = sc.Complete([]sc.Option{{Name: "toast.autovacuum_enabled", Value: "false"}, {Name: "fillfactor", Value: "80"}})
	got := renderDefinitionTable(t, table)
	if got.Limited {
		t.Fatalf("definition limited:\n%s", got.SQL)
	}
	requireDefinitionText(t, got.SQL, `CREATE UNLOGGED TABLE`, `"generated" integer GENERATED ALWAYS AS ("old"."quantity" * 2) STORED`, `"id" bigint NOT NULL GENERATED BY DEFAULT AS IDENTITY (SEQUENCE NAME "public"."items_id_seq")`, `WITH ("fillfactor" = E'80', "toast"."autovacuum_enabled" = E'false')`)
}
func TestSchemaDefinitionBuiltinModifiers(t *testing.T) {
	ptr := func(v int64) *int64 { return &v }
	tests := []struct {
		name    string
		typ     sc.TypeUse
		want    string
		limited bool
	}{
		{"numeric", definitionBuiltin("numeric", sc.TypeModifiers{Precision: ptr(16), Scale: ptr(-2)}), "numeric(16, -2)", false},
		{"character", definitionBuiltin("bpchar", sc.TypeModifiers{Length: ptr(20)}), "character(20)", false},
		{"varchar", definitionBuiltin("varchar", sc.TypeModifiers{Length: ptr(255)}), "character varying(255)", false},
		{"varbit", definitionBuiltin("varbit", sc.TypeModifiers{Length: ptr(10)}), "bit varying(10)", false},
		{"timestamptz", definitionBuiltin("timestamptz", sc.TypeModifiers{DatetimePrecision: ptr(3)}), "timestamp(3) with time zone", false},
		{"timetz", definitionBuiltin("timetz", sc.TypeModifiers{DatetimePrecision: ptr(6)}), "time(6) with time zone", false},
		{"interval", definitionBuiltin("interval", sc.TypeModifiers{Interval: ptr(7176), DatetimePrecision: ptr(2)}), "interval DAY TO SECOND(2)", false},
		{"full interval", definitionBuiltin("interval", sc.TypeModifiers{Interval: ptr(32767), DatetimePrecision: ptr(65535)}), "interval", false},
		{"user timestamptz", sc.TypeUse{Ref: sc.Ref{Schema: "custom", Name: "timestamptz"}, Modifiers: sc.Known(sc.TypeModifiers{})}, `"custom"."timestamptz"`, false},
		{"user numeric", sc.TypeUse{Ref: sc.Ref{Schema: "custom", Name: "numeric"}, Modifiers: sc.Known(sc.TypeModifiers{Precision: ptr(10)})}, `"custom"."numeric"`, true},
	}
	element := definitionBuiltin("varchar", sc.TypeModifiers{Length: ptr(8)})
	tests = append(tests, struct {
		name    string
		typ     sc.TypeUse
		want    string
		limited bool
	}{"array", sc.TypeUse{Kind: "array", Element: &element, Modifiers: sc.Known(sc.TypeModifiers{ArrayDimensions: 2})}, "character varying(8)[][]", false})
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := pgDefinition{w: &sc.DefinitionWriter{Context: context.Background()}}
			r.typ(tt.typ)
			got, e := r.w.Finish()
			if e != nil {
				t.Fatal(e)
			}
			if !strings.HasPrefix(got.SQL, tt.want) || got.Limited != tt.limited {
				t.Fatalf("got %#v, want %q limited=%v", got, tt.want, tt.limited)
			}
		})
	}
}
func TestSchemaDefinitionConstraintsAndIndexes(t *testing.T) {
	table := definitionTable(definitionColumn("id", definitionBuiltin("int4", sc.TypeModifiers{})), definitionColumn("payload", definitionBuiltin("text", sc.TypeModifiers{})))
	id := table.Columns.Items[0].Ref
	pk := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: "public", Table: "items", Name: "items_pk"}, "p")
	pk.Columns = sc.Complete([]sc.Ref{id})
	u := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: "public", Table: "items", Name: "items_unique"}, "u")
	u.Columns = sc.Complete([]sc.Ref{id})
	u.Deferrable = sc.Known(true)
	u.InitiallyDeferred = sc.Known(true)
	backing := definitionIndex("items_unique", definitionIndexKey("id"))
	backing.Unique = sc.Known(true)
	backing.Constraint = sc.Known(u.Ref)
	backing.NullsDistinct = sc.Known(false)
	backing.Includes = sc.Complete([]sc.Ref{table.Columns.Items[1].Ref})
	backing.Options = sc.Complete([]sc.Option{{Name: "fillfactor", Value: "70"}})
	fk := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: "public", Table: "items", Name: "items_fk"}, "f")
	fk.Columns = sc.Complete([]sc.Ref{id})
	fk.Target = sc.Known(sc.Ref{Kind: "table", Schema: "remote", Name: "parents"})
	fk.ForeignKeys = sc.Complete([]sc.ColumnPair{{Source: id, Target: sc.Ref{Name: "parent_id"}}})
	fk.Match = sc.Known("f")
	fk.Update = sc.Known("c")
	fk.Delete = sc.Known("n")
	fk.SetColumns = sc.Complete([]sc.Ref{id})
	fk.Validated = sc.Known(false)
	check := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: "public", Table: "items", Name: "items_check"}, "c")
	check.Check = sc.Known(definitionExpression(`"id" > 0`))
	check.NoInherit = sc.Known(true)
	check.Enforced = sc.Known(false)
	key := definitionIndexKey("payload")
	key.Descending = sc.Known(true)
	key.NullsFirst = sc.Known(true)
	key.Collation = sc.Known(sc.Ref{Schema: "pg_catalog", Name: "C"})
	key.Opclass = sc.Known(sc.Ref{Schema: "pg_catalog", Name: "text_ops"})
	key.Options = sc.Complete([]sc.Option{{Name: "some_option", Value: "x"}})
	expr := definitionIndexKey("")
	expr.Column = sc.Absent[sc.Ref]()
	expr.Expression = sc.Known(definitionExpression(`lower("payload")`))
	x := definitionIndex("payload_idx", key, expr)
	x.Unique = sc.Known(true)
	x.NullsDistinct = sc.Known(false)
	x.Includes = sc.Complete([]sc.Ref{id})
	x.Predicate = sc.Known(definitionExpression(`"id" > 10`))
	x.Options = sc.Complete([]sc.Option{{Name: "fillfactor", Value: "90"}})
	table.Constraints = sc.Complete([]sc.Constraint{pk, u, fk, check})
	table.Indexes = sc.Complete([]sc.Index{backing, x})
	got := renderDefinitionTable(t, table)
	if got.Limited {
		t.Fatalf("definition limited:\n%s", got.SQL)
	}
	requireDefinitionText(t, got.SQL, `CONSTRAINT "items_pk" PRIMARY KEY ("id")`, `CONSTRAINT "items_unique" UNIQUE NULLS NOT DISTINCT ("id") INCLUDE ("payload") WITH ("fillfactor" = E'70') DEFERRABLE INITIALLY DEFERRED`, `CONSTRAINT "items_check" CHECK ("id" > 0) NO INHERIT NOT ENFORCED`, `ALTER TABLE "public"."items" ADD CONSTRAINT "items_fk" FOREIGN KEY ("id") REFERENCES "remote"."parents" ("parent_id") MATCH FULL ON UPDATE CASCADE ON DELETE SET NULL ("id") NOT VALID;`, `CREATE UNIQUE INDEX "payload_idx" ON "public"."items" USING "btree" ("payload" COLLATE "pg_catalog"."C" "pg_catalog"."text_ops" ("some_option" = E'x') DESC NULLS FIRST, (lower("payload")) ASC NULLS LAST) INCLUDE ("id") NULLS NOT DISTINCT WITH ("fillfactor" = E'90') WHERE "id" > 10;`)
	if strings.Contains(got.SQL, `CREATE UNIQUE INDEX "items_unique"`) {
		t.Fatal("constraint backing index duplicated")
	}
}
func TestSchemaDefinitionCapturedIndexKeyPreserved(t *testing.T) {
	table := definitionTable(definitionColumn("payload", definitionBuiltin("text", sc.TypeModifiers{})))
	key := definitionIndexKey("")
	key.Column = sc.Absent[sc.Ref]()
	text := `lower("payload") COLLATE "C" text_pattern_ops DESC NULLS FIRST`
	key.Expression = sc.Known(sc.Expression{Text: text, Dependencies: sc.Collection[sc.Ref]{State: "unavailable", Code: "expressionIndexKey"}})
	table.Indexes = sc.Complete([]sc.Index{definitionIndex("expression", key)})
	got := renderDefinitionTable(t, table)
	if !got.Limited {
		t.Fatal("unresolved expression dependencies reported complete")
	}
	requireDefinitionText(t, got.SQL, "USING \"btree\" ("+text+");")
	if strings.Count(got.SQL, "NULLS FIRST") != 1 {
		t.Fatal("captured key suffix duplicated")
	}
}
func TestSchemaDefinitionTypesAndSequences(t *testing.T) {
	ref := sc.Ref{Kind: "type", Schema: "public", Name: "status"}
	enum := sc.TypeDefinition{Ref: ref, Kind: sc.Known("e"), Labels: sc.Complete([]string{"ready", "it's done", ""})}
	got, e := RenderSchemaDefinition(context.Background(), sc.Capture{Types: []sc.TypeDefinition{enum}}, ref)
	if e != nil {
		t.Fatal(e)
	}
	if got.Limited || got.SQL != `CREATE TYPE "public"."status" AS ENUM (E'ready', E'it''s done', E'');`+"\n" {
		t.Fatalf("enum: %#v", got)
	}
	check := sc.NewConstraint(sc.Ref{Name: "positive"}, "c")
	check.Check = sc.Known(definitionExpression("VALUE > 0"))
	check.Validated = sc.Known(false)
	domain := sc.TypeDefinition{Ref: ref, Kind: sc.Known("d"), Base: sc.Known(definitionBuiltin("int4", sc.TypeModifiers{})), Default: sc.Known(sc.Default{Kind: "sqlNull"}), Nullable: sc.Known(false), Checks: sc.Complete([]sc.Constraint{check})}
	got, e = RenderSchemaDefinition(context.Background(), sc.Capture{Types: []sc.TypeDefinition{domain}}, ref)
	if e != nil {
		t.Fatal(e)
	}
	if got.Limited {
		t.Fatalf("domain limited: %s", got.SQL)
	}
	requireDefinitionText(t, got.SQL, `CREATE DOMAIN "public"."status" AS integer DEFAULT NULL NOT NULL;`, `ALTER DOMAIN "public"."status" ADD CONSTRAINT "positive" CHECK (VALUE > 0) NOT VALID;`)
	composite := sc.TypeDefinition{Ref: ref, Kind: sc.Known("c"), Attributes: sc.Complete([]sc.Column{definitionColumn("value", definitionBuiltin("int8", sc.TypeModifiers{}))})}
	got, e = RenderSchemaDefinition(context.Background(), sc.Capture{Types: []sc.TypeDefinition{composite}}, ref)
	if e != nil {
		t.Fatal(e)
	}
	if got.Limited {
		t.Fatalf("composite limited: %s", got.SQL)
	}
	requireDefinitionText(t, got.SQL, "CREATE TYPE \"public\".\"status\" AS (\n    \"value\" bigint\n);")
	s := sc.Sequence{Ref: sc.Ref{Kind: "sequence", Schema: "public", Name: "items_id_seq"}, Type: sc.Known(definitionBuiltin("int8", sc.TypeModifiers{})), Start: sc.Known("10"), Increment: sc.Known("-2"), Min: sc.Known("-9223372036854775808"), Max: sc.Known("9223372036854775807"), Cache: sc.Known("50"), Cycle: sc.Known(true), Owner: sc.Known(sc.Ref{Schema: "public", Table: "items", Name: "id"})}
	got, e = RenderSchemaDefinition(context.Background(), sc.Capture{Sequences: []sc.Sequence{s}}, s.Ref)
	if e != nil {
		t.Fatal(e)
	}
	if got.Limited {
		t.Fatalf("sequence limited: %s", got.SQL)
	}
	requireDefinitionText(t, got.SQL, `CREATE SEQUENCE "public"."items_id_seq" AS bigint`, "START WITH 10", "INCREMENT BY -2", "MINVALUE -9223372036854775808", "MAXVALUE 9223372036854775807", "CACHE 50", "CYCLE", `OWNED BY "public"."items"."id"`)
}
func TestSchemaDefinitionUnavailableAndBounds(t *testing.T) {
	c := definitionColumn("unknown", definitionBuiltin("int4", sc.TypeModifiers{}))
	c.Type = sc.Unknown[sc.TypeUse]("permission")
	c.Default = sc.Unknown[sc.Default]("unavailable")
	got := renderDefinitionTable(t, definitionTable(c))
	if !got.Limited {
		t.Fatal("unknown facts reported complete")
	}
	requireDefinitionText(t, got.SQL, `"unknown" /* type unavailable */`, "Unavailable column type", "Unavailable column default")
	if strings.Contains(got.SQL, " DEFAULT NULL") || strings.Contains(got.SQL, "integer") {
		t.Fatal("unknown fact fabricated")
	}
	c.Type = sc.Absent[sc.TypeUse]()
	got = renderDefinitionTable(t, definitionTable(c))
	if !got.Limited {
		t.Fatal("known-nil required type reported complete")
	}
	large := strings.Repeat("日", textdiff.MaxTextBytes)
	c = definitionColumn("large", definitionBuiltin("text", sc.TypeModifiers{}))
	e := definitionExpression(large)
	c.Default = sc.Known(sc.Default{Kind: "expression", Expression: &e})
	columns := make([]sc.Column, 10000)
	for i := range columns {
		columns[i] = c
	}
	got = renderDefinitionTable(t, definitionTable(columns...))
	if !got.Limited || len(got.SQL) > textdiff.MaxTextBytes || !utf8.ValidString(got.SQL) {
		t.Fatalf("unbounded/invalid definition: bytes=%d limited=%v", len(got.SQL), got.Limited)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := RenderSchemaDefinition(ctx, sc.Capture{Tables: []sc.Table{definitionTable(c)}}, definitionTable(c).Ref)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation: %v", err)
	}
}
