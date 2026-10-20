package safety

import "testing"

func TestCQLScriptKeepsBatchTogether(t *testing.T) {
	sql := `-- comments before a script
USE "MixedCase";
BEGIN UNLOGGED BATCH
INSERT INTO t (id, value) VALUES (1, 'a;b');
UPDATE t SET value = $$c;d$$ WHERE id = 2;
APPLY BATCH;
SELECT * FROM t;`
	statements := Classify("cassandra", sql)
	if len(statements) != 3 {
		t.Fatalf("statement count = %d, want 3", len(statements))
	}
	if statements[0].Kind != Read || statements[1].Kind != Write || statements[2].Kind != Read {
		t.Fatalf("unexpected assessments: %#v", statements)
	}
	batch := sql[statements[1].Start:statements[1].End]
	if len(batch) < 10 || batch[:5] != "BEGIN" || batch[len(batch)-11:] != "APPLY BATCH" {
		t.Fatalf("wrong batch boundary: %q", batch)
	}
	keyspace, ok := CQLKeyspace(sql[statements[0].Start:statements[0].End])
	if !ok || keyspace != "MixedCase" {
		t.Fatalf("keyspace %q %v", keyspace, ok)
	}
}
func TestCQLConservativeReadAssessment(t *testing.T) {
	for _, tc := range []struct {
		sql  string
		kind Kind
	}{
		{`SELECT * FROM t`, Read},
		{`SELECT count(*), system.ttl(value), system.todate(id) FROM t WHERE pk IN (1, 2)`, Read},
		{`SELECT custom(value) FROM t`, Unknown},
		{`SELECT uuid(1) FROM t`, Unknown},
		{`SELECT count(value) FROM t`, Unknown},
		{`SELECT ks.uuid(1) FROM t`, Unknown},
		{`SELECT ttl(value) FROM t`, Read},
		{`SELECT writetime("MixedCase") FROM t`, Read},
		{`SELECT ttl(udf(value)) FROM t`, Unknown},
		{`SELECT ttl(value, extra) FROM t`, Unknown},
		{`SELECT ks.ttl(value) FROM t`, Unknown},
		{`SELECT maxwritetime(value) FROM t`, Unknown},
		{`SELECT system.uuid() FROM t`, Read},
		{`SELECT CAST(value AS text) FROM t`, Read},
		{`SELECT CAST(value) FROM t`, Unknown},
		{`SELECT ks.count(*) FROM t`, Unknown},
		{`SELECT "count"(*) FROM t`, Unknown},
		{`SELECT * FROM t WHERE id = custom(1)`, Unknown},
		{`BEGIN BATCH DELETE FROM t WHERE id=1; APPLY BATCH`, Destructive},
		{`BEGIN BATCH INSERT INTO t(id) VALUES(1)`, Unknown},
		{`SELECT 'unterminated`, Unknown},
		{`SELECT * FROM t //comment\n`, Read},
		{`USE ks`, Read},
		{`USE ks extra`, Unknown},
		{`UPDATE t SET value={'a': 'b'} WHERE id=1`, Write},
		{`COMMIT`, Unknown},
	} {
		t.Run(tc.sql, func(t *testing.T) {
			statements := Classify("cassandra", tc.sql)
			if len(statements) != 1 || statements[0].Kind != tc.kind {
				t.Fatalf("assessment = %#v, want %s", statements, tc.kind)
			}
		})
	}
}
func TestCQLMalformedTailIsNotAuthorizedAsRead(t *testing.T) {
	for _, sql := range []string{`SELECT * FROM t; 'unterminated`, `BEGIN BATCH SELECT * FROM t;`, `SELECT * FROM t; /* unterminated`} {
		for _, statement := range Classify("cassandra", sql) {
			if statement.Kind == Read {
				t.Fatalf("unsafe partial read assessment for %q", sql)
			}
		}
	}
}
