package postgres

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
)

func pgDestructiveBaseline(typ tableedit.DataType) tableedit.Baseline {
	name := "exact\"é"
	c := sc.Column{Ref: sc.Ref{Kind: "column", Schema: "public", Table: "fixture", Name: name}, Type: sc.Known(tableedit.ExpectedNewType("postgresql", typ)), Ordinal: sc.Known(1), Nullable: sc.Known(true), Default: sc.Known(sc.Default{Kind: "none"}), Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(true), Comment: sc.Known("preserved"), OnUpdate: sc.Absent[sc.Expression]()}
	if typ.Kind == "text" || typ.Kind == "varchar" {
		c.Collation = sc.Known(sc.Ref{Kind: "collation", Schema: "pg_catalog", Name: "C"})
	}
	storage := map[string]string{"integer": "p", "bigint": "p", "numeric": "m", "varchar": "x", "text": "x", "boolean": "p"}
	oid := map[string]string{"integer": "23", "bigint": "20", "numeric": "1700", "varchar": "1043", "text": "25", "boolean": "16"}
	return tableedit.Baseline{Engine: "postgresql", Target: tableedit.Target{Schema: "public", Table: "fixture"}, Attributes: map[string]map[string]any{name: {"atttypid": oid[typ.Kind], "attstorage": storage[typ.Kind], "attcompression": ""}}, Facts: &tableedit.Facts{TypeStorage: storage, Proof: true, Table: sc.Table{Columns: sc.Complete([]sc.Column{c}), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil)}, Dependents: map[string][]string{}}}
}

func TestStructureDestructivePostgresRenderAndValidationBoundaries(t *testing.T) {
	b := pgDestructiveBaseline(tableedit.DataType{Kind: "varchar", Length: 80})
	name := b.Facts.Table.Columns.Items[0].Ref.Name
	typ := tableedit.DataType{Kind: "varchar", Length: 8}
	c := tableedit.ColumnChange{Name: name, Type: &typ}
	sql, err := pgConversionChange(b, c, `"public"."fixture"`)
	if err != nil || !strings.Contains(sql, `ALTER COLUMN "exact""é" TYPE pg_catalog.varchar(8) COLLATE "pg_catalog"."C";`) {
		t.Fatalf("narrowing lost the exact identifier or existing collation: %v", err)
	}
	check := pgConversionCheck(b, c)
	if check.SQL == nil || check.UnavailableReason != nil || !strings.Contains(*check.SQL, `pg_catalog.char_length("exact""é") OPERATOR(pg_catalog.>) 8`) || !strings.Contains(*check.SQL, `"exact""é" IS NOT NULL`) {
		t.Fatal("varchar validation did not retain exact identity and SQL NULL semantics")
	}
	using := `pg_catalog.left("exact""é", 8)`
	c.UsingExpression = &using
	sql, err = pgConversionChange(b, c, `"public"."fixture"`)
	if err != nil || !strings.Contains(sql, " USING (") || !strings.Contains(sql, using) {
		t.Fatal("bounded USING was not retained as an explicit authored slot")
	}
	check = pgConversionCheck(b, c)
	if check.SQL != nil || check.UnavailableReason == nil || !strings.Contains(*check.UnavailableReason, "never evaluates") {
		t.Fatal("authored USING became automatically executable validation")
	}
	using = `1); DROP TABLE fixture; --`
	if _, err = pgConversionChange(b, c, `"public"."fixture"`); err == nil {
		t.Fatal("USING escaped its expression boundary")
	}
	charset := "LATIN1"
	c = tableedit.ColumnChange{Name: name, Charset: &charset}
	if _, err = pgConversionChange(b, c, `"public"."fixture"`); err == nil {
		t.Fatal("PostgreSQL admitted a column encoding alteration")
	}
	b.Facts.TypeStorage = map[string]string{"varchar": "x"}
	b.Attributes = map[string]map[string]any{name: {"attstorage": "e", "attcompression": ""}}
	if _, err = pgConversionChange(b, tableedit.ColumnChange{Name: name, Type: &typ}, `"public"."fixture"`); err == nil {
		t.Fatal("ALTER TYPE silently reset an explicit storage policy")
	}
	b.Attributes[name]["attstorage"], b.Attributes[name]["attcompression"] = "x", "p"
	if _, err = pgConversionChange(b, tableedit.ColumnChange{Name: name, Type: &typ}, `"public"."fixture"`); err == nil {
		t.Fatal("ALTER TYPE silently reset explicit compression")
	}
	// Unavailable checks never open a transaction or require a connection.
	s := &Session{}
	results := s.StructureValidate(context.Background(), b, tableedit.Plan{ValidationChecks: []tableedit.ValidationCheck{check}})
	if len(results) != 1 || results[0].State != "unavailable" {
		t.Fatal("unavailable USING validation attempted execution")
	}
}

