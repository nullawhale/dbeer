package safety

import (
	"strings"
	"testing"
)

func TestClassifySQL(t *testing.T) {
	tests := []struct {
		name, engine, sql string
		want              Kind
	}{
		{"select", "postgresql", "SELECT 1", Read},
		{"ordinary select", "postgresql", "SELECT u.id, u.name FROM public.users u WHERE u.id > 1 ORDER BY name LIMIT 20", Read},
		{"strings", "postgresql", "SELECT 'DELETE; DROP TABLE t', 'a'';b', $$; UPDATE x$$, $tag$COPY a FROM STDIN$tag$", Read},
		{"escape string", "postgresql", `SELECT E'escaped\';DELETE FROM t;'`, Read},
		{"quoted identifiers", "postgresql", `SELECT "DROP", "with"."delete" FROM "table;name"`, Read},
		{"nested comments", "postgresql", "/* DROP t; /* UPDATE t; */ */ SELECT 1 -- DELETE;\n", Read},
		{"comments between tokens", "postgresql", "SELECT/* hi */count/* hi */(*) FROM x", Read},
		{"quoted function unknown", "postgresql", `SELECT "count"(*) FROM t`, Unknown},
		{"aggregate", "postgresql", "SELECT count(*), min(x), sum(x) FILTER (WHERE x > 1) FROM t", Read},
		{"window", "postgresql", "SELECT row_number() OVER (PARTITION BY x ORDER BY y) FROM t", Read},
		{"expression group", "postgresql", "SELECT (1 + 2), CASE WHEN (id = 1) THEN 'a' ELSE 'b' END FROM t", Read},
		{"cast modifiers", "postgresql", "SELECT CAST('1.23' AS DECIMAL(10,2)), NULL::numeric(5,2), now()::timestamp(0)", Read},
		{"cast unknown modifier", "postgresql", "SELECT CAST(1 AS decimal(mutate_database()))", Unknown},
		{"subquery alias columns", "postgresql", "SELECT * FROM (VALUES (1)) AS t(id)", Read},
		{"subquery", "postgresql", "SELECT x FROM (SELECT id AS x FROM t) s WHERE EXISTS (SELECT 1 FROM u)", Read},
		{"nested cte", "postgresql", "WITH x AS (WITH y AS (SELECT 1) SELECT * FROM y) SELECT * FROM x", Read},
		{"recursive cte", "postgresql", "WITH RECURSIVE x(n) AS (VALUES (1) UNION ALL SELECT n+1 FROM x WHERE n < 5) SELECT * FROM x", Read},
		{"multiple cte", "postgresql", "WITH a AS MATERIALIZED (SELECT 1), b(id) AS NOT MATERIALIZED (SELECT 2) SELECT * FROM a, b", Read},
		{"writable cte", "postgresql", "WITH changed AS (UPDATE t SET a = 1 WHERE id = 2 RETURNING *) SELECT * FROM changed", Write},
		{"delete cte", "postgresql", "WITH gone AS (DELETE FROM t RETURNING *) SELECT * FROM gone", Destructive},
		{"nested writable cte", "postgresql", "SELECT * FROM (WITH changed AS (DELETE FROM t RETURNING *) SELECT * FROM changed) s", Destructive},
		{"cte then write", "postgresql", "WITH a AS (SELECT 1) INSERT INTO t SELECT * FROM a", Write},
		{"cte then unknown", "postgresql", "WITH a AS (SELECT 1) CALL modify_data()", Unknown},
		{"cte unsupported search", "postgresql", "WITH RECURSIVE a AS (SELECT 1) SEARCH DEPTH FIRST BY id SET path SELECT * FROM a", Unknown},
		{"cte missing body", "postgresql", "WITH x AS SELECT 1 SELECT * FROM x", Unknown},
		{"cte missing statement", "postgresql", "WITH x AS (SELECT 1)", Unknown},
		{"cte malformed columns", "postgresql", "WITH x(a + b) AS (SELECT 1) SELECT * FROM x", Unknown},
		{"select into", "postgresql", "SELECT * INTO temporary_copy FROM t", Write},
		{"select locking", "postgresql", "SELECT * FROM t FOR UPDATE", Write},
		{"select no key locking", "postgresql", "SELECT * FROM t FOR NO KEY UPDATE", Write},
		{"select share locking", "postgresql", "SELECT * FROM t FOR KEY SHARE", Write},
		{"unknown function", "postgresql", "SELECT mutate_database()", Unknown},
		{"nested unknown function", "postgresql", "SELECT coalesce((SELECT mutate_database()), 0)", Unknown},
		{"qualified unknown function", "postgresql", "SELECT public.count(*) FROM t", Unknown},
		{"catalog function", "postgresql", "SELECT pg_catalog.count(*) FROM t", Read},
		{"set config bypass", "postgresql", "SELECT set_config('default_transaction_read_only', 'off', false)", Unknown},
		{"set config qualified bypass", "postgresql", "SELECT pg_catalog.set_config('transaction_read_only', 'off', false)", Unknown},
		{"sequence write", "postgresql", "SELECT nextval('sequence')", Write},
		{"sequence set", "postgresql", "SELECT setval('sequence', 1)", Write},
		{"sleep", "postgresql", "SELECT pg_sleep(1)", Read},
		{"unknown mysql function in pg", "postgresql", "SELECT IF(1,2,3)", Unknown},
		{"insert", "postgresql", "INSERT INTO t VALUES (1)", Write},
		{"update", "postgresql", "UPDATE t SET a = 2 WHERE id = 1", Write},
		{"update all", "postgresql", "UPDATE t SET a = 2", Destructive},
		{"delete", "postgresql", "DELETE FROM t WHERE id = 1", Destructive},
		{"merge", "postgresql", "MERGE INTO t USING u ON t.id = u.id WHEN MATCHED THEN DELETE", Destructive},
		{"create", "postgresql", "CREATE TABLE t (id integer)", Write},
		{"create or replace", "postgresql", "CREATE OR REPLACE VIEW t AS SELECT 1", Destructive},
		{"alter", "postgresql", "ALTER TABLE t DROP COLUMN x", Destructive},
		{"drop", "postgresql", "DROP TABLE t", Destructive},
		{"truncate", "postgresql", "TRUNCATE t", Destructive},
		{"explain", "postgresql", "EXPLAIN SELECT * FROM t", Read},
		{"explain write without execution", "postgresql", "EXPLAIN DELETE FROM t", Read},
		{"explain analyze delete", "postgresql", "EXPLAIN ANALYZE DELETE FROM t", Destructive},
		{"explain options analyze write", "postgresql", "EXPLAIN (BUFFERS, ANALYZE TRUE, FORMAT JSON) UPDATE t SET a=1 WHERE id=2", Write},
		{"explain analyze false", "postgresql", "EXPLAIN (ANALYZE FALSE) DELETE FROM t", Read},
		{"explain analyze zero", "postgresql", "EXPLAIN (ANALYZE 0) DELETE FROM t", Read},
		{"explain unknown option", "postgresql", "EXPLAIN (FUTURE_OPTION) DELETE FROM t", Unknown},
		{"explain unknown query", "postgresql", "EXPLAIN CALL mutate()", Unknown},
		{"explain unknown function", "postgresql", "EXPLAIN SELECT mutate()", Unknown},
		{"copy read", "postgresql", "COPY public.t TO STDOUT WITH CSV HEADER", Read},
		{"copy query read", "postgresql", "COPY (SELECT * FROM t) TO STDOUT WITH (FORMAT CSV)", Read},
		{"copy unknown query", "postgresql", "COPY (SELECT mutate()) TO STDOUT", Unknown},
		{"copy write", "postgresql", "COPY t FROM STDIN", Write},
		{"copy file write", "postgresql", "COPY t TO '/tmp/t.csv'", Write},
		{"copy program unknown", "postgresql", "COPY t FROM PROGRAM 'command'", Unknown},
		{"copy program to unknown", "postgresql", "COPY t TO PROGRAM 'command'", Unknown},
		{"begin", "postgresql", "BEGIN", Read},
		{"begin readonly", "postgresql", "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY", Read},
		{"begin writable", "postgresql", "START TRANSACTION READ WRITE", Write},
		{"begin unknown", "postgresql", "BEGIN ATOMIC INSERT INTO t VALUES (1) END", Unknown},
		{"commit", "postgresql", "COMMIT AND CHAIN", Read},
		{"commit prepared", "postgresql", "COMMIT PREPARED 'txn'", Unknown},
		{"rollback prepared", "postgresql", "ROLLBACK PREPARED 'txn'", Unknown},
		{"rollback savepoint", "postgresql", "ROLLBACK TO SAVEPOINT a", Read},
		{"savepoint", "postgresql", "SAVEPOINT a", Read},
		{"release savepoint", "postgresql", "RELEASE SAVEPOINT a", Read},
		{"set bypass", "postgresql", "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", Unknown},
		{"reset bypass", "postgresql", "RESET ALL", Unknown},
		{"discard bypass", "postgresql", "DISCARD ALL", Unknown},
		{"call", "postgresql", "CALL mutate_database()", Unknown},
		{"do", "postgresql", "DO $$BEGIN DELETE FROM t; END$$", Unknown},
		{"dynamic", "postgresql", "EXECUTE prepared_statement", Unknown},
		{"show", "postgresql", "SHOW default_transaction_read_only", Read},
		{"show time zone", "postgresql", "SHOW TIME ZONE", Read},
		{"mysql strings comments", "mysql", "# delete\n SELECT 'DROP; DELETE', `column;name` FROM `table` -- ;UPDATE t\n", Read},
		{"mysql double quotes", "mysql", `SELECT "DROP;DELETE"`, Read},
		{"mysql hash comment", "mysql", "SELECT 1 # ; DROP t", Read},
		{"mysql double dash arithmetic", "mysql", "SELECT 1--1", Read},
		{"mysql executable comment", "mysql", "SELECT 1 /*! INTO OUTFILE '/tmp/a' */", Unknown},
		{"mysql versioned executable comment", "mysql", "/*!80000 SET transaction_read_only=OFF */ SELECT 1", Unknown},
		{"mysql executable comment separator", "mysql", "SELECT 1 /*!; DELETE FROM t */", Unknown},
		{"mysql hint", "mysql", "SELECT /*+ SET_VAR(sql_mode='') */ 1", Unknown},
		{"mysql cte", "mysql", "WITH x AS (SELECT 1) SELECT * FROM x", Read},
		{"mysql writable cte unsupported", "mysql", "WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x", Unknown},
		{"mysql outfile", "mysql", "SELECT * FROM t INTO OUTFILE '/tmp/t.csv'", Write},
		{"mysql dumpfile", "mysql", "SELECT * FROM t INTO DUMPFILE '/tmp/t.bin'", Write},
		{"mysql locking", "mysql", "SELECT * FROM t LOCK IN SHARE MODE", Write},
		{"mysql assignment", "mysql", "SELECT @a := 1", Write},
		{"mysql variables", "mysql", "SELECT @@session.transaction_read_only, @a", Read},
		{"mysql session function side effect", "mysql", "SELECT LAST_INSERT_ID(42)", Write},
		{"mysql session function read", "mysql", "SELECT LAST_INSERT_ID()", Read},
		{"mysql sleep", "mysql", "SELECT SLEEP(0.05), CONNECTION_ID()", Read},
		{"mysql numeric cast", "mysql", "SELECT CONVERT('1.23', DECIMAL(40,20))", Read},
		{"mysql postgres function unknown", "mysql", "SELECT pg_sleep(1)", Unknown},
		{"mysql replace", "mysql", "REPLACE INTO t VALUES (1)", Destructive},
		{"mysql explain analyze", "mysql", "EXPLAIN ANALYZE SELECT * FROM t", Read},
		{"mysql explain format", "mysql", "EXPLAIN FORMAT=JSON SELECT * FROM t", Read},
		{"mysql show create", "mysql", "SHOW CREATE TABLE t", Read},
		{"mysql show where function", "mysql", "SHOW TABLES WHERE mutate_database()", Unknown},
		{"mysql describe", "mysql", "DESCRIBE t", Read},
		{"mysql begin writable", "mysql", "START TRANSACTION READ WRITE", Write},
		{"mysql begin snapshot", "mysql", "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY", Read},
		{"mysql mode bypass", "mysql", "SET SESSION transaction_read_only = OFF", Unknown},
		{"mysql load write", "mysql", "LOAD DATA INFILE '/tmp/t.csv' INTO TABLE t", Write},
		{"unterminated string", "postgresql", "SELECT 'a", Unknown},
		{"unterminated comment", "postgresql", "SELECT 1 /*", Unknown},
		{"unterminated dollar", "postgresql", "SELECT $tag$a$$", Unknown},
		{"unbalanced group", "postgresql", "SELECT (1", Unknown},
		{"unexpected close", "postgresql", "SELECT 1)", Unknown},
		{"ambiguous pg backslash", "postgresql", `SELECT '\'; DELETE FROM t; --'`, Unknown},
		{"ambiguous mysql backslash", "mysql", `SELECT '\'; DELETE FROM t; --'`, Unknown},
		{"mysql nested comment ambiguous", "mysql", "SELECT 1 /* /* */ DELETE FROM t */", Unknown},
		{"nested semicolon", "postgresql", "SELECT (1; DELETE FROM t)", Unknown},
		{"invalid query suffix", "postgresql", "SELECT 1 DELETE FROM t", Unknown},
		{"unknown keyword", "postgresql", "FUTURE COMMAND x", Unknown},
		{"unknown dialect", "sqlite", "SELECT 1", Unknown},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := Classify(test.engine, test.sql)
			if len(got) != 1 || got[0].Kind != test.want {
				t.Fatalf("Classify(%q) = %#v, want %s", test.sql, got, test.want)
			}
			if got[0].Reason == "" {
				t.Fatal("assessment must have a safe structural reason")
			}
		})
	}
}

