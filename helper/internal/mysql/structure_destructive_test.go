package mysql

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
)

func mysqlDestructiveBaseline(typ tableedit.DataType) tableedit.Baseline {
	name := "exact`é"
	c := sc.Column{Ref: sc.Ref{Kind: "column", Schema: "fixture", Table: "table", Name: name}, Type: sc.Known(tableedit.ExpectedNewType("mysql", typ)), Ordinal: sc.Known(1), Nullable: sc.Known(true), Default: sc.Known(sc.Default{Kind: "sqlNull"}), Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(false), Comment: sc.Known("retained 'comment'"), OnUpdate: sc.Absent[sc.Expression]()}
	if typ.Kind == "text" || typ.Kind == "varchar" {
		c.Charset = sc.Known("utf8mb4")
		c.Collation = sc.Known(sc.Ref{Kind: "collation", Name: "utf8mb4_0900_ai_ci"})
	}
	return tableedit.Baseline{Engine: "mysql", Target: tableedit.Target{Schema: "fixture", Table: "table"}, Facts: &tableedit.Facts{Proof: true, EngineContext: []sc.Option{{Name: "sqlMode", Value: "ANSI_QUOTES,NO_BACKSLASH_ESCAPES,STRICT_TRANS_TABLES"}}, Table: sc.Table{Columns: sc.Complete([]sc.Column{c}), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil)}, Dependents: map[string][]string{}}}
}

func TestStructureDestructiveMySQLPreservesReplacementAttributes(t *testing.T) {
	b := mysqlDestructiveBaseline(tableedit.DataType{Kind: "varchar", Length: 80})
	name := b.Facts.Table.Columns.Items[0].Ref.Name
	typ := tableedit.DataType{Kind: "varchar", Length: 8}
	change := tableedit.ColumnChange{Name: name, Type: &typ}
	sql, err := mysqlConversionChange(context.Background(), b, change, "`fixture`.`table`")
	if err != nil || len(sql) != 1 {
		t.Fatalf("narrowing unavailable: %v", err)
	}
	for _, preserved := range []string{"`exact``é` VARCHAR(8)", "CHARACTER SET `utf8mb4`", "COLLATE `utf8mb4_0900_ai_ci`", " NULL DEFAULT NULL", " INVISIBLE", "COMMENT 'retained ''comment'''"} {
		if !strings.Contains(sql[0], preserved) {
			t.Fatalf("MODIFY lost captured attribute %s", preserved)
		}
	}
	if *b.Facts.Table.Columns.Items[0].Type.Value.Modifiers.Value.Length != 80 {
		t.Fatal("rendering mutated the retained source metadata")
	}
	charset := "latin1"
	collation := tableedit.TypeReference{Name: "latin1_bin"}
	change.Charset, change.Collation = &charset, &collation
	sql, err = mysqlConversionChange(context.Background(), b, change, "`fixture`.`table`")
	if err != nil || !strings.Contains(sql[0], "CHARACTER SET `latin1` COLLATE `latin1_bin`") {
		t.Fatal("explicit charset and collation conversion was lost")
	}
	change.Collation = nil
	if _, err = mysqlConversionChange(context.Background(), b, change, "`fixture`.`table`"); err == nil {
		t.Fatal("encoding conversion selected an implicit target collation")
	}
	using := "1"
	change = tableedit.ColumnChange{Name: name, Type: &typ, UsingExpression: &using}
	if _, err = mysqlConversionChange(context.Background(), b, change, "`fixture`.`table`"); err == nil {
		t.Fatal("MySQL accepted PostgreSQL USING")
	}
	b.Facts.Table.Columns.Items[0].OnUpdate = sc.Unknown[sc.Expression]("unavailable")
	if _, err = mysqlConversionChange(context.Background(), b, tableedit.ColumnChange{Name: name, Type: &typ}, "`fixture`.`table`"); err == nil {
		t.Fatal("MODIFY silently discarded unavailable column facts")
	}
}

