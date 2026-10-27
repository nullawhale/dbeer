package resultsource

import (
	"strings"
	"testing"
)

func TestDirectSelectionsPreserveIdentifiersAndOffsets(t *testing.T) {
	tests := []struct {
		sql, engine, schema, table, alias string
		columns                           []Projection
	}{
		{`SELECT id, label FROM public.items WHERE id >= 2 ORDER BY id DESC LIMIT 20 OFFSET 1`, "postgresql", "public", "items", "", []Projection{{Name: "id"}, {Name: "label"}}},
		{`/* SELECT fake FROM wrong */ SELECT x."ID" AS "Shown", x.label title FROM "Odd Schema"."Odd Table" AS x WHERE (x."ID" IN (1,2))`, "postgresql", "Odd Schema", "Odd Table", "x", []Projection{{Qualifier: "x", Name: "ID", Alias: "Shown"}, {Qualifier: "x", Name: "label", Alias: "title"}}},
		{"SELECT T.* FROM `sample`.`Order``Data` T WHERE T.id = 'literal FROM x; SELECT' ; -- end\n", "mysql", "sample", "Order`Data", "T", []Projection{{Qualifier: "T", Star: true}}},
		{`SELECT ID FROM Sample WHERE note = 'it''s FROM a join'`, "postgresql", "", "sample", "", []Projection{{Name: "id"}}},
		{`SELECT * FROM items`, "postgresql", "", "items", "", []Projection{{Star: true}}},
	}
	for _, test := range tests {
		got, reason := Parse(test.sql, test.engine)
		if reason != "" {
			t.Fatalf("supported selection rejected for %s", test.engine)
		}
		if got.Schema != test.schema || got.Table != test.table || got.Alias != test.alias || len(got.Columns) != len(test.columns) {
			t.Fatal("decoded source identity changed")
		}
		for i, col := range test.columns {
			if got.Columns[i] != col {
				t.Fatal("projection mapping lost alias or qualifier")
			}
		}
		if !strings.HasPrefix(strings.ToUpper(test.sql[got.FromOffset:]), "FROM") || got.TableEnd <= got.FromOffset {
			t.Fatal("rewrite offsets do not refer to original SQL bytes")
		}
	}
}

func TestAmbiguousAndSideEffectingSelectionsStayReadOnly(t *testing.T) {
	tests := []string{
		`SELECT id`, `SELECT DISTINCT id FROM t`, `WITH q AS (SELECT * FROM t) SELECT * FROM q`,
		`SELECT t.* FROM t JOIN u ON t.id=u.id`, `SELECT * FROM t,u`, `SELECT * FROM t UNION SELECT * FROM u`,
		`SELECT id+1 FROM t`, `SELECT id::text FROM t`, `SELECT count(*) FROM t`, `SELECT (id) FROM t`,
		`SELECT id,id FROM t WHERE EXISTS (SELECT 1 FROM u)`, `SELECT * FROM t WHERE id=(SELECT id FROM u)`,
		`SELECT * FROM t WHERE touch_database(id)=1`, `SELECT * FROM t WHERE "touch_database"(id)=1`,
		`SELECT * FROM t WHERE id=nextval('seq')`, `SELECT * FROM t ORDER BY random()`,
		`SELECT * FROM t FOR UPDATE`, `SELECT * FROM ONLY t`, `SELECT * FROM t TABLESAMPLE SYSTEM(1)`,
		`SELECT * INTO copied FROM t`, `SELECT * FROM t; DELETE FROM t`, `SELECT * FROM t;;`,
		`SELECT * FROM t LIMIT 1 LIMIT 2`, `SELECT * FROM t ORDER BY id WHERE id=1`,
		`SELECT * FROM t WHERE (id=1`, `SELECT * FROM t WHERE id=1)`,
		`SELECT * FROM t /* unterminated`, `SELECT * FROM t WHERE id=1 /*+ hint */`,
		`SELECT t.id FROM u`, `SELECT t.id FROM t AS u`, `SELECT schema.t.id FROM schema.t`,
		`SELECT * FROM t WHERE id=$1`, `SELECT * FROM t WHERE note=E'unsafe\'quote'`,
		`SELECT * FROM t WHERE id=1 /*! UNION SELECT 1 */`,
	}
	for _, sql := range tests {
		for _, engine := range []string{"postgresql", "mysql"} {
			if _, reason := Parse(sql, engine); reason == "" {
				t.Fatalf("unsafe source shape accepted (%s): %s", engine, sql)
			}
		}
	}
}

func TestDialectAmbiguitiesAndLimitsAreRefused(t *testing.T) {
	mysql := []string{`SELECT "id" FROM t`, `SELECT id FROM "t"`, `SELECT * FROM t WHERE s='a\b'`, `SELECT * FROM t --not_a_comment`, `SELECT * FROM t /* outer /* inner */ outer */`}
	for _, sql := range mysql {
		if _, reason := Parse(sql, "mysql"); reason == "" {
			t.Fatal("mode-sensitive MySQL source accepted")
		}
	}
	for _, sql := range []string{`SELECT * FROM ` + "`t`", "SELECT * FROM t\x00", "SELECT * FROM t WHERE " + strings.Repeat("(", 65) + "id=1" + strings.Repeat(")", 65), strings.Repeat(" ", maxSQLBytes) + `SELECT * FROM t`} {
		if _, reason := Parse(sql, "postgresql"); reason == "" {
			t.Fatal("invalid or unbounded PostgreSQL source accepted")
		}
	}
	if _, reason := Parse(`SELECT * FROM t`, "mongodb"); reason == "" {
		t.Fatal("document engine accepted SQL provenance")
	}
}

func FuzzSelectionDoesNotPanic(f *testing.F) {
	for _, sql := range []string{`SELECT * FROM t`, `SELECT id AS name FROM "schema"."t" WHERE id IN (1,2)`, `SELECT * FROM t /* unclosed`, `SELECT * FROM t; SELECT * FROM u`} {
		f.Add(sql)
	}
	f.Fuzz(func(t *testing.T, sql string) {
		for _, engine := range []string{"postgresql", "mysql"} {
			selection, reason := Parse(sql, engine)
			if reason == "" && (selection.Table == "" || len(selection.Columns) == 0 || selection.FromOffset < 0 || selection.FromOffset >= len(sql) || selection.TableEnd > len(sql)) {
				t.Fatal("accepted source has invalid structural bounds")
			}
		}
	})
}