func TestClassifyScriptPreservesByteRanges(t *testing.T) {
	sql := "-- before\n SELECT 'κόσμος;'; /* between */ WITH x AS (SELECT 1) DELETE FROM t;\nDROP TABLE t; -- after"
	got := Classify("postgresql", sql)
	wantSQL := []string{"SELECT 'κόσμος;'", "WITH x AS (SELECT 1) DELETE FROM t", "DROP TABLE t"}
	wantKind := []Kind{Read, Destructive, Destructive}
	if len(got) != len(wantSQL) {
		t.Fatalf("got %#v", got)
	}
	for i, part := range got {
		if sql[part.Start:part.End] != wantSQL[i] || part.Kind != wantKind[i] {
			t.Fatalf("part %d = %#v (%q)", i, part, sql[part.Start:part.End])
		}
	}
}

func TestQualifiedKeywordFunctionCannotMasqueradeAsSQLSyntax(t *testing.T) {
	for _, sql := range []string{"SELECT public.left('abc',1)", "SELECT public.right('abc',1)", "SELECT * FROM public.left('abc',1)", "SELECT custom_schema.substring('abc',1)"} {
		for _, engine := range []string{"postgresql", "mysql"} {
			got := Classify(engine, sql)
			if len(got) != 1 || got[0].Kind != Unknown {
				t.Fatalf("qualified keyword function classified as read: %#v", got)
			}
		}
	}
}

