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
		{`SELECT maxwritetime(value) FROM t`, Read},
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

func TestCQLReadSelectorsAndRelations(t *testing.T) {
	for _, sql := range []string{
		`SELECT attributes['name'], tags['a'..'z'], address.city FROM t`,
		`SELECT ttl(attributes['name']), writetime(address.city), maxwritetime(tags) FROM t`,
		`SELECT count(1) FROM t`,
		`SELECT * FROM t WHERE (part1, part2) = (1, 2) AND (time, id) > (3, 4)`,
		`SELECT * FROM t WHERE token(part1, part2) > system.token(1, 2)`,
		`SELECT * FROM t WHERE (part1 = 1) AND (((token(part1, part2) > system.token(1, 2))))`,
		`SELECT * FROM t WHERE value IN ([1, 2], [3, 4])`,
		`SELECT * FROM t WHERE attributes = {'name': 'test'} ALLOW FILTERING`,
		`SELECT * FROM t ORDER BY embedding ANN OF [0.1, 0.2] LIMIT 10`,
		`SELECT system.similarity_cosine(embedding, [0.1, 0.2]) FROM t`,
		`SELECT system.collection_count(tags), system.map_keys(attributes), system.mask_default(value) FROM t`,
		`SELECT system.blobAsTinyint(0x01), system.timeAsBlob(1), system.dateAsBlob(1) FROM t`,
	} {
		statements := Classify("cassandra", sql)
		if len(statements) != 1 || statements[0].Kind != Read {
			t.Errorf("CQL read requires write authorization: %q: %#v", sql, statements)
		}
	}
	for _, sql := range []string{
		`SELECT attributes[custom('name')] FROM t`,
		`SELECT ttl(attributes[custom('name')]) FROM t`,
		`SELECT maxwritetime(custom(value)) FROM t`,
		`SELECT * FROM t WHERE (part1, part2) IN ((custom(1), 2))`,
		`SELECT * FROM t WHERE token(custom(part1)) > 0`,
		`SELECT * FROM t WHERE (part1 = custom(1))`,
		`SELECT token(part1) FROM t`,
		`SELECT * FROM t ORDER BY embedding ANN OF [custom(1), 2] LIMIT 10`,
		`SELECT * FROM t WHERE attributes = {'name': custom('test')} ALLOW FILTERING`,
		`SELECT mask_default(value) FROM t`,
	} {
		statements := Classify("cassandra", sql)
		if len(statements) != 1 || statements[0].Kind != Unknown {
			t.Errorf("nested UDF was authorized as a read: %q: %#v", sql, statements)
		}
	}
}

func TestCQLMetadataReadStatements(t *testing.T) {
	for _, sql := range []string{
		`LIST USERS`, `LIST ROLES`, `LIST ROLES OF 'reader' NORECURSIVE`,
		`LIST ALL PERMISSIONS`, `LIST SELECT ON TABLE "Keyspace"."Table" OF "Reader"`,
		`LIST SELECT PERMISSION, MODIFY PERMISSION ON KEYSPACE app OF reader NORECURSIVE`,
		`LIST EXECUTE ON FUNCTION app.custom(frozen<map<text, tuple<int, text>>>, vector<float, 3>) OF reader`,
		`LIST ALL ON ALL FUNCTIONS IN KEYSPACE app`, `LIST DESCRIBE ON ALL ROLES`,
		`LIST ALL ON MBEANS 'org.apache.cassandra.*:*' NORECURSIVE`,
		`DESC CLUSTER`, `DESCRIBE FULL SCHEMA`, `DESCRIBE SCHEMA WITH INTERNALS`,
		`DESCRIBE KEYSPACES`, `DESCRIBE ONLY KEYSPACE`, `DESCRIBE ONLY KEYSPACE "App"`,
		`DESCRIBE TABLES`, `DESCRIBE TABLE app.records`, `DESCRIBE COLUMNFAMILY app.records`,
		`DESCRIBE INDEX app.idx WITH INTERNALS`, `DESCRIBE MATERIALIZED VIEW app.view`,
		`DESCRIBE TYPES`, `DESCRIBE TYPE app.address`, `DESCRIBE FUNCTIONS`,
		`DESCRIBE FUNCTION app.custom`, `DESCRIBE AGGREGATES`, `DESCRIBE AGGREGATE app.custom`,
		`DESCRIBE app.records`,
	} {
		statements := Classify("cassandra", sql)
		if len(statements) != 1 || statements[0].Kind != Read {
			t.Errorf("CQL metadata read requires write authorization: %q: %#v", sql, statements)
		}
	}
	for _, sql := range []string{
		`LIST`, `LIST USERS OF reader`, `LIST ROLES custom()`, `LIST ALL ON FUNCTION app.custom(udf())`,
		`LIST ALL OF custom()`, `LIST ALL ON TABLE app.records DROP TABLE app.records`,
		`DESCRIBE`, `DESCRIBE TABLE`, `DESCRIBE FUNCTION app.custom(1)`, `DESCRIBE TABLE app.records DROP TABLE app.records`,
	} {
		statements := Classify("cassandra", sql)
		if len(statements) != 1 || statements[0].Kind != Unknown {
			t.Errorf("invalid metadata statement authorized as read: %q: %#v", sql, statements)
		}
	}
	statements := Classify("cassandra", `LIST USERS; DROP ROLE reader; DESCRIBE SCHEMA; ADD IDENTITY 'client' TO ROLE reader`)
	if len(statements) != 4 || statements[0].Kind != Read || statements[1].Kind != Destructive || statements[2].Kind != Read || statements[3].Kind != Write {
		t.Fatalf("metadata script lost write assessment: %#v", statements)
	}
}

