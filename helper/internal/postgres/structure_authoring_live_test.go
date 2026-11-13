package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"io"
	"reflect"
	"strconv"
	"testing"

	"dbeer/helper/internal/tableedit"
)

func authoringApply(t *testing.T, s *Session, store *tableedit.Store, target tableedit.Target, d tableedit.Draft) *tableedit.Outcome {
	t.Helper()
	ctx := context.Background()
	b, e := store.Load(ctx, s, target)
	if e != nil {
		t.Fatal(e)
	}
	p, e := store.PreviewContext(ctx, s, b.Baseline.ID, d)
	if e != nil {
		t.Fatal(e)
	}
	out, e := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
	if e != nil {
		t.Fatal(e)
	}
	if out.Outcome.State != "applied" || out.Outcome.Observed == nil {
		t.Fatalf("authoring acknowledgement/observation mismatch: state=%s steps=%v refresh=%s", out.Outcome.State, out.Outcome.Steps, out.Outcome.RefreshError)
	}
	for _, step := range out.Outcome.Steps {
		if step.Message != "" {
			t.Fatalf("authoring preservation stopped: %s", step.Message)
		}
	}
	return out.Outcome
}

func TestStructureAuthoredGenerationAndIdentityLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	start, increment, cache, n := "10", "2", "3", "7"
	target := tableedit.Target{Schema: f.schema, Table: "authored", Create: true}
	d := tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{
		{Name: "id", Type: tableedit.DataType{Kind: "integer"}, Nullable: false, Default: tableedit.Default{Kind: "none"}, Identity: &tableedit.Identity{Kind: "always", Start: &start, Increment: &increment, Cache: &cache}},
		{Name: "base", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "numeric", Value: &n}},
		{Name: "doubled", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}, Generated: &tableedit.Generation{Storage: "stored", Expression: "base * 2"}},
	}}
	authoringApply(t, s, store, target, d)
	f.exec("INSERT INTO " + f.table(target.Table) + " DEFAULT VALUES")
	var id, value int
	if f.observer.QueryRow(context.Background(), "SELECT id,doubled FROM "+f.table(target.Table)).Scan(&id, &value) != nil || id != 10 || value != 14 {
		t.Fatal("generated/identity values did not retain authored semantics")
	}
	target.Create = false
	var version int
	if f.conn.QueryRow(context.Background(), "SELECT pg_catalog.current_setting('server_version_num')::int").Scan(&version) != nil {
		t.Fatal("cannot read server version")
	}
	expectedValue := 14
	if version >= 170000 {
		authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "doubled", Generated: &tableedit.Generation{Storage: "stored", Expression: "base * 3"}}}})
		expectedValue = 21
	}
	increment, cache = "3", "5"
	authoringApply(t, s, store, target, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", Identity: &tableedit.Identity{Kind: "byDefault", Increment: &increment, Cache: &cache}}}})
	if f.observer.QueryRow(context.Background(), "SELECT doubled FROM "+f.table(target.Table)).Scan(&value) != nil || value != expectedValue {
		t.Fatal("generation replacement did not preserve stored rows")
	}
}

func TestStructureTypeReferenceAndPreviewDoesNotAdvanceSequenceLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	f.exec("CREATE TYPE " + f.table("mood") + " AS ENUM('quiet','active')")
	f.exec("CREATE DOMAIN " + f.table("amount") + " AS integer CHECK(VALUE>=0)")
	f.exec("CREATE SEQUENCE " + f.table("preview_probe"))
	f.exec("CREATE TABLE " + f.table("typed") + "(id integer)")
	f.exec("INSERT INTO " + f.table("typed") + " VALUES(1)")
	expression := "nextval('" + f.schema + ".preview_probe'::regclass)"
	d := tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{
		{Name: "mood", Type: tableedit.DataType{Kind: "reference", Reference: &tableedit.TypeReference{Schema: f.schema, Name: "mood"}}, Nullable: true, Default: tableedit.Default{Kind: "none"}},
		{Name: "amount", Type: tableedit.DataType{Kind: "reference", Reference: &tableedit.TypeReference{Schema: f.schema, Name: "amount"}}, Nullable: true, Default: tableedit.Default{Kind: "none"}},
		{Name: "generated_value", Type: tableedit.DataType{Kind: "bigint"}, Nullable: true, Default: tableedit.Default{Kind: "expression", Value: &expression}},
	}}
	b, e := store.Load(ctx, s, tableedit.Target{Schema: f.schema, Table: "typed"})
	if e != nil {
		t.Fatal(e)
	}
	p, e := store.PreviewContext(ctx, s, b.Baseline.ID, d)
	if e != nil {
		t.Fatal(e)
	}
	var called bool
	if f.observer.QueryRow(ctx, "SELECT is_called FROM "+f.table("preview_probe")).Scan(&called) != nil || called {
		t.Fatal("Preview evaluated the authored default")
	}
	out, e := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "type-proof"})
	if e != nil || out.Outcome.State != "applied" {
		t.Fatal("typed/default authoring failed")
	}
	for _, step := range out.Outcome.Steps {
		if step.Message != "" {
			t.Fatalf("typed/default preservation failed: %s", step.Message)
		}
	}
	if f.observer.QueryRow(ctx, "SELECT is_called FROM "+f.table("preview_probe")).Scan(&called) != nil || !called {
		t.Fatal("Apply did not evaluate the explicitly reviewed default")
	}
}