func TestStructureDestructivePostgresExactNumericChecks(t *testing.T) {
	b := pgDestructiveBaseline(tableedit.DataType{Kind: "numeric", Precision: 30, Scale: 5})
	name := b.Facts.Table.Columns.Items[0].Ref.Name
	bigint := tableedit.DataType{Kind: "bigint"}
	check := pgConversionCheck(b, tableedit.ColumnChange{Name: name, Type: &bigint})
	if check.SQL == nil || !strings.Contains(*check.SQL, "'9223372036854775807'::pg_catalog.numeric") || !strings.Contains(*check.SQL, "pg_catalog.trunc(") {
		t.Fatal("exact bigint range/fraction validation was lost")
	}
	numeric := tableedit.DataType{Kind: "numeric", Precision: 12, Scale: 3}
	check = pgConversionCheck(b, tableedit.ColumnChange{Name: name, Type: &numeric})
	if check.SQL == nil || !strings.Contains(*check.SQL, "'1000000000'::pg_catalog.numeric") || !strings.Contains(*check.SQL, ",3)") {
		t.Fatal("decimal precision/scale validation used an inexact bound")
	}
	b.Facts.Table.Columns.Items[0].Type.Value.Kind = "domain"
	check = pgConversionCheck(b, tableedit.ColumnChange{Name: name, Type: &bigint})
	if check.SQL != nil || check.UnavailableReason == nil {
		t.Fatal("custom type support became executable validation")
	}
}

func TestStructureDestructivePostgresDropPreviewHasNoScans(t *testing.T) {
	b := pgDestructiveBaseline(tableedit.DataType{Kind: "integer"})
	b.Columns = []tableedit.ObservedColumn{{Name: b.Facts.Table.Columns.Items[0].Ref.Name}}
	draft := tableedit.Draft{AuthoringVersion: 4, DropTable: true, Columns: []tableedit.Column{}, AllowDestructive: true}
	p, err := (&Session{}).StructurePrepare(context.Background(), b, draft)
	if err != nil || len(p.SQL) != 1 || p.SQL[0] != `DROP TABLE "public"."fixture" RESTRICT;` || !p.DroppedTarget || len(p.Consequences) == 0 || len(p.ValidationChecks) != 1 || p.ValidationChecks[0].SQL != nil {
		t.Fatalf("DROP review was incomplete or attempted to read values: %v", err)
	}
}

