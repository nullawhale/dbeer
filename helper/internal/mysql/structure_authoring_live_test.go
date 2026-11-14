package mysql

import (
	"context"
	"errors"
	"fmt"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"io"
	"os"
	"testing"
	"time"

	"dbeer/helper/internal/tableedit"
)

func TestStructureGeneratedAndAutoIncrementAuthoringLive(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s := integrationSession(t)
	observer := integrationSession(t)
	settings := integrationSettings(t)
	ctx := context.Background()
	store := &tableedit.Store{}
	name := fmt.Sprintf("e1_generated_%d", time.Now().UnixNano())
	table := QuoteIdentifier(settings.Database) + "." + QuoteIdentifier(name)
	defer run(t, s, "DROP TABLE IF EXISTS "+table)
	seven := "7"
	expr := "UUID_SHORT()"
	d := tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{
		{Name: "id", Type: tableedit.DataType{Kind: "integer"}, Nullable: false, Default: tableedit.Default{Kind: "none"}, Identity: &tableedit.Identity{Kind: "autoIncrement"}},
		{Name: "base", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "numeric", Value: &seven}},
		{Name: "doubled", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}, Generated: &tableedit.Generation{Storage: "stored", Expression: "base * 2"}},
		{Name: "token", Type: tableedit.DataType{Kind: "bigint"}, Nullable: true, Default: tableedit.Default{Kind: "expression", Value: &expr}},
	}, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "primary", Name: "PRIMARY", Columns: []string{"id"}}}}
	target := tableedit.Target{Schema: settings.Database, Table: name, Create: true}
	b, e := store.Load(ctx, s, target)
	if e != nil {
		t.Fatal(e)
	}
	before, e := observer.work.client.Execute("SELECT UUID_SHORT()")
	if e != nil {
		t.Fatal(e)
	}
	previous, _ := before.GetUint(0, 0)
	before.Close()
	p, e := store.PreviewContext(ctx, s, b.Baseline.ID, d)
	if e != nil {
		t.Fatal(e)
	}
	after, e := observer.work.client.Execute("SELECT UUID_SHORT()")
	if e != nil {
		t.Fatal(e)
	}
	next, _ := after.GetUint(0, 0)
	after.Close()
	if next != previous+1 {
		t.Fatal("Preview evaluated the authored default")
	}
	if len(p.Plan.SQL) != 3 {
		t.Fatal("AUTO_INCREMENT did not retain its explicit supporting-key step")
	}
	out, e := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "generation"})
	if e != nil || out.Outcome.State != "applied" {
		t.Fatal("generated/identity authoring failed")
	}
	for _, step := range out.Outcome.Steps {
		if step.Message != "" {
			t.Fatalf("generation/identity preservation failed: %s", step.Message)
		}
	}
	run(t, s, "INSERT INTO "+table+" () VALUES()")
	values, e := observer.work.client.Execute("SELECT id,doubled,token FROM " + table)
	if e != nil {
		t.Fatal(e)
	}
	id, _ := values.GetInt(0, 0)
	generated, _ := values.GetInt(0, 1)
	token, _ := values.GetUint(0, 2)
	values.Close()
	if id != 1 || generated != 14 || token != next+1 {
		t.Fatal("authored values did not retain their requested semantics")
	}
	target.Create = false
	b, e = store.Load(ctx, s, target)
	if e != nil {
		t.Fatal(e)
	}
	d = tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "doubled", Generated: &tableedit.Generation{Storage: "stored", Expression: "base * 3"}}}}
	p, e = store.PreviewContext(ctx, s, b.Baseline.ID, d)
	if e != nil {
		t.Fatal(e)
	}
	out, e = store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "generation-edit"})
	if e != nil || out.Outcome.State != "applied" {
		t.Fatal("generation replacement failed")
	}
	for _, step := range out.Outcome.Steps {
		if step.Message != "" {
			t.Fatalf("generation replacement preservation failed: %s", step.Message)
		}
	}
	values, e = observer.work.client.Execute("SELECT doubled FROM " + table)
	if e != nil {
		t.Fatal(e)
	}
	generated, _ = values.GetInt(0, 0)
	values.Close()
	if generated != 21 {
		t.Fatal("stored generation replacement did not update existing data")
	}
}

