package safety

import "testing"

func TestMariaDBLexicalRoutingRetainsConservativeBoundaries(t *testing.T) {
	for _, sql := range []string{"SELECT id FROM `sample` WHERE id=1", "WITH a AS (SELECT 1 AS id) SELECT id FROM a"} {
		if !VisualExplainTarget("mariadb", sql) {
			t.Fatal("native lexical SELECT shape was rejected")
		}
		statements := Classify("mariadb", sql)
		if len(statements) != 1 || statements[0].Kind != Read {
			t.Fatal("native read classification changed")
		}
	}
	for _, sql := range []string{"SELECT 1 /*M! UNION SELECT 2 */", "SELECT 1 /*! UNION SELECT 2 */", "SELECT @x:=1", "SELECT id FROM sample FOR UPDATE", "SELECT 1; DELETE FROM sample"} {
		if VisualExplainTarget("mariadb", sql) {
			t.Fatal("ambiguous/wrapped/locking native query was admitted for Explain")
		}
	}
	if target, ok := ClassifyExplainTarget("mariadb", "UPDATE a JOIN b ON a.id=b.id SET a.id=2"); !ok || !target.MySQLMultiTable || target.Statement != "update" {
		t.Fatal("native multi-table lexical classification changed")
	}
}
