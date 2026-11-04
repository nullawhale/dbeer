package safety

import "testing"

func TestSQLiteAssessment(t *testing.T) {
	for _, c := range []struct {
		sql  string
		kind Kind
	}{
		{`SELECT [drop], ` + "`odd name`" + ` FROM main.t --no-space`, Read},
		{`SELECT 'a\'; DELETE FROM t; --'`, Unknown},
		{`ATTACH DATABASE '/synthetic/extra.sqlite' AS extra`, Write},
		{`DETACH DATABASE extra`, Write},
		{`PRAGMA writable_schema=ON`, Unknown},
		{`SELECT load_extension('x')`, Unknown},
	} {
		got := Classify("sqlite", c.sql)
		found := false
		for _, s := range got {
			if s.Kind == c.kind {
				found = true
			}
		}
		if !found {
			t.Fatalf("SQLite classification mismatch: got %#v want %s", got, c.kind)
		}
	}
	if !VisualExplainTarget("sqlite", `SELECT * FROM main.t`) || VisualExplainTarget("sqlite", `SELECT ?`) {
		t.Fatal("invalid SQLite explain target assessment")
	}
}
