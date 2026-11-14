package mysql

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"testing"
)

func TestStructureAutoIncrementReplacementRequiresSurvivingLeadingKey(t *testing.T) {
	b := tableedit.Baseline{Facts: &tableedit.Facts{Table: sc.Table{Columns: sc.Complete([]sc.Column{{Ref: sc.Ref{Name: "id"}, Identity: sc.Known(sc.Identity{Kind: "autoIncrement"})}})}}, Indexes: []tableedit.Index{{Name: "PRIMARY", Owner: "PRIMARY", Columns: []string{"id"}, Supported: true}}}
	d := tableedit.Draft{Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{{Action: "replace", Kind: "primary", Name: "PRIMARY", Columns: []string{"id", "other"}}}, AllowDestructive: true}
	if _, _, err := mysqlAuthoredDraft(b, d); err == nil {
		t.Fatal("sole AUTO_INCREMENT key replacement produced a failing drop prefix")
	}
	b.Indexes = append(b.Indexes, tableedit.Index{Name: "explicit_support", Columns: []string{"id"}, Supported: true})
	if _, _, err := mysqlAuthoredDraft(b, d); err != nil {
		t.Fatal("explicit surviving leading key did not permit replacement")
	}
}
