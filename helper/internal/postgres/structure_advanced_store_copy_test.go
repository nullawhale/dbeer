package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5"
	"reflect"
	"sort"
	"strings"
	"testing"

	"dbeer/helper/internal/tableedit"
)

func TestStructureAdvancedStoreCopyKindsLive(t *testing.T) {
	for _, mode := range []string{"RLS", "Unlogged", "Traditional", "LocalChild", "PartitionParent", "PartitionLeaf", "SerialWarm", "TypedRefusal", "LatePolicy", "UnknownCommit"} {
		t.Run(mode, func(t *testing.T) {
			f := newChangeFixture(t)
			ctx := context.Background()
			s := &Session{conn: f.conn}
			f.exec("CREATE SEQUENCE " + f.table("trigger_calls"))
			f.exec("CREATE FUNCTION " + f.table("retained_trigger") + "() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN PERFORM pg_catalog.nextval('" + f.table("trigger_calls") + "'::pg_catalog.regclass); RETURN NEW; END$$")
			prefix := "CREATE TABLE "
			if mode == "Unlogged" {
				prefix = "CREATE UNLOGGED TABLE "
			}
			tail := ""
			if strings.HasPrefix(mode, "Partition") {
				tail = " PARTITION BY RANGE(id)"
			}
			columns := "id bigint NOT NULL,payload text DEFAULT 'default',n numeric(30,4),b bytea,g bigint GENERATED ALWAYS AS(id+1) STORED,CONSTRAINT positive CHECK(id>=0)"
			if mode == "TypedRefusal" {
				f.exec("CREATE TYPE " + f.table("bound_type") + " AS(id bigint,payload text,n numeric(30,4),b bytea,g bigint)")
				f.exec("CREATE TABLE " + f.table("parent") + " OF " + f.table("bound_type") + "(id WITH OPTIONS NOT NULL)")
			} else {
				f.exec(prefix + f.table("parent") + "(" + columns + ")" + tail)
			}
			selected := "parent"
			if mode == "Traditional" {
				f.exec("CREATE TABLE " + f.table("child") + "(local_tag text) INHERITS(" + f.table("parent") + ")")
			}
			if mode == "LocalChild" {
				f.exec("CREATE TABLE " + f.table("child") + "(" + columns + ")")
				f.exec("ALTER TABLE " + f.table("child") + " INHERIT " + f.table("parent"))
				selected = "child"
			}
			if tail != "" {
				f.exec("CREATE TABLE " + f.table("child") + " PARTITION OF " + f.table("parent") + " FOR VALUES FROM(0)TO(100)")
				if mode == "PartitionLeaf" {
					selected = "child"
				}
			}
			if mode == "SerialWarm" {
				f.exec("CREATE SEQUENCE " + f.table("owned_seq") + " AS bigint START WITH 9007199254740993 INCREMENT BY 7 CACHE 17 OWNED BY " + f.table("parent") + ".id")
				f.exec("ALTER TABLE " + f.table("parent") + " ALTER COLUMN id SET DEFAULT nextval(" + postgresTextLiteral(f.table("owned_seq")) + "::pg_catalog.regclass)")
				if _, err := f.conn.Exec(ctx, "SELECT pg_catalog.nextval("+postgresTextLiteral(f.table("owned_seq"))+"::pg_catalog.regclass)"); err != nil {
					t.Fatal("owned cache setup failed")
				}
			}
			pgFamilyRichProperties(t, f, "parent")
			if mode == "Traditional" || mode == "LocalChild" || tail != "" {
				pgFamilyRichProperties(t, f, "child")
			}
			if mode == "TypedRefusal" {
				f.exec("INSERT INTO " + f.table("parent") + "(id,payload,n,b,g) VALUES(1,'',12345678901234567890.1234,decode('00ff','hex'),2)")
			} else {
				f.exec("INSERT INTO " + f.table("parent") + "(id,payload,n,b) VALUES(1,'',12345678901234567890.1234,decode('00ff','hex')),(2,'NULL',NULL,NULL),(3,NULL,-123.4000,decode('ff00','hex'))")
			}
			if mode == "Traditional" {
				f.exec("INSERT INTO " + f.table("child") + "(id,payload,n,b,local_tag) VALUES(4,'NULL',99999999999999999999.0001,decode('00ff00','hex'),'same'),(4,'NULL',99999999999999999999.0001,decode('00ff00','hex'),'same'),(5,NULL,NULL,NULL,'')")
			}
			if mode == "LocalChild" {
				f.exec("INSERT INTO " + f.table("child") + "(id,payload,n,b) VALUES(4,'NULL',99999999999999999999.0001,decode('00ff00','hex')),(4,'NULL',99999999999999999999.0001,decode('00ff00','hex')),(5,NULL,NULL,NULL)")
			}
			target := tableedit.Target{Schema: f.schema, Table: selected}
			store := &tableedit.Store{}
			loaded, err := store.Load(ctx, s, target)
			if err != nil {
				t.Fatal(err)
			}
			before := loaded.Baseline
			if before.Advanced == nil || !before.Advanced.Permits("reconstruction") {
				t.Fatal("normal production reconstruction capability missing")
			}
			original := pgAdvancedStoreCopyRows(t, f.observer, before)
			var oldSequence pgAdvancedSequenceValue
			if mode == "SerialWarm" {
				oldSequence = pgFamilyReadSequence(t, s, tableedit.Target{Schema: f.schema, Table: "owned_seq"})
			}
			draft := tableedit.Draft{AuthoringVersion: 5, AllowDestructive: true, Columns: []tableedit.Column{}, ColumnOrder: []string{"payload", "g", "id", "b", "n"}, Reconstruct: true}
			preview, err := store.PreviewContext(ctx, s, before.ID, draft)
			if mode == "TypedRefusal" {
				if err == nil || !strings.Contains(err.Error(), "ALTER TYPE") {
					t.Fatal("typed binding shape was not explicitly refused")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if preview.Plan.Reconstruction == nil || preview.Plan.Reconstruction.Method != "postgresql-advanced-copy" || len(preview.Plan.SQL) < 3 {
				t.Fatal("normal Store did not select the bound generic copy method")
			}
			if _, err = store.Apply(ctx, s, tableedit.Apply{PlanID: preview.Plan.ID, Digest: strings.Repeat("0", 64), ExecutionID: tableedit.Token()}); err == nil {
				t.Fatal("incorrect digest authorized copy")
			}
			if mode == "LatePolicy" {
				f.exec("ALTER POLICY retained ON " + f.table(selected) + " USING(id>1)")
			}
			committed := false
			if mode == "UnknownCommit" {
				s.structureCommitOverride = func(commit func() error) error {
					committed = true
					if err := commit(); err != nil {
						return err
					}
					return errors.New("owned synthetic lost acknowledgement")
				}
			}
			execution := tableedit.Token()
			out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: preview.Plan.ID, Digest: preview.Plan.Digest, ExecutionID: execution})
			if err != nil {
				t.Fatal(err)
			}
			if mode == "UnknownCommit" {
				if !committed || out.Outcome.State != "outcomeUnknown" || s.conn.PgConn().IsClosed() != true {
					t.Fatal("uncertain normal copy did not retire its physical connection")
				}
			} else if mode == "LatePolicy" {
				if out.Outcome.State != "failed" || out.Outcome.Steps[0].State != "notStarted" {
					t.Fatal("late policy drift dispatched normal copy")
				}
			} else {
				if out.Outcome.State != "applied" || out.Outcome.Observed == nil || out.Outcome.Observed.Identity == before.Identity {
					t.Fatalf("normal copy was not positively observed: state=%s steps=%v refresh=%s", out.Outcome.State, out.Outcome.Steps, out.Outcome.RefreshError)
				}
				for _, step := range out.Outcome.Steps {
					if step.State != "applied" || step.Message != "" {
						t.Fatal("normal copy acknowledgement mismatch")
					}
				}
				names := []string{}
				for _, column := range out.Outcome.Observed.Columns {
					names = append(names, column.Name)
				}
				if !reflect.DeepEqual(names, draft.ColumnOrder) {
					t.Fatal("normal copy did not retain the exact reviewed order")
				}
				after := *out.Outcome.Observed
				if !reflect.DeepEqual(original, pgAdvancedStoreCopyRows(t, f.observer, &after)) {
					t.Fatal("normal copy changed retained exact values or duplicates")
				}
				if mode == "SerialWarm" {
					next := pgFamilyReadSequence(t, s, tableedit.Target{Schema: f.schema, Table: "owned_seq"})
					if oldSequence.Value != next.Value || oldSequence.Called != next.Called || oldSequence.Session != next.Session || !reflect.DeepEqual(oldSequence.Definition["class"], next.Definition["class"]) || !reflect.DeepEqual(oldSequence.Definition["sequence"], next.Definition["sequence"]) {
						t.Fatal("normal copy changed native/session cached sequence state")
					}
				}
			}
			if _, err = store.Apply(ctx, s, tableedit.Apply{PlanID: preview.Plan.ID, Digest: preview.Plan.Digest, ExecutionID: tableedit.Token()}); err == nil {
				t.Fatal("normal copy retained replay authority")
			}
		})
	}
}

