package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	tc "dbeer/helper/internal/tablecapture"
	"github.com/jackc/pgx/v5"
	"os"
	"testing"
	"time"
)

func TestSchemaCapturePortableTypesAndReadOnly(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("disposable PostgreSQL fixture required")
	}
	ctx := context.Background()
	conn, e := pgx.Connect(ctx, dsn)
	if e != nil {
		t.Fatal("fixture connection failed")
	}
	defer conn.Close(ctx)
	suffix := time.Now().Format("150405000000")
	a, b := "schema_a_"+suffix, "schema_b_"+suffix
	for _, schema := range []string{a, b} {
		q := pgx.Identifier{schema}.Sanitize()
		if _, e = conn.Exec(ctx, "CREATE SCHEMA "+q+"; CREATE TYPE "+q+".mood AS ENUM ('new','done'); CREATE TABLE "+q+".orders(id numeric(30,9) PRIMARY KEY,status "+q+".mood, note text DEFAULT '',twice numeric GENERATED ALWAYS AS (id * 2) STORED); CREATE INDEX note_idx ON "+q+".orders(note) INCLUDE(status)"); e != nil {
			t.Fatal("fixture creation failed")
		}
		defer conn.Exec(ctx, "DROP SCHEMA "+q+" CASCADE")
	}
	capture := func(schema string) sc.Capture {
		reader, e := pgx.Connect(ctx, dsn)
		if e != nil {
			t.Fatal("capture connection failed")
		}
		defer reader.Close(ctx)
		c := sc.NewCollector(ctx, sc.DefaultLimits())
		s := &Session{conn: reader}
		if e = s.ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{schema}, Limits: sc.DefaultLimits()}, c); e != nil {
			t.Fatalf("capture failed: %T", e)
		}
		return c.Capture
	}
	left, right := capture(a), capture(b)
	m := sc.Mappings{Schemas: []sc.NamePair{{Source: a, Target: b}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}
	result, e := sc.Build(ctx, t.TempDir(), left, right, m)
	if e != nil {
		t.Fatal(e)
	}
	defer result.Close()
	if !result.Report.Summary.FullEquality {
		for _, d := range result.Report.Differences {
			t.Log(d.Property, d.Kind)
		}
		t.Fatal("portable equal schemas did not match")
	}
	if _, e = conn.Exec(ctx, "ALTER TYPE "+pgx.Identifier{b}.Sanitize()+".mood ADD VALUE 'later'"); e != nil {
		t.Fatal("fixture alteration failed")
	}
	changed, e := sc.Build(ctx, t.TempDir(), left, capture(b), m)
	if e != nil {
		t.Fatal(e)
	}
	defer changed.Close()
	if changed.Report.Summary.FullEquality || changed.Report.Summary.DifferenceCount == 0 {
		t.Fatal("enum drift was missed")
	}
}

func TestSchemaCaptureDeniedMetadataNeverProvesEquality(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("disposable PostgreSQL fixture required")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal("fixture connection failed")
	}
	defer conn.Close(ctx)
	suffix := time.Now().Format("150405000000")
	schema, role := "schema_access_"+suffix, "schema_reader_"+suffix
	q, user := pgx.Identifier{schema}.Sanitize(), pgx.Identifier{role}.Sanitize()
	if _, err = conn.Exec(ctx, "CREATE SCHEMA "+q+"; CREATE TABLE "+q+".orders(id int PRIMARY KEY,note text); CREATE ROLE "+user+"; GRANT USAGE ON SCHEMA "+q+" TO "+user+"; GRANT SELECT ON "+q+".orders TO "+user); err != nil {
		t.Fatal("access fixture creation failed")
	}
	defer conn.Exec(ctx, "DROP SCHEMA "+q+" CASCADE; DROP ROLE "+user)
	capture := func() sc.Capture {
		reader, e := pgx.Connect(ctx, dsn)
		if e != nil {
			t.Fatal("reader open failed")
		}
		defer reader.Close(ctx)
		if _, e = reader.Exec(ctx, "SET ROLE "+user); e != nil {
			t.Fatal("reader role failed")
		}
		collector := sc.NewCollector(ctx, sc.DefaultLimits())
		if e = (&Session{conn: reader}).ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{schema}, Limits: sc.DefaultLimits()}, collector); e != nil {
			t.Fatalf("access capture failed: %T", e)
		}
		return collector.Capture
	}
	m := sc.Mappings{Schemas: []sc.NamePair{{Source: schema, Target: schema}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}
	allowed := capture()
	hasPK := false
	for _, table := range allowed.Tables {
		for _, constraint := range table.Constraints.Items {
			if constraint.Kind.Value != nil && *constraint.Kind.Value == "p" {
				hasPK = true
			}
		}
	}
	if len(allowed.Tables) != 1 || !hasPK {
		t.Fatal("SELECT-only role lost catalog constraints")
	}
	if _, err = conn.Exec(ctx, "REVOKE ALL ON SCHEMA "+q+" FROM "+user+"; REVOKE ALL ON "+q+".orders FROM "+user); err != nil {
		t.Fatal("fixture revoke failed")
	}
	denied := capture()
	result, e := sc.Build(ctx, t.TempDir(), denied, capture(), m)
	if e != nil {
		t.Fatal(e)
	}
	defer result.Close()
	if result.Report.Summary.FullEquality || result.Report.Summary.Complete || result.Report.Summary.IssueCount == 0 {
		t.Fatal("matching denied access established equality")
	}
}