func TestStructureRenameLostAcknowledgementKeepsOriginalIdentity(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s := integrationSession(t)
	observer := integrationSession(t)
	ctx := context.Background()
	store := &tableedit.Store{}
	schema := integrationSettings(t).Database
	original := fmt.Sprintf("rename_unknown_%d", time.Now().UnixNano())
	name := original + "_destination"
	run(t, observer, "CREATE TABLE "+QuoteIdentifier(original)+"(id INT)")
	defer run(t, observer, "DROP TABLE IF EXISTS "+QuoteIdentifier(original)+","+QuoteIdentifier(name))
	target := tableedit.Target{Schema: schema, Table: original}
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal(err)
	}
	d := tableedit.Draft{AuthoringVersion: 2, RenameTable: &name, Columns: []tableedit.Column{{Name: "added", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}}
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, d)
	if err != nil {
		t.Fatal(err)
	}
	s.afterStructureStep = func(i int) {
		if i == 0 {
			s.structureExecuteOverride = func(execute func() error) error {
				if err := execute(); err != nil {
					return err
				}
				return io.ErrUnexpectedEOF
			}
		}
	}
	r := tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "rename-unknown"}
	out, err := store.Apply(ctx, s, r)
	s.afterStructureStep = nil
	s.structureExecuteOverride = nil
	if err != nil || out.Outcome.ExecutionID != r.ExecutionID || out.Outcome.State != "outcomeUnknown" || out.Outcome.Steps[0].State != "applied" || out.Outcome.Steps[1].State != "unknown" || p.Plan.Target != target || p.Plan.ResultTarget == nil || p.Plan.ResultTarget.Table != name {
		t.Fatal("rename rewrote original execution identity or unknown history")
	}
	if _, err = store.Apply(ctx, s, r); err == nil {
		t.Fatal("uncertain rename replayed")
	}
	if _, err = store.Load(ctx, observer, *p.Plan.ResultTarget); err != nil {
		t.Fatal("explicit resulting-target reconciliation failed")
	}
	if store.Status().Outcome.State != "outcomeUnknown" {
		t.Fatal("reconciliation rewrote historical acknowledgement")
	}
}

func TestStructureExactAccentNamesCannotBindShadowTables(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s := integrationSession(t)
	schema := integrationSettings(t).Database
	prefix := fmt.Sprintf("structure_exact_%d_", time.Now().UnixNano())
	names := []string{prefix + "é", prefix + "e"}
	defer run(t, s, "DROP TABLE IF EXISTS "+QuoteIdentifier(names[0])+","+QuoteIdentifier(names[1]))
	run(t, s, "CREATE TABLE "+QuoteIdentifier(names[0])+"(accent_value INT COMMENT 'exact',accent_other INT)")
	run(t, s, "CREATE TABLE "+QuoteIdentifier(names[1])+"(shadow_value INT COMMENT 'shadow')")
	for i, name := range names {
		b, err := s.StructureLoad(context.Background(), tableedit.Target{Schema: schema, Table: name})
		if err != nil {
			t.Fatal(err)
		}
		want := "accent_value"
		count := 2
		if i == 1 {
			want = "shadow_value"
			count = 1
		}
		if len(b.Columns) != count || b.Columns[0].Name != want || b.Facts == nil || b.Facts.Table.Ref.Name != name {
			t.Fatal("accent-folded metadata bound a different physical table")
		}
	}
}