func TestParenthesizedReadExpressionsAndNestedSubqueries(t *testing.T) {
	for _, sql := range []string{"SELECT ((1+2))", "SELECT round((price-cost)/price,2) FROM t", "SELECT * FROM t WHERE ((id=1) OR (id=2))", "SELECT * FROM a JOIN b ON ((a.id=b.id) AND (a.x=1))", "SELECT coalesce(((SELECT count(*) FROM t)),0)", "(SELECT 1) UNION ALL (SELECT 2)", "(SELECT 1) UNION ALL SELECT 2", "SELECT * FROM ((SELECT 1) UNION ALL (SELECT 2)) q", "SELECT CASE (id) WHEN 1 THEN 'one' ELSE 'other' END FROM t", "SELECT id BETWEEN (1) AND (2) FROM t", "SELECT name LIKE ('pattern') FROM t"} {
		for _, engine := range []string{"postgresql", "mysql"} {
			got := Classify(engine, sql)
			if len(got) != 1 || got[0].Kind != Read {
				t.Fatalf("read expression treated as unknown query: %q %#v", sql, got)
			}
		}
	}
	for _, sql := range []string{"SELECT ((custom_side_effect()))", "SELECT coalesce(((SELECT custom_side_effect())),0)"} {
		if got := Classify("postgresql", sql); len(got) != 1 || got[0].Kind != Unknown {
			t.Fatal("nested function escaped assessment")
		}
	}
}