func TestSchemaCaptureAllTypeFamiliesAndNativeIdentities(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("disposable PostgreSQL fixture required")
	}
	ctx := context.Background()
	conn, e := pgx.Connect(ctx, dsn)
	if e != nil {
		t.Fatal("fixture connection failed")
	}
	defer conn.Close(ctx)
	suffix := time.Now().Format("150405000000")
	a, b := "alltypes_a_"+suffix, "alltypes_b_"+suffix
	for _, schema := range []string{a, b} {
		q := pgx.Identifier{schema}.Sanitize()
		statements := []string{
			"CREATE SCHEMA " + q,
			"CREATE FUNCTION " + q + ".compare(numeric,numeric) RETURNS integer AS 'numeric_cmp' LANGUAGE internal IMMUTABLE STRICT",
			"CREATE OPERATOR CLASS " + q + ".numeric_order FOR TYPE numeric USING btree AS OPERATOR 1 < (numeric,numeric),OPERATOR 2 <= (numeric,numeric),OPERATOR 3 = (numeric,numeric),OPERATOR 4 >= (numeric,numeric),OPERATOR 5 > (numeric,numeric),FUNCTION 1 " + q + ".compare(numeric,numeric)",
			"CREATE TYPE " + q + ".span AS RANGE (subtype=numeric,subtype_opclass=" + q + ".numeric_order,multirange_type_name=" + q + ".spans)",
			"CREATE TYPE " + q + ".node AS (value integer)",
			"CREATE TYPE " + q + ".tree AS (root " + q + ".node,children " + q + ".node[])",
			"CREATE COLLATION " + q + ".text_order FROM pg_catalog.\"C\"",
			"CREATE DOMAIN " + q + ".codes AS varchar(9)[] COLLATE " + q + ".text_order",
			"CREATE TYPE " + q + ".number",
			"CREATE FUNCTION " + q + ".number_in(cstring) RETURNS " + q + ".number AS 'int4in' LANGUAGE internal IMMUTABLE STRICT",
			"CREATE FUNCTION " + q + ".number_out(" + q + ".number) RETURNS cstring AS 'int4out' LANGUAGE internal IMMUTABLE STRICT",
			"CREATE TYPE " + q + ".number (INPUT=" + q + ".number_in,OUTPUT=" + q + ".number_out,INTERNALLENGTH=4,PASSEDBYVALUE,ALIGNMENT=int4,STORAGE=plain,CATEGORY='N')",
			"CREATE TYPE " + q + ".varchar",
			"CREATE FUNCTION " + q + ".varchar_in(cstring,oid,integer) RETURNS " + q + ".varchar AS 'varcharin' LANGUAGE internal IMMUTABLE STRICT",
			"CREATE FUNCTION " + q + ".varchar_out(" + q + ".varchar) RETURNS cstring AS 'varcharout' LANGUAGE internal IMMUTABLE STRICT",
			"CREATE TYPE " + q + ".varchar (INPUT=" + q + ".varchar_in,OUTPUT=" + q + ".varchar_out,TYPMOD_IN=pg_catalog.varchartypmodin,TYPMOD_OUT=pg_catalog.varchartypmodout,INTERNALLENGTH=VARIABLE,ALIGNMENT=int4,STORAGE=extended,CATEGORY='S',COLLATABLE=true)",
			"COMMENT ON TYPE " + q + ".varchar IS 'custom type modifier fixture'",
			"CREATE TABLE " + q + ".records(id integer PRIMARY KEY,pt point,iv int2vector,ov oidvector,span " + q + ".span,spans " + q + ".spans,tree " + q + ".tree,codes " + q + ".codes,n " + q + ".number,stock int4range,stocks int4multirange,times timestamp(2)[][],custom_text " + q + ".varchar(15)[])",
		}
		for _, sql := range statements {
			if _, e = conn.Exec(ctx, sql); e != nil {
				t.Fatalf("type fixture: %v", e)
			}
		}
		defer conn.Exec(ctx, "DROP SCHEMA "+q+" CASCADE")
	}
	capture := func(schema string) sc.Capture {
		c := sc.NewCollector(ctx, sc.DefaultLimits())
		if e = (&Session{conn: conn}).ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{schema}, Limits: sc.DefaultLimits()}, c); e != nil {
			t.Fatalf("type capture: %v", e)
		}
		return c.Capture
	}
	left, right := capture(a), capture(b)
	mapping := sc.Mappings{Schemas: []sc.NamePair{{Source: a, Target: b}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}
	result, e := sc.Build(ctx, t.TempDir(), left, right, mapping)
	if e != nil {
		t.Fatal(e)
	}
	defer result.Close()
	if !result.Report.Summary.FullEquality {
		for _, d := range result.Report.Differences {
			t.Log(d.Property, d.Kind)
		}
		for _, i := range result.Report.Issues {
			t.Log(i.Property, i.Code)
		}
		t.Fatal("equivalent type families did not match")
	}
	for _, c := range left.Tables[0].Columns.Items {
		if (c.Ref.Name == "pt" || c.Ref.Name == "iv" || c.Ref.Name == "ov") && c.Type.Value.Kind != "builtin" {
			t.Fatal("non-array built-in mistaken for array")
		}
	}
	for _, typ := range left.Types {
		def, e := RenderSchemaDefinition(ctx, left, typ.Ref)
		if e != nil || def.Limited || def.SQL == "" {
			t.Fatalf("type %s definition unavailable: %v %s", typ.Ref.Name, e, def.SQL)
		}
	}
	d, e := (&Session{conn: conn}).DescribeTable(ctx, tc.Table{Schema: a, Name: "records"})
	if e != nil || len(d.Columns) != 13 {
		t.Fatalf("type table describe: %v columns=%d", e, len(d.Columns))
	}
	if _, e = conn.Exec(ctx, "ALTER FUNCTION "+pgx.Identifier{b}.Sanitize()+".compare(numeric,numeric) COST 101"); e != nil {
		t.Fatal("support function alteration failed")
	}
	ordering, e := sc.Build(ctx, t.TempDir(), left, capture(b), mapping)
	if e != nil {
		t.Fatal(e)
	}
	defer ordering.Close()
	if ordering.Report.Summary.FullEquality || ordering.Report.Summary.DifferenceCount == 0 {
		t.Fatal("custom range ordering drift missed")
	}

	if _, e = conn.Exec(ctx, "ALTER TYPE "+pgx.Identifier{b}.Sanitize()+".node ADD ATTRIBUTE extra bigint"); e != nil {
		t.Fatal("type mutation failed")
	}
	changed, e := sc.Build(ctx, t.TempDir(), left, capture(b), mapping)
	if e != nil {
		t.Fatal(e)
	}
	defer changed.Close()
	if changed.Report.Summary.FullEquality || changed.Report.Summary.DifferenceCount == 0 {
		t.Fatal("nested type drift missed")
	}
}