func TestStructureDestructivePostgresConversionValidationDropLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	ctx := context.Background()
	target := tableedit.Target{Schema: f.schema, Table: "destructive"}
	f.exec("CREATE TABLE " + f.table(target.Table) + "(id integer PRIMARY KEY,amount numeric(30,4),label varchar(40) COLLATE pg_catalog.\"C\",doomed text,kept text)")
	f.exec("COMMENT ON COLUMN " + f.table(target.Table) + ".label IS 'preserved comment'")
	f.exec("INSERT INTO " + f.table(target.Table) + " VALUES(1,2147483648.5,'é-long-value','remove',NULL),(2,NULL,NULL,NULL,'NULL')")
	preview := func(change tableedit.ColumnChange) (*tableedit.Store, *tableedit.Plan) {
		t.Helper()
		store := &tableedit.Store{}
		b, err := store.Load(ctx, s, target)
		if err != nil {
			t.Fatal("destructive baseline unavailable")
		}
		p, err := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{change}, AllowDestructive: true})
		if err != nil || !p.Plan.Destructive || len(p.Plan.Consequences) == 0 || len(p.Plan.ValidationChecks) == 0 {
			t.Fatalf("destructive conversion preview unavailable: %v", err)
		}
		return store, p.Plan
	}
	integer := tableedit.DataType{Kind: "integer"}
	store, p := preview(tableedit.ColumnChange{Name: "amount", Type: &integer})
	validation, err := store.Validate(ctx, s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "invalid_values"})
	if err != nil || validation.Validation == nil || validation.Validation.State != "completed" && validation.Validation.State != "failed" || validation.Validation.Checks[0].State != "failed" || validation.Validation.Checks[0].InvalidRows == nil || *validation.Validation.Checks[0].InvalidRows != "1" {
		t.Fatal("range/fraction validation did not report the exact invalid-row count")
	}
	failed, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "rejected_narrowing"})
	if err != nil || failed.Outcome.State != "failed" {
		t.Fatal("overflow narrowing was not a known PostgreSQL rejection")
	}
	f.exec("UPDATE " + f.table(target.Table) + " SET amount=12.25,label='é' WHERE id=1")
	decimal := tableedit.DataType{Kind: "numeric", Precision: 10, Scale: 2}
	store, p = preview(tableedit.ColumnChange{Name: "amount", Type: &decimal})
	validation, err = store.Validate(ctx, s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "valid_values"})
	if err != nil || validation.Validation.Checks[0].State != "passed" {
		t.Fatal("representable exact numeric values did not validate")
	}
	result, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "numeric_narrow"})
	if err != nil || result.Outcome.State != "applied" || result.Outcome.Steps[0].Message != "" {
		t.Fatalf("numeric narrowing transition did not verify: %v", result.Outcome)
	}
	label := tableedit.DataType{Kind: "varchar", Length: 8}
	structureRunDraft(t, s, target, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "label", Type: &label}}}, "varchar_narrow")
	collation := tableedit.TypeReference{Schema: "pg_catalog", Name: "POSIX"}
	structureRunDraft(t, s, target, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "label", Collation: &collation}}}, "collation_change")
	f.exec("CREATE INDEX destructive_doomed ON " + f.table(target.Table) + "(doomed)")
	store = &tableedit.Store{}
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal("drop baseline unavailable")
	}
	drop := tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "doomed", Drop: true}}}
	if _, err = store.PreviewContext(ctx, s, b.Baseline.ID, drop); err == nil || !strings.Contains(err.Error(), "destructive_doomed") {
		t.Fatal("column removal did not identify its unscheduled dependent index")
	}
	drop.Indexes = []tableedit.IndexEdit{{Action: "drop", Name: "destructive_doomed"}}
	structureRunDraft(t, s, target, drop, "column_drop")
	var preserved bool
	if err = f.observer.QueryRow(ctx, "SELECT count(*)=2 AND count(amount)=1 AND min(amount)=12.25 AND min(label)='é' AND count(kept)=1 AND max(kept)='NULL' FROM "+f.table(target.Table)).Scan(&preserved); err != nil || !preserved {
		t.Fatal("conversion/drop changed unaffected rows or SQL NULL/text NULL")
	}
	dropped := structureRunDraft(t, s, target, tableedit.Draft{AuthoringVersion: 4, DropTable: true, Columns: []tableedit.Column{}, AllowDestructive: true}, "table_drop")
	if !dropped.DroppedTarget || dropped.Observed != nil || dropped.RefreshError != "" {
		t.Fatal("acknowledged table deletion was not represented as an absent target")
	}
}