func TestReadFunctionsWithStatementKeywordNames(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql"} {
		got := Classify(engine, "SELECT replace(name,'old','new') FROM t")
		if len(got) != 1 || got[0].Kind != Read {
			t.Fatal("REPLACE string function is not a command")
		}
	}
	got := Classify("mysql", "SELECT truncate(1.234,2)")
	if len(got) != 1 || got[0].Kind != Read {
		t.Fatal("TRUNCATE numeric function is not a command")
	}
	for _, sql := range []string{"SELECT array_col[1] FROM t", "SELECT array_col[1:2] FROM t", "SELECT name ILIKE ('pattern') FROM t", "SELECT now() AT TIME ZONE ('UTC')", "SELECT 1 FETCH FIRST (10) ROWS ONLY"} {
		got := Classify("postgresql", sql)
		if len(got) != 1 || got[0].Kind != Read {
			t.Fatalf("ordinary operand treated as function: %q %#v", sql, got)
		}
	}
	if got := Classify("postgresql", "SELECT array_col[custom_side_effect()] FROM t"); len(got) != 1 || got[0].Kind != Unknown {
		t.Fatal("array index effect escaped classification")
	}
}

func TestUnicodeNamesCannotSpoofASCIIKeywordsOrBuiltins(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql"} {
		for _, sql := range []string{"SELECT abſ(1)", "SELECT ſum(1)", "ſELECT 1"} {
			got := Classify(engine, sql)
			if len(got) != 1 || got[0].Kind != Unknown {
				t.Fatalf("Unicode identifier spoofed builtin or keyword: %#v", got)
			}
		}
	}
}

