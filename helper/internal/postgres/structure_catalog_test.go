package postgres

import (
	"strings"
	"testing"
)

func TestStructureCatalogOperators(t *testing.T) {
	cases := []struct{ sql, want string }{
		{"SELECT n.oid FROM pg_catalog.pg_namespace n WHERE n.nspname=$1", "N . NSPNAME OPERATOR(pg_catalog.=) $1"},
		{"SELECT count(*),r.* FROM pg_catalog.pg_class r WHERE r.relkind IN ('r','p')", "R . RELKIND OPERATOR(pg_catalog.=) ANY ( ARRAY [ 'r' , 'p' ] )"},
		{"SELECT oid FROM pg_catalog.pg_class WHERE oid NOT IN (SELECT objid FROM pg_catalog.pg_depend WHERE objsubid=0)", "OID OPERATOR(pg_catalog.<>) ALL ( SELECT"},
		{"SELECT CASE WHEN oid=ANY($1::pg_catalog.oid[]) THEN 'a''=IN' ELSE 'OPERATOR(x.=)' END FROM pg_catalog.pg_class", "OID OPERATOR(pg_catalog.=) ANY"},
		{"SELECT a.attstattarget<>-1 FROM pg_catalog.pg_attribute a", "ATTSTATTARGET OPERATOR(pg_catalog.<>) OPERATOR(pg_catalog.-) 1"},
		{"SELECT ((pg_catalog.to_jsonb(c)->>'flag')='x') FROM pg_catalog.pg_class c", "OPERATOR(pg_catalog.->>)"},
		{`SELECT "a=IN" FROM ONLY "s"."t" LIMIT 100001`, `"a=IN"`},
		{"SELECT 1 OPERATOR(pg_catalog.=) ALL(ARRAY[1,2])", "OPERATOR(pg_catalog.=) ALL"},
	}
	for _, tc := range cases {
		actual, ok := pgStructureCatalogSQL(tc.sql)
		if !ok || !strings.Contains(actual, tc.want) {
			t.Fatalf("fixed metadata template was not guarded: %q", tc.want)
		}
		second, ok := pgStructureCatalogSQL(actual)
		if !ok || second != actual {
			t.Fatal("guard must be idempotent for nested catalog readers")
		}
	}
	for _, sql := range []string{
		"SELECT 'x' LIKE 'x'", "SELECT 'x' ILIKE 'x'", "SELECT 1 BETWEEN 0 AND 2", "SELECT NULLIF(1,2)",
		"SELECT CASE 1 WHEN 1 THEN true END", "SELECT 1 IS DISTINCT FROM 2", "SELECT 1 IS NOT DISTINCT FROM 2",
		"SELECT greatest(1,2)", "SELECT 1 OPERATOR(public.=) 2", "SELECT 1; SELECT 2", "SELECT 1 --comment",
		"SELECT /*comment*/ 1", "SELECT $$x$$", "SELECT E'\\x'", "SELECT fn(x=>1)", "UPDATE t SET a=1",
		"SELECT 'unterminated", "SELECT 1 ~ 'x'",
	} {
		if _, ok := pgStructureCatalogSQL(sql); ok {
			t.Fatal("unhandled metadata grammar must fail closed")
		}
	}
}