func TestStructureDestructiveMySQLExactRangeAndCharsetChecks(t *testing.T) {
	b := mysqlDestructiveBaseline(tableedit.DataType{Kind: "bigint"})
	name := b.Facts.Table.Columns.Items[0].Ref.Name
	unsigned := true
	checks := mysqlConversionChecks(b, tableedit.ColumnChange{Name: name, Unsigned: &unsigned})
	if len(checks) != 1 || checks[0].SQL == nil || !strings.Contains(*checks[0].SQL, "18446744073709551615") || !strings.Contains(*checks[0].SQL, "TRUNCATE(") || !strings.Contains(*checks[0].SQL, "IS NOT NULL AND ((") {
		t.Fatal("unsigned conversion lost the exact range or NULL guard")
	}
	decimal := tableedit.DataType{Kind: "numeric", Precision: 20, Scale: 2}
	checks = mysqlConversionChecks(b, tableedit.ColumnChange{Name: name, Type: &decimal})
	if len(checks) != 1 || checks[0].SQL == nil || strings.Contains(*checks[0].SQL, "ABS(") || !strings.Contains(*checks[0].SQL, "<= -1000000000000000000") {
		t.Fatal("decimal validation could overflow on signed BIGINT minimum")
	}
	b = mysqlDestructiveBaseline(tableedit.DataType{Kind: "varchar", Length: 80})
	name = b.Facts.Table.Columns.Items[0].Ref.Name
	charset := "latin1"
	collation := tableedit.TypeReference{Name: "latin1_bin"}
	checks = mysqlConversionChecks(b, tableedit.ColumnChange{Name: name, Charset: &charset, Collation: &collation})
	if len(checks) != 2 || checks[0].SQL == nil || !strings.Contains(*checks[0].SQL, "USING `latin1`") || !strings.Contains(*checks[0].SQL, "USING `utf8mb4`") || checks[1].SQL != nil || checks[1].UnavailableReason == nil {
		t.Fatal("encoding round-trip and unprovable collation semantics were conflated")
	}
	s := &Session{}
	results := s.StructureValidate(context.Background(), b, tableedit.Plan{ValidationChecks: checks[1:]})
	if len(results) != 1 || results[0].State != "unavailable" {
		t.Fatal("unavailable collation validation attempted execution")
	}
}

func TestStructureDestructiveMySQLDropPreviewHasNoScans(t *testing.T) {
	b := mysqlDestructiveBaseline(tableedit.DataType{Kind: "integer"})
	b.Columns = []tableedit.ObservedColumn{{Name: b.Facts.Table.Columns.Items[0].Ref.Name}}
	draft := tableedit.Draft{AuthoringVersion: 4, DropTable: true, Columns: []tableedit.Column{}, AllowDestructive: true}
	p, err := (&Session{}).StructurePrepare(context.Background(), b, draft)
	if err != nil || len(p.SQL) != 1 || p.SQL[0] != "DROP TABLE `fixture`.`table`;" || !p.DroppedTarget || len(p.Consequences) == 0 || len(p.ValidationChecks) != 1 || p.ValidationChecks[0].SQL != nil {
		t.Fatalf("DROP review was incomplete or attempted to read values: %v", err)
	}
}

