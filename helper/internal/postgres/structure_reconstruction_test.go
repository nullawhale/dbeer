package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"io"
	"strings"
	"testing"
)

func pgE4Draft(order ...string) tableedit.Draft {
	return tableedit.Draft{AuthoringVersion: 5, AllowDestructive: true, Columns: []tableedit.Column{}, ColumnOrder: order, Reconstruct: true}
}
func TestStructureReconstructionAndPhysicalOrderLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	ctx := context.Background()
	target := tableedit.Target{Schema: f.schema, Table: "physical"}
	f.exec("CREATE TABLE " + f.table("physical") + " (id integer CONSTRAINT physical_pk PRIMARY KEY, value text, amount numeric(30,8), flag boolean, CONSTRAINT physical_unique UNIQUE(value))")
	f.exec("CREATE INDEX physical_amount ON " + f.table("physical") + " (amount)")
	f.exec("INSERT INTO " + f.table("physical") + " VALUES (1,'',9007199254740993.12345678,true),(2,NULL,NULL,false),(3,'NULL',-0.00000001,NULL)")
	store := &tableedit.Store{}
	b, e := store.Load(ctx, s, target)
	if e != nil {
		t.Fatal(e)
	}
	p, e := store.PreviewContext(ctx, s, b.Baseline.ID, pgE4Draft("flag", "amount", "value", "id"))
	if e != nil {
		t.Fatal(e)
	}
	if p.Plan.Reconstruction == nil || len(p.Plan.SQL) < 6 {
		t.Fatal("missing real retained-object reconstruction")
	}
	out, e := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "physical"})
	if e != nil || out.Outcome.State != "applied" {
		t.Fatalf("reconstruction failed: %v %+v", e, out.Outcome)
	}
	for _, x := range out.Outcome.Steps {
		if x.Message != "" {
			t.Fatal(x.Message)
		}
	}
	var value, amount string
	if e = f.observer.QueryRow(ctx, "SELECT value,amount::text FROM "+f.table("physical")+" WHERE id=1").Scan(&value, &amount); e != nil || value != "" || amount != "9007199254740993.12345678" {
		t.Fatal("exact retained values lost")
	}
	var count int
	if e = f.observer.QueryRow(ctx, "SELECT count(*) FROM "+f.table("physical")).Scan(&count); e != nil || count != 3 {
		t.Fatal("multiplicity lost")
	}
	if _, e = f.observer.Exec(ctx, "INSERT INTO "+f.table("physical")+" (id,value) VALUES(1,'duplicate')"); e == nil {
		t.Fatal("primary constraint lost")
	}
	if _, e = f.observer.Exec(ctx, "INSERT INTO "+f.table("physical")+" (id,value) VALUES(4,'NULL')"); e == nil {
		t.Fatal("unique constraint lost")
	}
}
func TestStructureReconstructionRejectsUnpreservableDependenciesLive(t *testing.T) {
	for _, object := range []string{"view", "incoming", "sequence", "acl", "comment", "default-privileges", "column-stats"} {
		t.Run(object, func(t *testing.T) {
			f := newChangeFixture(t)
			s := &Session{conn: f.conn}
			f.exec("CREATE TABLE " + f.table("physical") + " (id integer PRIMARY KEY, value text)")
			switch object {
			case "view":
				f.exec("CREATE VIEW " + f.table("dependent") + " AS SELECT id FROM " + f.table("physical"))
			case "incoming":
				f.exec("CREATE TABLE " + f.table("child") + " (id integer REFERENCES " + f.table("physical") + "(id))")
			case "sequence":
				f.exec("ALTER TABLE " + f.table("physical") + " ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY")
			case "acl":
				f.exec("GRANT SELECT ON " + f.table("physical") + " TO PUBLIC")
			case "comment":
				f.exec("COMMENT ON TABLE " + f.table("physical") + " IS 'retained'")
			case "default-privileges":
				f.exec("ALTER DEFAULT PRIVILEGES IN SCHEMA " + strings.TrimSuffix(f.table("sentinel"), `."sentinel"`) + " GRANT SELECT ON TABLES TO PUBLIC")
			case "column-stats":
				f.exec("ALTER TABLE " + f.table("physical") + " ALTER COLUMN value SET STATISTICS 100")
			}
			b, e := s.StructureLoad(context.Background(), tableedit.Target{Schema: f.schema, Table: "physical"})
			if e != nil {
				t.Fatal(e)
			}
			if _, e = s.StructurePrepare(context.Background(), b, pgE4Draft("value", "id")); e == nil {
				t.Fatal("unproven property accepted")
			}
		})
	}
}
func TestStructureBackfillPreviewPartialFailureCancellationAndUnknownLive(t *testing.T) {
	for _, effect := range []string{"apply", "failed-expression", "cancel", "unknown", "concurrent"} {
		t.Run(effect, func(t *testing.T) {
			f := newChangeFixture(t)
			s := &Session{conn: f.conn}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			f.exec("CREATE TABLE " + f.table("backfill") + " (id integer)")
			f.exec("INSERT INTO " + f.table("backfill") + " VALUES(1),(2)")
			store := &tableedit.Store{}
			b, e := store.Load(ctx, s, tableedit.Target{Schema: f.schema, Table: "backfill"})
			if e != nil {
				t.Fatal(e)
			}
			expression := "id::text || ':required'"
			if effect == "failed-expression" {
				expression = "missing_function(id)"
			}
			d := tableedit.Draft{AuthoringVersion: 5, AllowDestructive: true, Columns: []tableedit.Column{{Name: "required", Type: tableedit.DataType{Kind: "text"}, Default: tableedit.Default{Kind: "none"}}}, Backfills: []tableedit.Backfill{{Column: "required", Expression: expression}}}
			p, e := store.PreviewContext(ctx, s, b.Baseline.ID, d)
			if e != nil || len(p.Plan.SQL) != 3 || !strings.Contains(p.Plan.SQL[1], expression) {
				t.Fatal("preview evaluated or hid expression", e)
			}
			if effect == "cancel" {
				s.afterStructureStep = func(i int) {
					if i == 0 {
						cancel()
					}
				}
			}
			if effect == "unknown" {
				s.afterStructureStep = func(i int) {
					if i == 0 {
						s.structureCommitOverride = func(commit func() error) error {
							if e := commit(); e != nil {
								return e
							}
							return io.ErrUnexpectedEOF
						}
					}
				}
			}
			if effect == "concurrent" {
				f.exec("ALTER TABLE " + f.table("backfill") + " ADD COLUMN concurrent integer")
			}
			apply := tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: effect}
			out, e := store.Apply(ctx, s, apply)
			if e != nil {
				t.Fatal(e)
			}
			want := map[string]string{"apply": "applied", "failed-expression": "partiallyApplied", "cancel": "partiallyApplied", "unknown": "outcomeUnknown", "concurrent": "failed"}[effect]
			if out.Outcome.State != want {
				t.Fatalf("want %s got %+v", want, out.Outcome)
			}
			if _, e = store.Apply(ctx, s, apply); e == nil {
				t.Fatal("execution replayed")
			}
		})
	}
}