func TestCQLDollarStringsMatchServerLexing(t *testing.T) {
	statements := Classify("cassandra", `INSERT INTO t (id, value) VALUES (1, $$text; with 'quotes' and \slashes$$); SELECT * FROM t`)
	if len(statements) != 2 || statements[0].Kind != Write || statements[1].Kind != Read {
		t.Fatalf("CQL dollar-quoted text split incorrectly: %#v", statements)
	}
	for _, sql := range []string{`SELECT $body$value; DELETE FROM t;$body$ FROM t`, `SELECT col$name FROM t`, `SELECT $$unterminated FROM t`} {
		statements = Classify("cassandra", sql)
		if len(statements) != 1 || statements[0].Kind != Unknown || statements[0].Reason != "ambiguous_or_invalid_syntax" {
			t.Errorf("non-CQL dollar syntax was accepted: %q: %#v", sql, statements)
		}
	}
	statements = Classify("postgres", `SELECT $body$value; DELETE FROM t;$body$`)
	if len(statements) != 1 || statements[0].Kind != Read {
		t.Fatalf("CQL restriction changed PostgreSQL dollar strings: %#v", statements)
	}
}

func TestCQLNativeSnakeCaseNamesRequireExplicitSystemNamespace(t *testing.T) {
	for _, expression := range []string{
		`system.to_date(system.current_timestamp())`,
		`system.to_timestamp(system.current_timeuuid())`,
		`system.to_unix_timestamp(system.current_date())`,
		`system.current_time()`,
		`system.min_timeuuid(system.current_timestamp())`,
		`system.max_timeuuid(system.current_timestamp())`,
		`system.to_json(value)`,
		`system.blob_as_int(system.int_as_blob(1))`,
		`system.blob_as_duration(system.duration_as_blob(1mo2d3ns))`,
	} {
		statements := Classify("cassandra", "SELECT "+expression+" FROM t")
		if len(statements) != 1 || statements[0].Kind != Read {
			t.Errorf("explicit native snake_case spelling requires write authorization: %s", expression)
		}
	}
	for _, statement := range []string{
		`SELECT * FROM t WHERE id = system.from_json('1')`,
		`SELECT * FROM t WHERE id = system.fromJson('1')`,
	} {
		statements := Classify("cassandra", statement)
		if len(statements) != 1 || statements[0].Kind != Read {
			t.Fatal("native from_json term requires write authorization")
		}
	}
	for _, expression := range []string{
		`to_date(value)`, `current_timestamp()`, `ks.int_as_blob(value)`, `from_json('1')`,
		`system.to__date(value)`, `system.to_d_ate(value)`, `system.int_as__blob(value)`,
		`system.blob_as_unknown(value)`, `system.date_of(value)`, `system.unix_timestamp_of(value)`,
		`system.to_json(custom(value))`, `system.blob_as_int(int_as_blob(value))`,
	} {
		statements := Classify("cassandra", "SELECT "+expression+" FROM t")
		if len(statements) != 1 || statements[0].Kind != Unknown {
			t.Errorf("unrecognized or shadowable spelling was authorized: %s", expression)
		}
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