func pgAdvancedStoreCopyRows(t *testing.T, q structureReader, b *tableedit.Baseline) map[tableedit.Target][][]any {
	t.Helper()
	out := map[tableedit.Target][][]any{}
	for id, facts := range b.AdvancedEvidence.Facts {
		target := tableedit.Target{Schema: facts.Table.Ref.Schema, Table: facts.Table.Ref.Name}
		projection := "id::pg_catalog.text,payload,n::pg_catalog.text,pg_catalog.encode(b,'hex'),g::pg_catalog.text"
		for _, attr := range b.AdvancedEvidence.Rows[id+"/attributes"] {
			if attr["attname"] == "local_tag" {
				projection += ",local_tag"
			}
		}
		rows, err := q.Query(context.Background(), "SELECT "+projection+" FROM ONLY "+pgx.Identifier{target.Schema, target.Table}.Sanitize())
		if err != nil {
			t.Fatal("normal copy retained-value observation unavailable")
		}
		values := [][]any{}
		for rows.Next() {
			row, err := rows.Values()
			if err != nil {
				rows.Close()
				t.Fatal("normal copy retained-value observation invalid")
			}
			values = append(values, row)
		}
		rows.Close()
		if rows.Err() != nil {
			t.Fatal("normal copy retained-value observation incomplete")
		}
		sort.Slice(values, func(i, j int) bool {
			a, _ := json.Marshal(values[i])
			b, _ := json.Marshal(values[j])
			return string(a) < string(b)
		})
		out[target] = values
	}
	return out
}