func TestStructureDestructivePostgresUsingPreviewNeverEvaluatesLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("using_source") + "(id integer PRIMARY KEY,value bigint)")
	f.exec("CREATE SEQUENCE " + f.table("using_sequence"))
	f.exec("INSERT INTO " + f.table("using_source") + " VALUES(1,9),(2,NULL)")
	store := &tableedit.Store{}
	b, err := store.Load(ctx, s, tableedit.Target{Schema: f.schema, Table: "using_source"})
	if err != nil {
		t.Fatal("USING baseline unavailable")
	}
	integer := tableedit.DataType{Kind: "integer"}
	expression := fmt.Sprintf("pg_catalog.nextval('%s.using_sequence'::pg_catalog.regclass)", f.schema)
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "value", Type: &integer, UsingExpression: &expression}}})
	if err != nil {
		t.Fatal("bounded USING preview unavailable")
	}
	validation, err := store.Validate(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "using_unavailable"})
	if err != nil || validation.Validation.Checks[0].State != "unavailable" {
		t.Fatal("arbitrary USING validation was not explicitly unavailable")
	}
	var called bool
	if f.observer.QueryRow(ctx, "SELECT is_called FROM "+f.table("using_sequence")).Scan(&called) != nil || called {
		t.Fatal("Preview or validation evaluated the authored USING expression")
	}
	result, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "using_apply"})
	if err != nil || result.Outcome.State != "applied" || result.Outcome.Steps[0].Message != "" {
		t.Fatal("explicit USING did not apply as a verified conversion")
	}
}

func TestStructureDestructivePostgresCancellationAndOwnedSequenceLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	ctx := context.Background()
	target := tableedit.Target{Schema: f.schema, Table: "cancel_validation"}
	f.exec("CREATE TABLE " + f.table(target.Table) + "(id integer PRIMARY KEY,value bigint,owned bigint GENERATED ALWAYS AS IDENTITY)")
	f.exec("INSERT INTO " + f.table(target.Table) + "(id,value) VALUES(1,9),(2,NULL)")
	store := &tableedit.Store{}
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal("validation cancellation baseline unavailable")
	}
	integer := tableedit.DataType{Kind: "integer"}
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "value", Type: &integer}}})
	if err != nil {
		t.Fatal("validation cancellation preview unavailable")
	}
	blocker, err := f.observer.Begin(ctx)
	if err != nil {
		t.Fatal("validation cancellation blocker unavailable")
	}
	defer blocker.Rollback(context.Background())
	if _, err = blocker.Exec(ctx, "LOCK TABLE "+f.table(target.Table)+" IN ACCESS EXCLUSIVE MODE"); err != nil {
		t.Fatal("validation cancellation lock unavailable")
	}
	limited, cancel := context.WithTimeout(ctx, 150*time.Millisecond)
	started := time.Now()
	validation, err := store.Validate(limited, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "cancel_validation"})
	cancel()
	if err != nil || validation.Validation.State != "cancelled" || validation.Validation.Checks[0].State != "cancelled" || time.Since(started) > 3*time.Second {
		t.Fatal("validation did not cancel its owned lock wait promptly")
	}
	if err = blocker.Rollback(ctx); err != nil {
		t.Fatal("validation cancellation lock cleanup unavailable")
	}
	if s.TransactionStatus() != "idle" {
		t.Fatal("read-only validation leaked a transaction")
	}
	structureRunDraft(t, s, target, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "owned", Drop: true}}}, "owned_column_drop")
	f.exec("ALTER TABLE " + f.table(target.Table) + " ALTER COLUMN value SET STORAGE PLAIN")
	// A same-kind storage policy is the normal type default and remains supported.
	structureRunDraft(t, s, target, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "value", Type: &integer}}}, "value_narrow_after_cancel")
}