func TestSchemaCaptureExtensionTypeAndVersion(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("disposable PostgreSQL fixture required")
	}
	ctx := context.Background()
	conn, e := pgx.Connect(ctx, dsn)
	if e != nil {
		t.Fatal("fixture connection failed")
	}
	defer conn.Close(ctx)
	schema := "extension_" + time.Now().Format("150405000000")
	q := pgx.Identifier{schema}.Sanitize()
	if _, e = conn.Exec(ctx, "CREATE SCHEMA "+q+"; CREATE EXTENSION hstore SCHEMA "+q+"; CREATE TABLE "+q+".records(id integer PRIMARY KEY,value "+q+".hstore)"); e != nil {
		t.Fatalf("extension fixture: %v", e)
	}
	defer conn.Exec(ctx, "DROP EXTENSION hstore CASCADE; DROP SCHEMA "+q+" CASCADE")
	capture := func() sc.Capture {
		c := sc.NewCollector(ctx, sc.DefaultLimits())
		if e = (&Session{conn: conn}).ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{schema}, Limits: sc.DefaultLimits()}, c); e != nil {
			t.Fatalf("extension capture: %v", e)
		}
		return c.Capture
	}
	c := capture()
	found := false
	for _, typ := range c.Types {
		if typ.Ref.Name == "hstore" {
			found = typ.Extension != nil && typ.Extension.Name == "hstore" && typ.Extension.Version != "" && typ.BaseType != nil && typ.Kind.State == "known"
		}
	}
	if !found {
		t.Fatal("extension catalog identity absent")
	}
	mapping := sc.Mappings{Schemas: []sc.NamePair{{Source: schema, Target: schema}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}
	result, e := sc.Build(ctx, t.TempDir(), c, capture(), mapping)
	if e != nil {
		t.Fatal(e)
	}
	defer result.Close()
	if !result.Report.Summary.FullEquality {
		t.Fatal("unchanged extension type is incomplete")
	}
	if _, e = (&Session{conn: conn}).DescribeTable(ctx, tc.Table{Schema: schema, Name: "records"}); e != nil {
		t.Fatalf("extension table description: %v", e)
	}
	for i := range c.Types {
		if c.Types[i].Extension != nil {
			c.Types[i].Extension.Version += ".changed"
		}
	}
	changed, e := sc.Build(ctx, t.TempDir(), c, capture(), mapping)
	if e != nil {
		t.Fatal(e)
	}
	defer changed.Close()
	if changed.Report.Summary.FullEquality || changed.Report.Summary.DifferenceCount == 0 {
		t.Fatal("extension version drift missed")
	}
}

