package safety

import "testing"

func TestVisualExplainTargetIsOneUnwrappedRead(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql"} {
		for _, sql := range []string{"SELECT 1;", "/* EXPLAIN DELETE */ SELECT ';'", "SELECT count(*) FROM sample", "WITH sample AS (SELECT 1) SELECT * FROM sample", "SELECT fixture_unknown()", "SELECT * FROM sample a JOIN sample b ON a.id=b.id"} {
			if !VisualExplainTarget(engine, sql) {
				t.Errorf("rejected supported shape %s: %s", engine, sql)
			}
		}
		for _, sql := range []string{"SELECT 1; SELECT 2", "SELECT 1;;", "EXPLAIN SELECT 1", "(SELECT 1)", "SELECT * FROM sample FOR UPDATE", "SELECT * FROM sample LOCK IN SHARE MODE", "SELECT 1 INTO sample", "WITH changed AS (DELETE FROM sample RETURNING *) SELECT * FROM changed", "SELECT $1", "SELECT :value", "SELECT 1 /* unterminated", "EXECUTE prepared", "DELETE FROM sample", "WITH x AS (SELECT 1) TABLE x"} {
			if VisualExplainTarget(engine, sql) {
				t.Errorf("accepted unsupported %s: %s", engine, sql)
			}
		}
	}
	if !VisualExplainTarget("postgresql", "SELECT payload ? 'field' FROM sample") {
		t.Fatal("JSON operator rejected")
	}
	if VisualExplainTarget("mysql", "SELECT ?") || VisualExplainTarget("mysql", "SELECT @value") {
		t.Fatal("MySQL parameters/variables accepted")
	}
	if VisualExplainTarget("postgresql", "SELECT nextval('sample')") {
		t.Fatal("known side effect")
	}
	if VisualExplainTarget("mysql", "SELECT last_insert_id(1)") {
		t.Fatal("known side effect")
	}
}