func TestStructureDestructivePostgresValidationRequiresBuiltinOID(t *testing.T) {
	b := pgDestructiveBaseline(tableedit.DataType{Kind: "numeric", Precision: 30, Scale: 5})
	name := b.Facts.Table.Columns.Items[0].Ref.Name
	want := tableedit.DataType{Kind: "integer"}
	b.Attributes = map[string]map[string]any{name: {"atttypid": float64(900001)}}
	check := pgConversionCheck(b, tableedit.ColumnChange{Name: name, Type: &want})
	if check.SQL != nil || check.UnavailableReason == nil {
		t.Fatal("a builtin display name with a different native type identity authorized validation")
	}
	b.Attributes[name]["atttypid"] = float64(1700)
	check = pgConversionCheck(b, tableedit.ColumnChange{Name: name, Type: &want})
	if check.SQL == nil || check.UnavailableReason != nil {
		t.Fatal("the actual captured builtin identity was rejected")
	}
	b.Facts.Table.Columns.Items[0].Type.Value.Ref.Schema = "application"
	check = pgConversionCheck(b, tableedit.ColumnChange{Name: name, Type: &want})
	if check.SQL != nil || check.UnavailableReason == nil {
		t.Fatal("a custom-schema lookalike authorized builtin validation")
	}
}

func TestStructureDestructivePostgresValidationQualifiesBuiltinOperators(t *testing.T) {
	for _, tc := range []struct {
		source, want tableedit.DataType
		operators    []string
	}{
		{tableedit.DataType{Kind: "varchar", Length: 80}, tableedit.DataType{Kind: "varchar", Length: 8}, []string{"OPERATOR(pg_catalog.>)"}},
		{tableedit.DataType{Kind: "numeric", Precision: 30, Scale: 5}, tableedit.DataType{Kind: "integer"}, []string{"OPERATOR(pg_catalog.<)", "OPERATOR(pg_catalog.>)", "OPERATOR(pg_catalog.<>)", "'-2147483648'::pg_catalog.numeric"}},
		{tableedit.DataType{Kind: "numeric", Precision: 30, Scale: 5}, tableedit.DataType{Kind: "numeric", Precision: 12, Scale: 3}, []string{"OPERATOR(pg_catalog.>=)", "OPERATOR(pg_catalog.<>)"}},
	} {
		b := pgDestructiveBaseline(tc.source)
		name := b.Facts.Table.Columns.Items[0].Ref.Name
		check := pgConversionCheck(b, tableedit.ColumnChange{Name: name, Type: &tc.want})
		if check.SQL == nil {
			t.Fatal("trusted builtin validation unavailable")
		}
		for _, operator := range tc.operators {
			if !strings.Contains(*check.SQL, operator) {
				t.Fatal("generated validation left operator or signed-bound resolution to the user search path")
			}
		}
	}
}