func TestStructureAuthoredExpressionModesPreserveSlotBoundaries(t *testing.T) {
	for _, mode := range []string{"", "ANSI_QUOTES,NO_BACKSLASH_ESCAPES"} {
		t.Run(mode, func(t *testing.T) {
			s := integrationSession(t)
			ctx := context.Background()
			store := &tableedit.Store{}
			name := fmt.Sprintf("expression_modes_%d", time.Now().UnixNano())
			schema := integrationSettings(t).Database
			defer run(t, s, "DROP TABLE IF EXISTS "+QuoteIdentifier(name))
			run(t, s, "SET SESSION sql_mode='"+mode+"'")
			b, err := store.Load(ctx, s, tableedit.Target{Schema: schema, Table: name, Create: true})
			if err != nil {
				t.Fatal(err)
			}
			expression := "concat('a''b;--', 'kept')"
			d := tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{{Name: "value", Type: tableedit.DataType{Kind: "varchar", Length: 40}, Nullable: true, Default: tableedit.Default{Kind: "expression", Value: &expression}}}}
			p, err := store.PreviewContext(ctx, s, b.Baseline.ID, d)
			if mode != "" {
				if err == nil {
					t.Fatal("known MySQL NO_BACKSLASH_ESCAPES parser limitation accepted")
				}
				_, serverErr := s.work.client.Execute("CREATE TABLE " + QuoteIdentifier(name) + "(value varchar(40) DEFAULT (" + expression + "))")
				var failure *wire.MyError
				if !errors.As(serverErr, &failure) || failure.Code != 1064 {
					t.Fatal("actual MySQL parser limitation was not reproduced")
				}
				expression = "concat('safe;--', 'kept')"
				d.Columns[0].Default.Value = &expression
				p, err = store.PreviewContext(ctx, s, b.Baseline.ID, d)
			}
			if err != nil {
				t.Fatal(err)
			}
			out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "expression-mode"})
			if err != nil || out.Outcome.State != "applied" {
				t.Fatalf("expression default acknowledgement: state=%s steps=%v", out.Outcome.State, out.Outcome.Steps)
			}
			if out.Outcome.Steps[0].Message != "" {
				t.Fatal("expression default catalog preservation differs")
			}
			run(t, s, "INSERT INTO "+QuoteIdentifier(name)+" () VALUES()")
			result, err := s.work.client.Execute("SELECT value FROM " + QuoteIdentifier(name))
			if err != nil {
				t.Fatal(err)
			}
			got, _ := ownedStructureString(result, 0, 0)
			result.Close()
			want := "a'b;--kept"
			if mode != "" {
				want = "safe;--kept"
			}
			if got != want {
				t.Fatal("authored expression escaped its slot or lost literal bytes")
			}
		})
	}
}

func TestStructureRenameRejectsExternalTriggerDependency(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s := integrationSession(t)
	ctx := context.Background()
	schema := integrationSettings(t).Database
	prefix := fmt.Sprintf("external_trigger_%d", time.Now().UnixNano())
	target, other, trigger := prefix+"_parent", prefix+"_other", prefix+"_trigger"
	defer run(t, s, "DROP TABLE IF EXISTS "+QuoteIdentifier(other)+","+QuoteIdentifier(target))
	run(t, s, "CREATE TABLE "+QuoteIdentifier(target)+"(id INT)")
	run(t, s, "CREATE TABLE "+QuoteIdentifier(other)+"(id INT)")
	run(t, s, "CREATE TRIGGER "+QuoteIdentifier(trigger)+" AFTER INSERT ON "+QuoteIdentifier(other)+" FOR EACH ROW INSERT INTO "+QuoteIdentifier(target)+" VALUES(NEW.id)")
	defer run(t, s, "DROP TRIGGER IF EXISTS "+QuoteIdentifier(trigger))
	store := &tableedit.Store{}
	b, err := store.Load(ctx, s, tableedit.Target{Schema: schema, Table: target})
	if err != nil {
		t.Fatal(err)
	}
	name := prefix + "_renamed"
	if _, err = store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 2, RenameTable: &name, Columns: []tableedit.Column{}}); err == nil {
		t.Fatal("rename ignored a trigger attached to another table")
	}
	run(t, s, "INSERT INTO "+QuoteIdentifier(other)+" VALUES(7)")
	rows, err := s.work.client.Execute("SELECT COUNT(*) FROM " + QuoteIdentifier(target))
	if err != nil {
		t.Fatal(err)
	}
	count, _ := rows.GetInt(0, 0)
	rows.Close()
	if count != 1 {
		t.Fatal("rejected rename changed trigger behavior")
	}
}