func TestKeywordNamesNeedSyntacticContextBeforeParentheses(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql"} {
		for _, name := range []string{"filter", "zone", "first", "next", "over", "partition", "within", "rollup", "cube", "by", "to", "sets", "join", "inner", "outer", "cross", "full", "like", "ilike", "similar", "is", "on", "from", "where", "having", "limit", "offset", "group"} {
			got := Classify(engine, "SELECT "+name+"(1)")
			if len(got) != 1 || got[0].Kind != Unknown {
				t.Fatalf("keyword-shaped function %s bypassed assessment: %#v", name, got)
			}
		}
	}
	for _, sql := range []string{
		"SELECT sum(x) FILTER (WHERE x>0) OVER (PARTITION BY (group_id) ORDER BY (id)) FROM t",
		"SELECT x FROM t GROUP BY ROLLUP (x)", "SELECT x FROM t GROUP BY x, CUBE (x)",
		"SELECT x FROM t GROUP BY GROUPING SETS ((x),())", "SELECT * FROM t WHERE id IN (1,2)",
		"SELECT x FROM t WHERE x SIMILAR TO ('abc')", "SELECT NOT (false)",
	} {
		got := Classify("postgresql", sql)
		if len(got) != 1 || got[0].Kind != Read {
			t.Fatalf("syntactic operand became an unknown function: %q %#v", sql, got)
		}
	}
	for _, sql := range []string{"SELECT x LIKE (filter(1)) FROM t", "SELECT sum(x) OVER (ORDER BY (filter(1))) FROM t", "SELECT x FROM t GROUP BY ROLLUP (filter(1))"} {
		got := Classify("postgresql", sql)
		if len(got) != 1 || got[0].Kind != Unknown {
			t.Fatal("syntactic context concealed nested unknown function")
		}
	}
}