func TestStructureCustomTypeDriftStopsBeforeDDL(t *testing.T) {
	for _, mutate := range []string{"alter", "recreate"} {
		t.Run(mutate, func(t *testing.T) {
			f := newChangeFixture(t)
			ctx := context.Background()
			s := &Session{conn: f.conn}
			store := &tableedit.Store{}
			f.exec("CREATE TYPE " + f.table("mood") + " AS ENUM('quiet')")
			f.exec("CREATE TABLE " + f.table("typed") + "(id integer)")
			target := tableedit.Target{Schema: f.schema, Table: "typed"}
			b, err := store.Load(ctx, s, target)
			if err != nil {
				t.Fatal(err)
			}
			d := tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{{Name: "mood", Type: tableedit.DataType{Kind: "reference", Reference: &tableedit.TypeReference{Schema: f.schema, Name: "mood"}}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}}
			p, err := store.PreviewContext(ctx, s, b.Baseline.ID, d)
			if err != nil {
				t.Fatal(err)
			}
			if mutate == "alter" {
				f.exec("ALTER TYPE " + f.table("mood") + " ADD VALUE 'active'")
			} else {
				f.exec("DROP TYPE " + f.table("mood"))
				f.exec("CREATE TYPE " + f.table("mood") + " AS ENUM('quiet')")
			}
			out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "stale-type"})
			if err != nil || len(out.Outcome.Steps) != 1 || out.Outcome.Steps[0].State != "notStarted" {
				t.Fatal("changed custom type reached DDL dispatch")
			}
			current, err := s.StructureLoad(ctx, target)
			if err != nil || len(current.Columns) != 1 {
				t.Fatal("stale type intent changed the table")
			}
		})
	}
}

func TestStructureVirtualGenerationVersionBoundaryLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: f.schema, Table: "virtual_authored", Create: true}
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal(err)
	}
	d := tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{
		{Name: "base", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}},
		{Name: "derived", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}, Generated: &tableedit.Generation{Storage: "virtual", Expression: "base * 2"}},
	}}
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, d)
	var version int
	if f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('server_version_num')::int").Scan(&version) != nil {
		t.Fatal("cannot read server version")
	}
	if version < 180000 {
		if err == nil {
			t.Fatal("pre-18 server accepted virtual generation")
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "virtual"})
	if err != nil || out.Outcome.State != "applied" || out.Outcome.Steps[0].Message != "" {
		t.Fatal("PostgreSQL 18 virtual generation failed preservation")
	}
	f.exec("INSERT INTO " + f.table(target.Table) + "(base) VALUES(6)")
	var result int
	if f.observer.QueryRow(ctx, "SELECT derived FROM "+f.table(target.Table)).Scan(&result) != nil || result != 12 {
		t.Fatal("virtual generation changed semantics")
	}
}