func TestStructureExistingAutoIncrementZeroEffectsRequireReview(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	for _, preserveZero := range []bool{false, true} {
		t.Run(fmt.Sprint(preserveZero), func(t *testing.T) {
			s := integrationSession(t)
			ctx := context.Background()
			store := &tableedit.Store{}
			name := fmt.Sprintf("identity_zero_%d", time.Now().UnixNano())
			defer run(t, s, "DROP TABLE IF EXISTS "+QuoteIdentifier(name))
			if preserveZero {
				run(t, s, "SET SESSION sql_mode=CONCAT(@@sql_mode,',NO_AUTO_VALUE_ON_ZERO')")
			}
			run(t, s, "CREATE TABLE "+QuoteIdentifier(name)+"(id INT NOT NULL PRIMARY KEY)")
			run(t, s, "INSERT INTO "+QuoteIdentifier(name)+" VALUES(0)")
			b, err := store.Load(ctx, s, tableedit.Target{Schema: integrationSettings(t).Database, Table: name})
			if err != nil {
				t.Fatal(err)
			}
			p, err := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", Identity: &tableedit.Identity{Kind: "autoIncrement"}}}})
			if err != nil {
				t.Fatal(err)
			}
			if !p.Plan.Destructive {
				t.Fatal("identity value effects bypass explicit policy confirmation")
			}
			out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "identity-zero"})
			if err != nil || out.Outcome.State != "applied" || out.Outcome.Steps[0].Message != "" {
				t.Fatal("reviewed existing-column identity enable failed")
			}
			result, err := s.work.client.Execute("SELECT id FROM " + QuoteIdentifier(name))
			if err != nil {
				t.Fatal(err)
			}
			value, _ := result.GetInt(0, 0)
			result.Close()
			if preserveZero && value != 0 || !preserveZero && value == 0 {
				t.Fatal("actual server zero-value semantics differ from reviewed consequence")
			}
		})
	}
}

func TestStructureAutoIncrementKeyReplacementPrerequisiteLive(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s := integrationSession(t)
	ctx := context.Background()
	store := &tableedit.Store{}
	name := fmt.Sprintf("identity_key_%d", time.Now().UnixNano())
	defer run(t, s, "DROP TABLE IF EXISTS "+QuoteIdentifier(name))
	run(t, s, "CREATE TABLE "+QuoteIdentifier(name)+"(id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,other INT NOT NULL DEFAULT 7)")
	run(t, s, "INSERT INTO "+QuoteIdentifier(name)+" () VALUES()")
	target := tableedit.Target{Schema: integrationSettings(t).Database, Table: name}
	replacement := tableedit.Draft{Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{{Action: "replace", Kind: "primary", Name: "PRIMARY", Columns: []string{"id", "other"}}}, AllowDestructive: true}
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = store.PreviewContext(ctx, s, b.Baseline.ID, replacement); err == nil {
		t.Fatal("sole AUTO_INCREMENT key removal prefix accepted")
	}
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "explicit_support", Columns: []string{"id"}}}})
	if err != nil {
		t.Fatal(err)
	}
	out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "support"})
	if err != nil || out.Outcome.State != "applied" {
		t.Fatal("explicit supporting index failed")
	}
	b, err = store.Load(ctx, s, target)
	if err != nil {
		t.Fatal(err)
	}
	p, err = store.PreviewContext(ctx, s, b.Baseline.ID, replacement)
	if err != nil {
		t.Fatal(err)
	}
	out, err = store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "replacement"})
	if err != nil || out.Outcome.State != "applied" {
		t.Fatal("replacement with surviving supporting key failed")
	}
	for _, step := range out.Outcome.Steps {
		if step.Message != "" {
			t.Fatal("key replacement altered unrelated identity properties")
		}
	}
	run(t, s, "INSERT INTO "+QuoteIdentifier(name)+" () VALUES()")
	result, err := s.work.client.Execute("SELECT COUNT(*),MIN(id),MAX(id) FROM " + QuoteIdentifier(name))
	if err != nil {
		t.Fatal(err)
	}
	count, _ := result.GetInt(0, 0)
	low, _ := result.GetInt(0, 1)
	high, _ := result.GetInt(0, 2)
	result.Close()
	if count != 2 || low != 1 || high != 2 {
		t.Fatal("key replacement changed stored identities or counter progression")
	}
}