func TestStructureReconstructionAtomicFailureCancellationValueProofAndUnknownLive(t *testing.T) {
	for _, effect := range []string{"cancel", "failed-copy", "mutated-copy", "concurrent", "unknown"} {
		t.Run(effect, func(t *testing.T) {
			f := newChangeFixture(t)
			s := &Session{conn: f.conn}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			f.exec("CREATE TABLE " + f.table("atomic") + " (id integer PRIMARY KEY, value text)")
			f.exec("INSERT INTO " + f.table("atomic") + " VALUES(1,'kept'),(2,NULL)")
			store := &tableedit.Store{}
			loaded, e := store.Load(ctx, s, tableedit.Target{Schema: f.schema, Table: "atomic"})
			if e != nil {
				t.Fatal(e)
			}
			preview, e := store.PreviewContext(ctx, s, loaded.Baseline.ID, pgE4Draft("value", "id"))
			if e != nil {
				t.Fatal(e)
			}
			if effect == "cancel" {
				s.afterStructureStep = func(i int) {
					if i == 0 {
						cancel()
					}
				}
			}
			if effect == "failed-copy" {
				s.afterStructureStep = func(i int) {
					if i == 0 {
						temporary := f.table("__dbeer_rebuild_" + loaded.Baseline.Fingerprint[:12])
						if _, e := s.conn.Exec(context.Background(), "ALTER TABLE "+temporary+" ADD CONSTRAINT reject_copy CHECK(false)"); e != nil {
							t.Fatal("fault injection failed")
						}
					}
				}
			}
			if effect == "mutated-copy" {
				s.afterStructureStep = func(i int) {
					if i == 1 {
						temporary := f.table("__dbeer_rebuild_" + loaded.Baseline.Fingerprint[:12])
						if _, e := s.conn.Exec(context.Background(), "UPDATE "+temporary+" SET value='changed' WHERE id=1"); e != nil {
							t.Fatal("fault injection failed")
						}
					}
				}
			}
			if effect == "concurrent" {
				f.exec("ALTER TABLE " + f.table("atomic") + " ADD COLUMN concurrent integer")
			}
			if effect == "unknown" {
				s.structureCommitOverride = func(commit func() error) error {
					if e := commit(); e != nil {
						return e
					}
					return io.ErrUnexpectedEOF
				}
			}
			request := tableedit.Apply{PlanID: preview.Plan.ID, Digest: preview.Plan.Digest, ExecutionID: effect}
			out, e := store.Apply(ctx, s, request)
			if e != nil {
				t.Fatal(e)
			}
			want := map[string]string{"cancel": "cancelled", "failed-copy": "failed", "mutated-copy": "failed", "concurrent": "failed", "unknown": "outcomeUnknown"}[effect]
			if out.Outcome.State != want {
				t.Fatalf("want %s got %+v", want, out.Outcome)
			}
			if effect == "cancel" && (out.Outcome.Steps[0].State != "rolledBack" || out.Outcome.Steps[1].State != "notStarted") {
				t.Fatal("atomic cancellation erased step evidence")
			}
			if effect == "unknown" && !s.conn.IsClosed() {
				t.Fatal("uncertain physical connection was not retired")
			}
			var value string
			if e = f.observer.QueryRow(context.Background(), "SELECT value FROM "+f.table("atomic")+" WHERE id=1").Scan(&value); e != nil || value != "kept" {
				t.Fatal("atomic reconstruction changed retained values")
			}
			if _, e = store.Apply(context.Background(), s, request); e == nil {
				t.Fatal("atomic outcome replayed")
			}
		})
	}
}