func TestStructureDomainPreviewNeverRunsUserFunctions(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	f.exec("CREATE SEQUENCE " + f.table("domain_probe"))
	f.exec("CREATE FUNCTION " + f.table("domain_check") + "(integer) RETURNS boolean LANGUAGE plpgsql VOLATILE AS $$ BEGIN PERFORM nextval('" + f.schema + ".domain_probe'::regclass); RETURN true; END $$")
	f.exec("CREATE DOMAIN " + f.table("authored_domain") + " AS integer DEFAULT 7 CHECK(" + f.table("domain_check") + "(VALUE))")
	f.exec("CREATE TABLE " + f.table("domain_table") + "(id integer)")
	f.exec("INSERT INTO " + f.table("domain_table") + " VALUES(1)")
	b, err := store.Load(ctx, s, tableedit.Target{Schema: f.schema, Table: "domain_table"})
	if err != nil {
		t.Fatal(err)
	}
	d := tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{{Name: "checked", Type: tableedit.DataType{Kind: "reference", Reference: &tableedit.TypeReference{Schema: f.schema, Name: "authored_domain"}}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}}
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, d)
	if err != nil {
		t.Fatal(err)
	}
	var called bool
	if f.observer.QueryRow(ctx, "SELECT is_called FROM "+f.table("domain_probe")).Scan(&called) != nil || called {
		t.Fatal("Preview invoked a user-defined domain function")
	}
	out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "domain-functions"})
	if err != nil || out.Outcome.State != "applied" || out.Outcome.Steps[0].Message != "" {
		t.Fatal("resolved domain default/check properties were lost")
	}
	if f.observer.QueryRow(ctx, "SELECT is_called FROM "+f.table("domain_probe")).Scan(&called) != nil || !called {
		t.Fatal("Apply did not execute the reviewed domain constraint")
	}
}

func TestStructureGenerationReplacementVersionBoundaryLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	f.exec("CREATE TABLE " + f.table("generation_boundary") + "(base integer,derived integer GENERATED ALWAYS AS(base*2) STORED)")
	f.exec("INSERT INTO " + f.table("generation_boundary") + "(base) VALUES(6)")
	b, err := store.Load(ctx, s, tableedit.Target{Schema: f.schema, Table: "generation_boundary"})
	if err != nil {
		t.Fatal(err)
	}
	d := tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "derived", Generated: &tableedit.Generation{Storage: "stored", Expression: "base * 3"}}}}
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, d)
	var version int
	if f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('server_version_num')::int").Scan(&version) != nil {
		t.Fatal("cannot read server version")
	}
	if version < 170000 {
		if err == nil {
			t.Fatal("pre-17 server accepted generation replacement")
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "generation-boundary"})
	if err != nil || out.Outcome.State != "applied" || out.Outcome.Steps[0].Message != "" {
		t.Fatal("supported generation replacement failed preservation")
	}
	var result int
	if f.observer.QueryRow(ctx, "SELECT derived FROM "+f.table("generation_boundary")).Scan(&result) != nil || result != 18 {
		t.Fatal("generation replacement changed semantics")
	}
}

func TestStructureRenameLostAcknowledgementKeepsOriginalIdentity(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	f.exec("CREATE TABLE " + f.table("rename_original") + "(id integer)")
	target := tableedit.Target{Schema: f.schema, Table: "rename_original"}
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal(err)
	}
	name := "rename_destination"
	d := tableedit.Draft{AuthoringVersion: 2, RenameTable: &name, Columns: []tableedit.Column{{Name: "added", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}}
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, d)
	if err != nil {
		t.Fatal(err)
	}
	s.afterStructureStep = func(i int) {
		if i == 0 {
			s.structureCommitOverride = func(commit func() error) error {
				if err := commit(); err != nil {
					return err
				}
				return io.ErrUnexpectedEOF
			}
		}
	}
	r := tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "rename-unknown"}
	out, err := store.Apply(ctx, s, r)
	s.afterStructureStep = nil
	s.structureCommitOverride = nil
	if err != nil || out.Outcome.ExecutionID != r.ExecutionID || out.Outcome.State != "outcomeUnknown" || out.Outcome.Steps[0].State != "applied" || out.Outcome.Steps[1].State != "unknown" || p.Plan.Target != target || p.Plan.ResultTarget == nil || p.Plan.ResultTarget.Table != name {
		t.Fatal("rename rewrote original execution identity or unknown history")
	}
	if _, err = store.Apply(ctx, s, r); err == nil {
		t.Fatal("uncertain rename replayed")
	}
	if _, err = store.Load(ctx, s, *p.Plan.ResultTarget); err != nil {
		t.Fatal("explicit resulting-target reconciliation failed")
	}
	if store.Status().Outcome.State != "outcomeUnknown" {
		t.Fatal("reconciliation rewrote historical acknowledgement")
	}
}

