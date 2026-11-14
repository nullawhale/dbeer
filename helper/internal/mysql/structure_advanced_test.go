package mysql

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"fmt"
	"os"
	"testing"
	"time"
)

func TestStructureAdvancedMySQLLive(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s := integrationSession(t)
	settings := integrationSettings(t)
	ctx := context.Background()
	store := &tableedit.Store{}
	for _, kind := range []string{"MyISAM", "Partitions"} {
		t.Run(kind, func(t *testing.T) {
			name := fmt.Sprintf("e7_%s_%d", kind, time.Now().UnixNano())
			target := tableedit.Target{Schema: settings.Database, Table: name}
			table := QuoteIdentifier(target.Schema) + "." + QuoteIdentifier(name)
			engine := " ENGINE=MyISAM"
			tail := ""
			if kind == "Partitions" {
				engine = " ENGINE=InnoDB"
				tail = " PARTITION BY RANGE(id) (PARTITION p0 VALUES LESS THAN (100) COMMENT 'lower retained',PARTITION p1 VALUES LESS THAN MAXVALUE COMMENT 'upper retained')"
			}
			run(t, s, "CREATE TABLE "+table+"(id int,payload varchar(50) COMMENT 'retained column',n decimal(30,4),b varbinary(4), KEY retained_idx(n))"+engine+" COMMENT='retained table'"+tail)
			defer func() {
				run(t, s, "DROP TABLE IF EXISTS "+QuoteIdentifier(target.Schema)+"."+QuoteIdentifier(target.Table))
			}()
			run(t, s, "INSERT INTO "+table+" VALUES (1,'',12345678901234567890.1234,0x00ff),(101,'NULL',NULL,NULL)")
			apply := func(d tableedit.Draft) {
				t.Helper()
				b, e := store.Load(ctx, s, target)
				if e != nil || b.Baseline.Advanced == nil {
					t.Fatalf("advanced load: %v", e)
				}
				p, e := store.PreviewContext(ctx, s, b.Baseline.ID, d)
				if e != nil {
					t.Fatal(e)
				}
				o, e := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
				if e != nil || o.Outcome.State != "applied" {
					t.Fatalf("advanced apply failed: %v state=%s", e, o.Outcome.State)
				}
				for _, step := range o.Outcome.Steps {
					if step.Message != "" {
						t.Fatal(step.Message)
					}
				}
			}
			literal := "NULL"
			apply(tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "payload", Default: &tableedit.Default{Kind: "text", Value: &literal}}}})
			apply(tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{{Name: "new_local", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}})
			to := "renamed_payload"
			apply(tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "payload", RenameTo: &to}}})
			required := false
			apply(tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: to, Nullable: &required}}})
			apply(tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "e7_payload_idx", Definition: &tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: &to}}}}}})

			apply(tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "new_local", Type: &tableedit.DataType{Kind: "bigint"}}}})
			uniqueColumns := []string{"id"}
			if kind == "Partitions" {
				uniqueColumns = append(uniqueColumns, to)
			}
			apply(tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "unique", Name: "e7_unique", Columns: uniqueColumns}}})
			apply(tableedit.Draft{AuthoringVersion: 4, AllowDestructive: true, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "new_local", Drop: true}}})
			b, e := store.Load(ctx, s, target)
			if e != nil {
				t.Fatal(e)
			}
			badName := "renamed_key"
			if kind == "Partitions" {
				if _, e = store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", RenameTo: &badName}}}); e == nil {
					t.Fatal("partition-key rename bypassed unchanged-suffix proof")
				}
			}
			b, e = store.Load(ctx, s, target)
			if e != nil {
				t.Fatal(e)
			}
			p, e := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: to, Default: &tableedit.Default{Kind: "none"}}}})
			if e != nil {
				t.Fatal(e)
			}
			run(t, s, "ALTER TABLE "+table+" COMMENT='drifted native suffix'")
			o, e := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
			if e != nil || o.Outcome.State != "failed" || o.Outcome.Steps[0].State != "notStarted" {
				t.Fatal("late native suffix drift dispatched DDL")
			}
			renamed := name + "_renamed"
			apply(tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, RenameTable: &renamed})
			target.Table = renamed
			rows, e := s.work.client.Execute("SELECT id," + QuoteIdentifier(to) + ",CAST(n AS CHAR),HEX(b) FROM " + QuoteIdentifier(target.Schema) + "." + QuoteIdentifier(target.Table) + " ORDER BY id")
			if e != nil {
				t.Fatal("cannot read preserved rows")
			}
			defer rows.Close()
			if rows.RowNumber() != 2 {
				t.Fatal("advanced row count changed")
			}
			v, _ := ownedStructureString(rows, 0, 1)
			n, _ := ownedStructureString(rows, 0, 2)
			binary, _ := ownedStructureString(rows, 0, 3)
			if v != "" || n != "12345678901234567890.1234" || binary != "00FF" {
				t.Fatal("native values changed")
			}
		})
	}
}
