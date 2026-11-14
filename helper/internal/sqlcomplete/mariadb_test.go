package sqlcomplete

import (
	"strings"
	"testing"
)

func TestMariaDBCompletionUsesNativeLexicalIdentityAndFunctions(t *testing.T) {
	context := Context{Engine: "mariadb", Catalog: []Relation{{Schema: "fixture", Name: "Order`Data", Kind: "table", Columns: []string{"MixedCase", "payload"}}}}
	if got := qualifiedName(context.Catalog[0], context.Engine); got != "`fixture`.`Order``Data`" {
		t.Fatal("native identifier quote or original spelling changed")
	}
	for _, text := range []string{"SELECT `t`.", "SELECT t."} {
		sql := text + " FROM `fixture`.`Order``Data` t"
		items := Complete(sql, len(text), context)
		if item, ok := itemWithLabel(items, "MixedCase"); !ok || !strings.Contains(item.InsertText, "`MixedCase`") {
			t.Fatal("native quoted catalog member completion unavailable")
		}
	}
	names := functions("mariadb")
	if !containsMariaDBName(names, "JSON_QUERY") || !containsMariaDBName(names, "INET6_ATON") || containsMariaDBName(names, "JSONB_BUILD_OBJECT") || containsMariaDBName(names, "GENERATE_SERIES") {
		t.Fatal("native function list leaked another engine model")
	}
	help := Signatures("SELECT JSON_EXTRACT('{\"a\":1}', ", len("SELECT JSON_EXTRACT('{\"a\":1}', "), context)
	if help == nil || len(help.Signatures) == 0 || !strings.Contains(help.Signatures[0].Label, "JSON text") {
		t.Fatal("native text-backed JSON signature was lost")
	}
	if got := builtinSignatures("JSON_QUERY", "mysql"); len(got) != 0 {
		t.Fatal("MariaDB-only registry branch changed MySQL signatures")
	}
}
func containsMariaDBName(names []string, want string) bool {
	for _, name := range names {
		if name == want {
			return true
		}
	}
	return false
}
func TestMariaDBEditorKeepsNativeCommentsAndOpaqueProcedures(t *testing.T) {
	for _, sql := range []string{"SELECT 1 # native comment\nFROM `t`", "SELECT 'a\\b', `name``quoted` FROM t", "SELECT 1 /*M! + 2 */"} {
		if d := Diagnostics(sql, "mariadb"); len(d) != 0 {
			t.Fatal("native lexical rules produced false diagnostics")
		}
		if _, err := FormatEditor(sql, "mariadb", FormatOptions{TabSize: 2, InsertSpaces: true}); err != nil {
			t.Fatal("native editor formatting rejected balanced SQL")
		}
	}
	procedure := "DELIMITER $$\nCREATE PROCEDURE p() BEGIN SELECT 1; END$$\nDELIMITER ;"
	formatted, err := FormatEditor(procedure, "mariadb", FormatOptions{TabSize: 2, InsertSpaces: true})
	if err == nil || formatted != "" {
		t.Fatal("opaque native client delimiter script was rewritten")
	}
}