func TestStructureDestructiveMySQLConversionValidationDropLive(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s := integrationSession(t)
	ctx := context.Background()
	name := fmt.Sprintf("destructive_%d", time.Now().UnixNano())
	target := tableedit.Target{Schema: integrationSettings(t).Database, Table: name}
	table := QuoteIdentifier(target.Schema) + "." + QuoteIdentifier(name)
	defer run(t, s, "DROP TABLE IF EXISTS "+table)
	run(t, s, "CREATE TABLE "+table+"(id INT PRIMARY KEY,amount DECIMAL(30,4),counter BIGINT,label VARCHAR(40) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin COMMENT 'preserved comment',doomed TEXT,kept TEXT) ENGINE=InnoDB")
	run(t, s, "INSERT INTO "+table+" VALUES(1,2147483648.5,-1,'é-long-value','remove',NULL),(2,NULL,NULL,NULL,NULL,'NULL')")
	preview := func(change tableedit.ColumnChange) (*tableedit.Store, *tableedit.Plan) {
		t.Helper()
		store := &tableedit.Store{}
		b, err := store.Load(ctx, s, target)
		if err != nil {
			t.Fatal("destructive baseline unavailable")
		}
		p, err := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{change}, AllowDestructive: true})
		if err != nil || !p.Plan.Destructive || len(p.Plan.Consequences) == 0 || len(p.Plan.ValidationChecks) == 0 {
			t.Fatalf("destructive conversion preview unavailable: %v", err)
		}
		return store, p.Plan
	}
	integer := tableedit.DataType{Kind: "integer"}
	store, p := preview(tableedit.ColumnChange{Name: "amount", Type: &integer})
	validation, err := store.Validate(ctx, s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "invalid_values"})
	if err != nil || validation.Validation == nil || validation.Validation.Checks[0].State != "failed" || validation.Validation.Checks[0].InvalidRows == nil || *validation.Validation.Checks[0].InvalidRows != "1" {
		t.Fatal("range/fraction validation did not report the exact invalid-row count")
	}
	failed, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "rejected_narrowing"})
	if err != nil || failed.Outcome.State != "failed" {
		t.Fatal("overflow narrowing was not a known MySQL rejection in strict mode")
	}
	unsigned := true
	store, p = preview(tableedit.ColumnChange{Name: "counter", Unsigned: &unsigned})
	validation, err = store.Validate(ctx, s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "signedness_invalid"})
	if err != nil || validation.Validation.Checks[0].State != "failed" || validation.Validation.Checks[0].InvalidRows == nil || *validation.Validation.Checks[0].InvalidRows != "1" {
		t.Fatal("negative-to-unsigned loss was not exposed")
	}
	run(t, s, "UPDATE "+table+" SET amount=12.25,counter=9,label='é' WHERE id=1")
	structureRunDraftMySQL(t, s, target, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "counter", Unsigned: &unsigned}}}, "unsigned_change")
	structureRunDraftMySQL(t, s, target, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "counter", Type: &integer}}}, "unsigned_narrow")
	decimal := tableedit.DataType{Kind: "numeric", Precision: 10, Scale: 2}
	structureRunDraftMySQL(t, s, target, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "amount", Type: &decimal}}}, "numeric_narrow")
	charset := "latin1"
	collation := tableedit.TypeReference{Name: "latin1_bin"}
	label := tableedit.DataType{Kind: "varchar", Length: 8}
	run(t, s, "UPDATE "+table+" SET label='😀' WHERE id=1")
	store, p = preview(tableedit.ColumnChange{Name: "label", Type: &label, Charset: &charset, Collation: &collation})
	validation, err = store.Validate(ctx, s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "encoding_invalid"})
	if err != nil || validation.Validation.Checks[0].State != "failed" || validation.Validation.Checks[0].InvalidRows == nil || *validation.Validation.Checks[0].InvalidRows != "1" {
		t.Fatal("unrepresentable charset values were not exposed")
	}
	run(t, s, "UPDATE "+table+" SET label='é' WHERE id=1")
	store, p = preview(tableedit.ColumnChange{Name: "label", Type: &label, Charset: &charset, Collation: &collation})
	validation, err = store.Validate(ctx, s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "encoding_valid"})
	if err != nil || validation.Validation.Checks[0].State != "passed" || validation.Validation.Checks[1].State != "unavailable" {
		t.Fatal("charset representability and collation meaning were not distinguished")
	}
	result, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.ID, Digest: p.Digest, ExecutionID: "encoding_apply"})
	if err != nil || result.Outcome.State != "applied" || result.Outcome.Steps[0].Message != "" {
		t.Fatal("encoding conversion transition did not verify")
	}
	collation.Name = "latin1_swedish_ci"
	structureRunDraftMySQL(t, s, target, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "label", Collation: &collation}}}, "collation_change")
	run(t, s, "CREATE INDEX destructive_doomed ON "+table+"(doomed(8))")
	store = &tableedit.Store{}
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal("drop baseline unavailable")
	}
	drop := tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "doomed", Drop: true}}}
	if _, err = store.PreviewContext(ctx, s, b.Baseline.ID, drop); err == nil || !strings.Contains(err.Error(), "destructive_doomed") {
		t.Fatal("column removal did not identify its unscheduled dependent index")
	}
	drop.Indexes = []tableedit.IndexEdit{{Action: "drop", Name: "destructive_doomed"}}
	structureRunDraftMySQL(t, s, target, drop, "column_drop")
	response := s.Execute(ctx, protocol.Command{SQL: "SELECT count(*)=2 AND count(amount)=1 AND min(amount)=12.25 AND min(counter)=9 AND min(label)='é' AND count(kept)=1 AND max(kept)='NULL' FROM " + table})
	if response.Type != "query.result" || len(response.Rows) != 1 || len(response.Rows[0]) != 1 || response.Rows[0][0] == nil || *response.Rows[0][0] != "1" {
		t.Fatal("conversion/drop changed unaffected rows or SQL NULL/text NULL")
	}
	dropped := structureRunDraftMySQL(t, s, target, tableedit.Draft{AuthoringVersion: 4, DropTable: true, Columns: []tableedit.Column{}, AllowDestructive: true}, "table_drop")
	if !dropped.DroppedTarget || dropped.Observed != nil || dropped.RefreshError != "" {
		t.Fatal("acknowledged table deletion was not represented as an absent target")
	}
}

func structureRunDraftMySQL(t *testing.T, s *Session, target tableedit.Target, draft tableedit.Draft, executionID string) tableedit.Outcome {
	t.Helper()
	ctx := context.Background()
	store := &tableedit.Store{}
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal("destructive baseline unavailable")
	}
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, draft)
	if err != nil {
		t.Fatalf("destructive preview rejected: %v", err)
	}
	result, err := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: executionID})
	if err != nil || result.Outcome.State != "applied" {
		t.Fatalf("destructive operation %s did not apply", executionID)
	}
	for _, step := range result.Outcome.Steps {
		if step.Message != "" {
			t.Fatalf("destructive operation %s did not preserve metadata: %s", executionID, step.Message)
		}
	}
	return *result.Outcome
}