func TestSchemaCaptureMappedTableRowTypes(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("disposable PostgreSQL fixture required")
	}
	ctx := context.Background()
	conn, e := pgx.Connect(ctx, dsn)
	if e != nil {
		t.Fatal("fixture connection failed")
	}
	defer conn.Close(ctx)
	suffix := time.Now().Format("150405000000")
	a, b := "rowtype_a_"+suffix, "rowtype_b_"+suffix
	for i, schema := range []string{a, b} {
		name := "records"
		if i == 1 {
			name = "renamed"
		}
		q := pgx.Identifier{schema}.Sanitize()
		if _, e = conn.Exec(ctx, "CREATE SCHEMA "+q+";CREATE TABLE "+q+"."+name+"(value integer);CREATE TABLE "+q+".container(rows "+q+"."+name+"[])"); e != nil {
			t.Fatalf("rowtype fixture: %v", e)
		}
		defer conn.Exec(ctx, "DROP SCHEMA "+q+" CASCADE")
	}
	capture := func(schema string) sc.Capture {
		c := sc.NewCollector(ctx, sc.DefaultLimits())
		if e = (&Session{conn: conn}).ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{schema}, Limits: sc.DefaultLimits()}, c); e != nil {
			t.Fatalf("rowtype capture: %v", e)
		}
		return c.Capture
	}
	mapping := sc.Mappings{Schemas: []sc.NamePair{{Source: a, Target: b}}, Tables: []sc.TablePair{{Source: sc.QualifiedName{Schema: a, Name: "records"}, Target: sc.QualifiedName{Schema: b, Name: "renamed"}, Columns: []sc.NamePair{}, Constraints: []sc.NamePair{}, Indexes: []sc.NamePair{}}}, Types: []sc.ObjectPair{}}
	result, e := sc.Build(ctx, t.TempDir(), capture(a), capture(b), mapping)
	if e != nil {
		t.Fatal(e)
	}
	defer result.Close()
	if !result.Report.Summary.FullEquality {
		for _, d := range result.Report.Differences {
			t.Log(d.Property, d.Kind)
		}
		t.Fatal("mapped table row type did not follow its table")
	}
}

