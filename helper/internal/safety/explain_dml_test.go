package safety

import "testing"

func TestExplainDMLClassificationUsesDialectTokens(t *testing.T) {
	for _, item := range []struct {
		engine, sql, statement string
		cte, multi             bool
	}{
		{"postgresql", "/* DELETE */ INSERT INTO sample(note) VALUES ('UPDATE; COMMIT')", "insert", false, false},
		{"postgresql", "UPDATE sample SET note=$tag$ DELETE FROM sample; $tag$ WHERE id=1;", "update", false, false},
		{"postgresql", "WITH changed AS (DELETE FROM sample RETURNING *) SELECT * FROM changed", "select", true, false},
		{"postgresql", "WITH a AS (SELECT 1), b AS (UPDATE sample SET id=2 RETURNING id) INSERT INTO sample SELECT id FROM b", "insert", true, false},
		{"postgresql", "WITH a AS (SELECT 1) DELETE FROM sample WHERE id IN (SELECT * FROM a)", "delete", false, false},
		{"mysql", "UPDATE `join` a JOIN sample b ON a.id=b.id SET a.id=2", "update", false, true},
		{"mysql", "UPDATE sample a, other b SET a.id=2 WHERE a.id=b.id", "update", false, true},
		{"mysql", "UPDATE sample SET note='JOIN , USING' WHERE id=1", "update", false, false},
		{"mysql", "DELETE a FROM sample a JOIN other b ON a.id=b.id", "delete", false, true},
		{"mysql", "DELETE FROM a USING sample a JOIN other b ON a.id=b.id", "delete", false, true},
		{"mysql", "DELETE FROM sample WHERE note='USING'", "delete", false, false},
		{"sqlite", "WITH a AS (SELECT 1) UPDATE sample SET id=2 WHERE id IN (SELECT * FROM a)", "update", false, false},
	} {
		target, ok := ClassifyExplainTarget(item.engine, item.sql)
		if !ok || target.Statement != item.statement || target.DataModifyingCTE != item.cte || target.MySQLMultiTable != item.multi {
			t.Errorf("classification mismatch for %s", item.engine)
		}
	}
	for _, engine := range []string{"postgresql", "mysql", "sqlite"} {
		for _, sql := range []string{"EXPLAIN DELETE FROM sample", "DELETE FROM sample; COMMIT", "INSERT INTO sample VALUES(1);;", "(UPDATE sample SET id=1)", "WITH a AS (SELECT 1) COMMIT", "UPDATE sample SET id=:unbound", "UPDATE sample SET id=1 /* invalid", "REPLACE INTO sample VALUES(1)", "PRAGMA writable_schema=ON"} {
			if _, ok := ClassifyExplainTarget(engine, sql); ok {
				t.Errorf("accepted unsupported %s", engine)
			}
		}
	}
	for _, engine := range []string{"mysql", "sqlite"} {
		if _, ok := ClassifyExplainTarget(engine, "WITH a AS (DELETE FROM sample RETURNING *) SELECT * FROM a"); ok {
			t.Fatal("accepted data-modifying CTE for unsupported engine")
		}
	}
}

func TestEstimatedExplainRetainsRoutinePolicy(t *testing.T) {
	for _, item := range []struct {
		engine, sql string
		kind        Kind
	}{
		{"mysql", "INSERT INTO sample(id) VALUES(1)", Read},
		{"postgresql", "INSERT INTO schema_name.sample(id,note) VALUES(1,'fixture_write()')", Read},
		{"mysql", "INSERT INTO sample SELECT ABS(id) FROM source", Read},
		{"mysql", "INSERT INTO sample SELECT id FROM source a JOIN (SELECT fixture_write()) b", Unknown},
		{"mysql", "UPDATE sample SET id=(SELECT fixture_write()) WHERE id=1", Unknown},
		{"mysql", "DELETE FROM sample WHERE id=(SELECT fixture_write())", Unknown},
		{"mysql", "WITH a AS (SELECT fixture_write()) UPDATE sample SET id=1 WHERE id IN (SELECT * FROM a)", Unknown},
		{"postgresql", "WITH a AS (DELETE FROM sample WHERE id=fixture_write() RETURNING *) SELECT * FROM a", Unknown},
		{"postgresql", "UPDATE sample SET id=pg_catalog.abs(-1) WHERE id=1", Read},
		{"postgresql", "UPDATE sample SET id=public.abs(-1) WHERE id=1", Unknown},
		{"postgresql", "UPDATE sample SET id=\"abs\"(-1) WHERE id=1", Unknown},
		{"postgresql", "INSERT INTO sample(id) VALUES(nextval('sequence_name'))", Write},
		{"mysql", "INSERT INTO sample(id) VALUES(last_insert_id(2))", Write},
	} {
		statements := ClassifyEstimatedExplain(item.engine, item.sql)
		if len(statements) != 1 || statements[0].Kind != item.kind {
			t.Errorf("estimated routine policy mismatch for %s", item.engine)
		}
	}
}