func TestStructureDestructiveMySQLValidationCancellationLive(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s := integrationSession(t)
	observer := integrationSession(t)
	ctx := context.Background()
	name := fmt.Sprintf("cancel_validation_%d", time.Now().UnixNano())
	target := tableedit.Target{Schema: integrationSettings(t).Database, Table: name}
	table := QuoteIdentifier(target.Schema) + "." + QuoteIdentifier(name)
	defer run(t, s, "DROP TABLE IF EXISTS "+table)
	run(t, s, "CREATE TABLE "+table+"(id INT PRIMARY KEY,value BIGINT) ENGINE=InnoDB")
	run(t, s, "INSERT INTO "+table+" VALUES(1,9),(2,NULL)")
	store := &tableedit.Store{}
	b, err := store.Load(ctx, s, target)
	if err != nil {
		t.Fatal("validation cancellation baseline unavailable")
	}
	integer := tableedit.DataType{Kind: "integer"}
	p, err := store.PreviewContext(ctx, s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "value", Type: &integer}}})
	if err != nil {
		t.Fatal("validation cancellation preview unavailable")
	}
	run(t, observer, "LOCK TABLES "+table+" WRITE")
	defer run(t, observer, "UNLOCK TABLES")
	limited, cancel := context.WithTimeout(ctx, 150*time.Millisecond)
	started := time.Now()
	validation, err := store.Validate(limited, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "cancel_validation"})
	cancel()
	if err != nil || validation.Validation.State != "cancelled" || validation.Validation.Checks[0].State != "cancelled" || time.Since(started) > 3*time.Second {
		t.Fatal("validation did not cancel its owned metadata lock wait promptly")
	}
	run(t, observer, "UNLOCK TABLES")
	if s.TransactionStatus() != "idle" {
		t.Fatal("read-only validation leaked a transaction")
	}
	structureRunDraftMySQL(t, s, target, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "value", Type: &integer}}}, "narrow_after_cancel")
}

func TestStructureDestructiveMySQLCrossKindEncodingLive(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s := integrationSession(t)
	ctx := context.Background()
	name := fmt.Sprintf("destructive_cross_%d", time.Now().UnixNano())
	target := tableedit.Target{Schema: integrationSettings(t).Database, Table: name}
	table := QuoteIdentifier(target.Schema) + "." + QuoteIdentifier(name)
	defer run(t, s, "DROP TABLE IF EXISTS "+table)
	run(t, s, "CREATE TABLE "+table+"(id INT PRIMARY KEY,value DECIMAL(8,2) COMMENT 'keep') ENGINE=InnoDB")
	run(t, s, "INSERT INTO "+table+" VALUES(1,12.50),(2,NULL)")
	charset := "utf8mb4"
	collation := tableedit.TypeReference{Name: "utf8mb4_bin"}
	varchar := tableedit.DataType{Kind: "varchar", Length: 20}
	structureRunDraftMySQL(t, s, target, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "value", Type: &varchar, Charset: &charset, Collation: &collation}}}, "numeric_to_text")
	b, err := s.StructureLoad(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	c, ok := tableedit.FindColumn(b, "value")
	if !ok || c.Charset.Value == nil || *c.Charset.Value != "utf8mb4" || c.Collation.Value == nil || c.Collation.Value.Name != "utf8mb4_bin" || c.Comment.Value == nil || *c.Comment.Value != "keep" {
		t.Fatal("crosskind explicit encoding or unchanged comment was lost")
	}
	numeric := tableedit.DataType{Kind: "numeric", Precision: 8, Scale: 2}
	structureRunDraftMySQL(t, s, target, tableedit.Draft{AuthoringVersion: 4, Columns: []tableedit.Column{}, AllowDestructive: true, Changes: []tableedit.ColumnChange{{Name: "value", Type: &numeric}}}, "text_to_numeric")
	b, err = s.StructureLoad(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	c, ok = tableedit.FindColumn(b, "value")
	if !ok || c.Charset.Value != nil || c.Collation.Value != nil || c.Comment.Value == nil || *c.Comment.Value != "keep" {
		t.Fatal("nontext target retained character metadata or lost comment")
	}
	result, err := s.work.client.Execute("SELECT value FROM " + table + " ORDER BY id")
	if err != nil {
		t.Fatal(err)
	}
	defer result.Close()
	v, err := ownedStructureString(result, 0, 0)
	second, _ := result.GetValue(1, 0)
	if err != nil || v != "12.50" || second != nil {
		t.Fatal("crosskind roundtrip lost exact numeric or SQL NULL values")
	}
}