func TestSchemaCaptureDomainFunctionBehavior(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("disposable PostgreSQL fixture required")
	}
	ctx := context.Background()
	conn, e := pgx.Connect(ctx, dsn)
	if e != nil {
		t.Fatal("fixture connection failed")
	}
	defer conn.Close(ctx)
	schema := "domainfn_" + time.Now().Format("150405000000")
	q := pgx.Identifier{schema}.Sanitize()
	if _, e = conn.Exec(ctx, "CREATE SCHEMA "+q+";CREATE FUNCTION "+q+".positive(integer) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT AS 'SELECT $1 > 0';CREATE DOMAIN "+q+".positive_int AS integer DEFAULT 1 CHECK("+q+".positive(VALUE));CREATE TABLE "+q+".records(value "+q+".positive_int)"); e != nil {
		t.Fatalf("domain function fixture: %v", e)
	}
	defer conn.Exec(ctx, "DROP SCHEMA "+q+" CASCADE")
	capture := func() sc.Capture {
		c := sc.NewCollector(ctx, sc.DefaultLimits())
		if e = (&Session{conn: conn}).ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{schema}, Limits: sc.DefaultLimits()}, c); e != nil {
			t.Fatalf("domain function capture: %v", e)
		}
		return c.Capture
	}
	before := capture()
	mapping := sc.Mappings{Schemas: []sc.NamePair{{Source: schema, Target: schema}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}
	result, e := sc.Build(ctx, t.TempDir(), before, capture(), mapping)
	if e != nil {
		t.Fatal(e)
	}
	defer result.Close()
	if !result.Report.Summary.FullEquality {
		for _, issue := range result.Report.Issues {
			t.Log(issue.Property, issue.Code)
		}
		t.Fatal("complete domain function metadata rejected")
	}
	if _, e = (&Session{conn: conn}).DescribeTable(ctx, tc.Table{Schema: schema, Name: "records"}); e != nil {
		t.Fatalf("domain function table description: %v", e)
	}
	if _, e = conn.Exec(ctx, "CREATE OR REPLACE FUNCTION "+q+".positive(integer) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT AS 'SELECT $1 >= 0'"); e != nil {
		t.Fatal("function behavior mutation failed")
	}
	changed, e := sc.Build(ctx, t.TempDir(), before, capture(), mapping)
	if e != nil {
		t.Fatal(e)
	}
	defer changed.Close()
	if changed.Report.Summary.FullEquality || changed.Report.Summary.DifferenceCount == 0 {
		t.Fatal("domain function behavior drift missed")
	}
}

func TestSchemaCaptureCollationBehavior(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("disposable PostgreSQL fixture required")
	}
	ctx := context.Background()
	conn, e := pgx.Connect(ctx, dsn)
	if e != nil {
		t.Fatal("fixture connection failed")
	}
	defer conn.Close(ctx)
	suffix := time.Now().Format("150405000000")
	a, b := "collation_a_"+suffix, "collation_b_"+suffix
	for i, schema := range []string{a, b} {
		locale := "C"
		if i == 1 {
			locale = "POSIX"
		}
		q := pgx.Identifier{schema}.Sanitize()
		if _, e = conn.Exec(ctx, "CREATE SCHEMA "+q+";CREATE COLLATION "+q+".ordering FROM pg_catalog."+pgx.Identifier{locale}.Sanitize()+";CREATE DOMAIN "+q+".label AS text COLLATE "+q+".ordering;CREATE TYPE "+q+".span AS RANGE(subtype=text,collation="+q+".ordering);CREATE TABLE "+q+".records(value "+q+".label,span "+q+".span)"); e != nil {
			t.Fatalf("collation fixture: %v", e)
		}
		defer conn.Exec(ctx, "DROP SCHEMA "+q+" CASCADE")
	}
	capture := func(schema string) sc.Capture {
		c := sc.NewCollector(ctx, sc.DefaultLimits())
		if e = (&Session{conn: conn}).ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{schema}, Limits: sc.DefaultLimits()}, c); e != nil {
			t.Fatalf("collation capture: %v", e)
		}
		return c.Capture
	}
	mapping := sc.Mappings{Schemas: []sc.NamePair{{Source: a, Target: b}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}
	result, e := sc.Build(ctx, t.TempDir(), capture(a), capture(b), mapping)
	if e != nil {
		t.Fatal(e)
	}
	defer result.Close()
	if !result.Report.Summary.Complete || result.Report.Summary.FullEquality || result.Report.Summary.DifferenceCount == 0 {
		t.Fatal("collation behavior drift missed")
	}
}