func TestStructureReconstructionCustomFastDefaultMetadataNeverInvokesSupportLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	s := &Session{conn: f.conn}
	f.exec("CREATE TYPE " + f.table("missing_opaque"))
	f.exec("CREATE FUNCTION " + f.table("missing_in") + "(cstring) RETURNS " + f.table("missing_opaque") + " AS 'int4in' LANGUAGE internal IMMUTABLE STRICT")
	f.exec("CREATE FUNCTION " + f.table("missing_out") + "(" + f.table("missing_opaque") + ") RETURNS cstring AS 'int4out' LANGUAGE internal IMMUTABLE STRICT")
	f.exec("CREATE TYPE " + f.table("missing_opaque") + "(INPUT=" + f.table("missing_in") + ",OUTPUT=" + f.table("missing_out") + ",INTERNALLENGTH=4,ALIGNMENT=int4,PASSEDBYVALUE)")
	f.exec("CREATE TABLE " + f.table("missing_metadata") + " (id integer)")
	f.exec("INSERT INTO " + f.table("missing_metadata") + " VALUES(1)")
	f.exec("ALTER TABLE " + f.table("missing_metadata") + " ADD COLUMN value " + f.table("missing_opaque") + " DEFAULT '7'")
	f.exec("UPDATE pg_catalog.pg_proc SET prolang=(SELECT oid FROM pg_catalog.pg_language WHERE lanname='plpgsql'),prosrc='BEGIN RAISE EXCEPTION ''owned missing-value output invoked''; END' WHERE pronamespace='" + f.schema + "'::regnamespace AND proname='missing_out'")
	_, err := s.StructureLoad(ctx, tableedit.Target{Schema: f.schema, Table: "missing_metadata"})
	if err == nil || !strings.Contains(err.Error(), "Stored fast-default metadata requires custom type support") {
		t.Fatal("raw missing-value support was evaluated or its prerequisite was hidden")
	}
	var text string
	if err = f.observer.QueryRow(ctx, "SELECT pg_catalog.row_to_json(a)::text FROM pg_catalog.pg_attribute a WHERE a.attrelid=$1::regclass AND a.attname='value'", f.table("missing_metadata")).Scan(&text); err == nil {
		t.Fatal("unsafe output positive control did not invoke support")
	}
}