func TestStructurePreviewNeverInvokesCustomTypmodOutput(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TYPE " + f.table("opaque"))
	f.exec("CREATE FUNCTION " + f.table("opaque_in") + "(cstring) RETURNS " + f.table("opaque") + " AS 'int4in' LANGUAGE internal IMMUTABLE STRICT")
	f.exec("CREATE FUNCTION " + f.table("opaque_out") + "(" + f.table("opaque") + ") RETURNS cstring AS 'int4out' LANGUAGE internal IMMUTABLE STRICT")
	f.exec("CREATE FUNCTION " + f.table("opaque_mod_in") + "(cstring[]) RETURNS integer AS 'numerictypmodin' LANGUAGE internal IMMUTABLE STRICT")
	f.exec("CREATE FUNCTION " + f.table("opaque_mod_out") + "(integer) RETURNS cstring AS 'numerictypmodout' LANGUAGE internal VOLATILE STRICT")
	f.exec("CREATE TYPE " + f.table("opaque") + " (INPUT=" + f.table("opaque_in") + ",OUTPUT=" + f.table("opaque_out") + ",INTERNALLENGTH=4,ALIGNMENT=int4,PASSEDBYVALUE,TYPMOD_IN=" + f.table("opaque_mod_in") + ",TYPMOD_OUT=" + f.table("opaque_mod_out") + ")")
	f.exec("CREATE TYPE " + f.table("compound") + " AS (member " + f.table("opaque") + "(7,2))")
	f.exec("CREATE DOMAIN " + f.table("domain_probe") + " AS " + f.table("opaque") + "(7,2)")
	f.exec("CREATE TABLE " + f.table("observed") + "(probe " + f.table("opaque") + "(7,2))")
	// A disposable superuser-only catalog probe models a raising C support routine
	// without compiling/loading native code or invoking it during fixture creation.
	f.exec("UPDATE pg_catalog.pg_proc SET prolang=(SELECT oid FROM pg_catalog.pg_language WHERE lanname='plpgsql'),prosrc='BEGIN RAISE EXCEPTION ''owned support function executed''; END' WHERE pronamespace='" + f.schema + "'::regnamespace AND proname='opaque_mod_out'")
	tx, err := f.conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	var typeOID uint32
	var mod int32
	for _, name := range []string{"compound", "domain_probe"} {
		if _, err = resolveStructureType(ctx, tx, tableedit.TypeReference{Schema: f.schema, Name: name}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = readStructure(ctx, tx, tableedit.Target{Schema: f.schema, Table: "observed"}); err != nil {
		t.Fatal(err)
	}
	if tx.QueryRow(ctx, `SELECT a.atttypid,a.atttypmod FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_class c ON c.oid=a.attrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname='observed' AND a.attname='probe'`, f.schema).Scan(&typeOID, &mod) != nil {
		t.Fatal("cannot read opaque modifier")
	}
	var display string
	if tx.QueryRow(ctx, `SELECT pg_catalog.format_type($1::oid,$2::int)`, typeOID, mod).Scan(&display) == nil {
		t.Fatal("custom formatter positive control did not execute its raising function")
	}
}

func TestStructureUnsafeDefaultCheckAndFunctionMetadataRetainsRawProof(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TYPE " + f.table("opaque"))
	f.exec("CREATE FUNCTION " + f.table("opaque_in") + "(cstring) RETURNS " + f.table("opaque") + " AS 'int4in' LANGUAGE internal IMMUTABLE STRICT")
	f.exec("CREATE FUNCTION " + f.table("opaque_out") + "(" + f.table("opaque") + ") RETURNS cstring AS 'int4out' LANGUAGE internal IMMUTABLE STRICT")
	f.exec("CREATE TYPE " + f.table("opaque") + " (INPUT=" + f.table("opaque_in") + ",OUTPUT=" + f.table("opaque_out") + ",INTERNALLENGTH=4,ALIGNMENT=int4,PASSEDBYVALUE)")
	f.exec("CREATE FUNCTION " + f.table("opaque_eq") + "(" + f.table("opaque") + "," + f.table("opaque") + ") RETURNS boolean AS 'int4eq' LANGUAGE internal IMMUTABLE STRICT")
	f.exec("CREATE OPERATOR " + f.schema + ".= (LEFTARG=" + f.table("opaque") + ",RIGHTARG=" + f.table("opaque") + ",FUNCTION=" + f.table("opaque_eq") + ")")
	condition := "probe OPERATOR(" + f.schema + ".=) '7'::" + f.table("opaque")
	f.exec("CREATE TABLE " + f.table("unsafe_metadata") + "(id integer,probe " + f.table("opaque") + " DEFAULT '7'::" + f.table("opaque") + ",CHECK(" + condition + "))")
	f.exec("CREATE DOMAIN " + f.table("unsafe_domain") + " AS " + f.table("opaque") + " CHECK(VALUE OPERATOR(" + f.schema + ".=) '7'::" + f.table("opaque") + ")")
	f.exec("CREATE FUNCTION " + f.table("sql_support") + "(arg " + f.table("opaque") + " DEFAULT '7'::" + f.table("opaque") + ") RETURNS integer LANGUAGE sql BEGIN ATOMIC RETURN 1; END")
	f.exec("UPDATE pg_catalog.pg_proc SET prolang=(SELECT oid FROM pg_catalog.pg_language WHERE lanname='plpgsql'),prosrc='BEGIN RAISE EXCEPTION ''owned output function executed''; END' WHERE pronamespace='" + f.schema + "'::regnamespace AND proname='opaque_out'")
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: f.schema, Table: "unsafe_metadata"}
	loaded, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal(err)
	}
	before := loaded.Baseline
	if before.Facts == nil || len(before.Facts.RawExpressions) < 2 {
		t.Fatal("unsafe default/CHECK raw proof was lost")
	}
	old, ok := tableedit.FindColumn(*before, "probe")
	if !ok || old.Default.Value == nil || old.Default.Value.Expression == nil || old.Default.Value.Expression.Dependencies.Code != "customTypeSupport" {
		t.Fatal("unsafe default was not explicitly unavailable")
	}
	drop := tableedit.Default{Kind: "none"}
	if _, err = store.PreviewContext(ctx, s, before.ID, tableedit.Draft{Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "probe", Default: &drop}}}); err == nil {
		t.Fatal("unavailable custom-support change produced executable SQL")
	}
	p, err := store.PreviewContext(ctx, s, before.ID, tableedit.Draft{Columns: []tableedit.Column{{Name: "safe_added", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}})
	if err != nil {
		t.Fatal(err)
	}
	out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "raw-preservation"})
	if err != nil || out.Outcome.State != "applied" || out.Outcome.Steps[0].Message != "" {
		t.Fatal("safe append failed to preserve unavailable raw metadata")
	}
	guard, err := resolveStructureType(ctx, f.conn, tableedit.TypeReference{Schema: f.schema, Name: "unsafe_domain"})
	if err == nil || len(guard.RawExpressions) == 0 || guard.Identity == "" {
		t.Fatal("selected unsafe domain did not retain explicit unavailable raw proof")
	}
	var functionOID uint32
	if f.conn.QueryRow(ctx, `SELECT p.oid FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=$1 AND p.proname='sql_support'`, f.schema).Scan(&functionOID) != nil {
		t.Fatal("cannot find owned SQL support fixture")
	}
	r := &schemaCapture{ctx: ctx, tx: f.conn, skipCustomTypeFormatting: true, spec: sc.CaptureSpec{Limits: sc.Limits{Nodes: 128, Members: 1024, Bytes: 1 << 20, Scalar: 65536}}}
	fn, err := r.typeFunction(strconv.FormatUint(uint64(functionOID), 10), "probe")
	if err != nil || fn == nil {
		t.Fatal("raw SQL support metadata capture failed")
	}
	properties := map[string]string{}
	for _, property := range fn.Properties.Items {
		properties[property.Name] = property.Value
	}
	if properties["sqlBodyEncoding"] != "catalogNodeTree" || properties["sqlBody"] == "" || properties["argumentDefaults"] == "" {
		t.Fatal("SQL body/argument default raw proof was not retained")
	}
	for _, query := range []string{
		`SELECT pg_catalog.pg_get_expr(d.adbin,d.adrelid,false) FROM pg_catalog.pg_attrdef d JOIN pg_catalog.pg_class c ON c.oid=d.adrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname='unsafe_metadata'`,
		`SELECT pg_catalog.pg_get_expr(k.conbin,k.conrelid,false) FROM pg_catalog.pg_constraint k JOIN pg_catalog.pg_namespace n ON n.oid=k.connamespace WHERE n.nspname=$1 AND k.contype='c' LIMIT 1`,
	} {
		var text string
		if f.observer.QueryRow(ctx, query, f.schema).Scan(&text) == nil {
			t.Fatal("unsafe deparser positive control did not reach raising support")
		}
	}
	var definition string
	if f.observer.QueryRow(ctx, `SELECT pg_catalog.pg_get_functiondef($1::oid)`, functionOID).Scan(&definition) == nil {
		t.Fatal("function-definition positive control did not reach default output support")
	}
	f.exec("ALTER TABLE " + f.table("unsafe_metadata") + " ALTER COLUMN probe SET DEFAULT '8'::" + f.table("opaque"))
	changed, err := s.StructureLoad(ctx, target)
	if err != nil || changed.Fingerprint == out.Outcome.Observed.Fingerprint || reflect.DeepEqual(changed.Facts.RawExpressions, out.Outcome.Observed.Facts.RawExpressions) {
		t.Fatal("changed unavailable raw metadata did not invalidate private proof")
	}
}