func TestStructureRenameUnrelatedColumnPreservesExpressionMetadataLive(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	for _, mode := range []string{"", "ANSI_QUOTES", "ANSI_QUOTES,NO_BACKSLASH_ESCAPES"} {
		for _, kind := range []string{"generated", "default"} {
			t.Run(kind+"/"+mode, func(t *testing.T) {
				s := integrationSession(t)
				ctx := context.Background()
				store := &tableedit.Store{}
				schema := integrationSettings(t).Database
				name := fmt.Sprintf("rename_expression_%d", time.Now().UnixNano())
				resultingName := name + "_renamed"
				table := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
				resultingTable := QuoteIdentifier(schema) + "." + QuoteIdentifier(resultingName)
				defer run(t, s, "DROP TABLE IF EXISTS "+table+","+resultingTable)
				run(t, s, "SET SESSION sql_mode='"+mode+"'")
				definition := "GENERATED ALWAYS AS (`base` * 2) STORED"
				if kind == "default" {
					definition = "DEFAULT (`base` * 2)"
				}
				run(t, s, "CREATE TABLE "+table+" (`id` INT PRIMARY KEY, `base` INT DEFAULT 7, `derived` INT "+definition+", `label` VARCHAR(40) DEFAULT (concat('id','kept')))")
				run(t, s, "INSERT INTO "+table+" (`id`) VALUES (7)")
				b, err := store.Load(ctx, s, tableedit.Target{Schema: schema, Table: name})
				if err != nil {
					t.Fatal(err)
				}
				renamedBase := "renamed_base"
				d := tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "base", RenameTo: &renamedBase}}}
				if _, err = store.PreviewContext(ctx, s, b.Baseline.ID, d); err == nil {
					t.Fatal("referenced column rename was accepted without explicit expression repair")
				}
				renamedID := "renamed_id"
				d = tableedit.Draft{AuthoringVersion: 2, RenameTable: &resultingName, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", RenameTo: &renamedID}}}
				p, err := store.PreviewContext(ctx, s, b.Baseline.ID, d)
				if err != nil {
					t.Fatalf("unrelated-column rename Preview failed: %v", err)
				}
				if p.Plan.Target.Table != name || p.Plan.ResultTarget == nil || p.Plan.ResultTarget.Table != resultingName {
					t.Fatal("rename changed original review identity")
				}
				out, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "expression-rename"})
				if err != nil || out.Outcome.State != "applied" {
					t.Fatal("unrelated expression rename did not apply")
				}
				for _, step := range out.Outcome.Steps {
					if step.State != "applied" || step.Message != "" {
						t.Fatal("expression metadata did not survive rename verification")
					}
				}
				values, err := s.work.client.Execute("SELECT `renamed_id`,`derived`,`label` FROM " + resultingTable)
				if err != nil {
					t.Fatal(err)
				}
				id, _ := values.GetInt(0, 0)
				derived, _ := values.GetInt(0, 1)
				label, _ := values.GetString(0, 2)
				values.Close()
				if id != 7 || derived != 14 || label != "idkept" {
					t.Fatal("rename altered stored or generated values")
				}
			})
		}
	}
}