func TestDialectBuiltinsAndTypeModifiersCannotHideUserFunctions(t *testing.T) {
	for _, test := range []struct{ engine, sql string }{
		{"postgresql", "SELECT schema()"}, {"postgresql", "SELECT coalesce(truncate(1,2),0)"},
		{"mysql", "SELECT trunc(1)"}, {"mysql", "SELECT array(1)"},
		{"postgresql", "SELECT 1,numeric(1)"}, {"mysql", "SELECT 1,numeric(1)"},
		{"postgresql", "SELECT 1,varbinary(1)"}, {"mysql", "SELECT 1,varbinary(1)"},
		{"postgresql", "SELECT 1::varbinary(1)"}, {"mysql", "SELECT CAST(1 AS varbit(1))"},
		{"postgresql", "SELECT coalesce(1,numeric(1))"},
		{"postgresql", "SELECT CONVERT('1.23', numeric(1))"},
	} {
		got := Classify(test.engine, test.sql)
		if len(got) != 1 || got[0].Kind != Unknown {
			t.Fatalf("dialect or type name hid unknown function: %q %#v", test.sql, got)
		}
	}
	for _, test := range []struct{ engine, sql string }{
		{"mysql", "SELECT schema()"}, {"mysql", "SELECT truncate(1.234,2)"},
		{"mysql", "SELECT CONVERT(price*qty,DECIMAL(10,2)) FROM t"},
		{"postgresql", "SELECT trunc(1.234,2)"}, {"postgresql", "SELECT 1::numeric(10,2)"},
		{"postgresql", "SELECT CAST(1 AS numeric(10,2))"},
	} {
		got := Classify(test.engine, test.sql)
		if len(got) != 1 || got[0].Kind != Read {
			t.Fatalf("recognized dialect builtin or type lost read behavior: %q %#v", test.sql, got)
		}
	}
}

func TestDialectOnlyReadFunctionsAreUnknownOnTheOtherEngine(t *testing.T) {
	for name := range postgresReadFunctions {
		if commonReadFunctions[name] || mysqlReadFunctions[name] {
			t.Fatalf("dialect-only name %s is shared", name)
		}
		got := Classify("mysql", "SELECT "+name+"(1)")
		if len(got) != 1 || got[0].Kind != Unknown {
			t.Fatalf("PostgreSQL-only builtin %s authorized on MySQL: %#v", name, got)
		}
	}
	for name := range mysqlReadFunctions {
		if commonReadFunctions[name] || postgresReadFunctions[name] {
			t.Fatalf("dialect-only name %s is shared", name)
		}
		got := Classify("postgresql", "SELECT "+name+"(1)")
		if len(got) != 1 || got[0].Kind != Unknown {
			t.Fatalf("MySQL-only builtin %s authorized on PostgreSQL: %#v", name, got)
		}
	}
}

func TestClassifyEmptySQL(t *testing.T) {
	for _, sql := range []string{"", " \t\n", "-- empty\n/* none */", ";;SELECT 1;;"} {
		got := Classify("postgresql", sql)
		want := 0
		if strings.Contains(sql, "SELECT") {
			want = 1
		}
		if len(got) != want {
			t.Fatalf("Classify(%q) = %#v", sql, got)
		}
	}
}

func TestClassifyLexicalFailureInvalidatesWholeScript(t *testing.T) {
	sql := "SELECT 1; SELECT 'unterminated"
	got := Classify("postgresql", sql)
	if len(got) != 1 || got[0].Start != 0 || got[0].End != len(sql) || got[0].Kind != Unknown {
		t.Fatalf("partial script incorrectly authorized: %#v", got)
	}
}

func TestClassifyBoundsNesting(t *testing.T) {
	got := Classify("postgresql", "SELECT "+strings.Repeat("(", 1000)+"1"+strings.Repeat(")", 1000))
	if len(got) != 1 || got[0].Kind != Unknown {
		t.Fatalf("unbounded nesting = %#v", got)
	}
}

func FuzzClassify(f *testing.F) {
	for _, sql := range []string{"SELECT 1", "WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x", "SELECT ';' /*comment*/;", "SELECT $x$;$x$", "SELECT /*!80000 1 */"} {
		f.Add(sql)
	}
	f.Fuzz(func(t *testing.T, sql string) {
		for _, engine := range []string{"postgresql", "mysql"} {
			for _, statement := range Classify(engine, sql) {
				if statement.Start < 0 || statement.End < statement.Start || statement.End > len(sql) || statement.Kind == "" {
					t.Fatalf("invalid assessment bounds: %#v", statement)
				}
			}
		}
	})
}
