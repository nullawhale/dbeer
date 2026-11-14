package mariadb

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"strings"
	"testing"
)

func TestMariaDBPartialStructureRefusesDeferredOperationsBeforeSQL(t *testing.T) {
	facts := newMariaDBStructureFacts("utf8mb4", "utf8mb4_bin")
	facts.Table.Ref = sc.Ref{Kind: "table", Schema: "s", Name: "t"}
	c := definitionNativeColumn("n", "int")
	c.Ref = sc.Ref{Kind: "column", Schema: "s", Table: "t", Name: "n"}
	facts.Table.Columns = sc.Complete([]sc.Column{c})
	b := tableedit.Baseline{Engine: "mariadb", Target: tableedit.Target{Schema: "s", Table: "t"}, Fingerprint: strings.Repeat("a", 64), Facts: facts, Columns: []tableedit.ObservedColumn{}, Keys: []tableedit.Key{}, Indexes: []tableedit.Index{}, Limitations: []string{}}
	tableedit.Summarize(&b)
	if !tableedit.ValidBaseline(b) {
		t.Fatal("invalid partial-scope fixture")
	}
	var cold Session
	for _, d := range []tableedit.Draft{{AuthoringVersion: 4, AllowDestructive: true, DropTable: true}, {AuthoringVersion: 4, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "n", Type: &tableedit.DataType{Kind: "varchar", Length: 20}}}}, {AuthoringVersion: 5, AllowDestructive: true, Reconstruct: true}, {AuthoringVersion: 2, Columns: []tableedit.Column{{Name: "g", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}, Generated: &tableedit.Generation{Storage: "stored", Expression: "1"}}}}, {AuthoringVersion: 2, Columns: []tableedit.Column{{Name: "a", Type: tableedit.DataType{Kind: "bigint"}, Nullable: false, Default: tableedit.Default{Kind: "none"}, Identity: &tableedit.Identity{Kind: "autoIncrement"}}}}, {AuthoringVersion: 2, Changes: []tableedit.ColumnChange{{Name: "n", Generated: &tableedit.Generation{Storage: "stored", Expression: "1"}}}}, {AuthoringVersion: 2, Changes: []tableedit.ColumnChange{{Name: "n", Identity: &tableedit.Identity{Kind: "autoIncrement"}}}}} {
		p, e := cold.StructurePrepare(context.Background(), b, d)
		if e == nil || !strings.Contains(e.Error(), "deferred") || len(p.SQL) > 0 {
			t.Fatal("deferred authoring intent reached native work")
		}
	}
	p, e := cold.StructurePrepareMigration(context.Background(), b, tableedit.Draft{}, nil)
	if e == nil || !strings.Contains(e.Error(), "deferred") || len(p.SQL) > 0 {
		t.Fatal("deferred migration reached native work")
	}
}