func TestStructureDestructivePostgresValidationIgnoresShadowOperatorsLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	f.exec("CREATE TABLE " + f.table("operator_source") + "(id pg_catalog.int4 PRIMARY KEY,amount pg_catalog.numeric(30,4),label pg_catalog.varchar(40) COLLATE pg_catalog.\"C\")")
	f.exec("INSERT INTO " + f.table("operator_source") + " VALUES(1,2147483648.5,'too-long'),(2,12.25,'ok'),(3,NULL,NULL)")
	f.exec("CREATE SEQUENCE " + f.table("operator_calls"))
	sequence := f.schema + ".operator_calls"
	for _, spec := range []struct{ name, argument, result, body string }{
		{"shadow_numeric", "pg_catalog.numeric,pg_catalog.numeric", "pg_catalog.bool", "false"},
		{"shadow_integer", "pg_catalog.int4,pg_catalog.int4", "pg_catalog.bool", "false"},
		{"shadow_negative", "pg_catalog.numeric", "pg_catalog.numeric", "'0'::pg_catalog.numeric"},
	} {
		f.exec("CREATE FUNCTION " + f.table(spec.name) + "(" + spec.argument + ") RETURNS " + spec.result + " LANGUAGE plpgsql VOLATILE AS $$BEGIN PERFORM pg_catalog.nextval('" + sequence + "'::pg_catalog.regclass); RETURN " + spec.body + "; END$$")
	}
	for _, operator := range []string{"<", ">", "<>", ">="} {
		f.exec("CREATE OPERATOR " + f.schema + "." + operator + " (LEFTARG=pg_catalog.numeric,RIGHTARG=pg_catalog.numeric,FUNCTION=" + f.table("shadow_numeric") + ")")
	}
	f.exec("CREATE OPERATOR " + f.schema + ".> (LEFTARG=pg_catalog.int4,RIGHTARG=pg_catalog.int4,FUNCTION=" + f.table("shadow_integer") + ")")
	f.exec("CREATE OPERATOR " + f.schema + ".- (RIGHTARG=pg_catalog.numeric,FUNCTION=" + f.table("shadow_negative") + ")")
	if _, err := f.conn.Exec(ctx, "SET search_path TO "+`"`+f.schema+`"`+",pg_catalog"); err != nil {
		t.Fatal("fixture search path setup failed")
	}
	var beforePath string
	if f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('search_path')").Scan(&beforePath) != nil {
		t.Fatal("fixture search path unavailable")
	}
	var lt, gt, neq, ge, length bool
	var negative string
	if f.conn.QueryRow(ctx, "SELECT '1'::pg_catalog.numeric < '2'::pg_catalog.numeric,'2'::pg_catalog.numeric > '1'::pg_catalog.numeric,'1'::pg_catalog.numeric <> '2'::pg_catalog.numeric,'2'::pg_catalog.numeric >= '1'::pg_catalog.numeric,pg_catalog.char_length('ab') > 1,(-('1'::pg_catalog.numeric))::pg_catalog.text").Scan(&lt, &gt, &neq, &ge, &length, &negative) != nil || lt || gt || neq || ge || length || negative != "0" {
		t.Fatal("unqualified positive control did not resolve the fixture shadow operators")
	}
	var calls int64
	if f.observer.QueryRow(ctx, "SELECT last_value FROM "+f.table("operator_calls")).Scan(&calls) != nil || calls != 6 {
		t.Fatal("shadow operator positive control did not execute the fixture routines")
	}
	target := tableedit.Target{Schema: f.schema, Table: "operator_source"}
	for i, change := range []tableedit.ColumnChange{
		{Name: "amount", Type: &tableedit.DataType{Kind: "integer"}},
		{Name: "amount", Type: &tableedit.DataType{Kind: "numeric", Precision: 5, Scale: 1}},
		{Name: "label", Type: &tableedit.DataType{Kind: "varchar", Length: 3}},
	} {
		store := &tableedit.Store{}
		b, err := store.Load(ctx, s, target)
		if err != nil {
			t.Fatal("shadowed search path prevented metadata loading")
		}
		p, err := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{change}})
		if err != nil {
			t.Fatal("shadowed search path prevented metadata-only Preview")
		}
		validation, err := store.Validate(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: fmt.Sprintf("shadow-validation-%d", i)})
		expected := "1"
		if i < 2 {
			expected = "2"
		}
		if err != nil || validation.Validation == nil {
			t.Fatalf("shadow validation %d failed before an outcome", i)
		}
		if validation.Validation.State != "completed" {
			t.Fatalf("shadow validation %d did not complete", i)
		}
		if len(validation.Validation.Checks) != 1 || validation.Validation.Checks[0].State != "failed" {
			t.Fatalf("shadow validation %d did not retain a failing representability check", i)
		}
		if validation.Validation.Checks[0].InvalidRows == nil || *validation.Validation.Checks[0].InvalidRows != expected {
			t.Fatalf("shadow validation %d did not retain the expected builtin invalid-row count", i)
		}
	}
	var afterCalls int64
	if f.observer.QueryRow(ctx, "SELECT last_value FROM "+f.table("operator_calls")).Scan(&afterCalls) != nil || afterCalls != calls {
		t.Fatal("Preview or validation executed a user-defined shadow operator")
	}
	var afterPath string
	if f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('search_path')").Scan(&afterPath) != nil || afterPath != beforePath || s.TransactionStatus() != "idle" {
		t.Fatal("validation changed the session search path or left a transaction open")
	}
}
