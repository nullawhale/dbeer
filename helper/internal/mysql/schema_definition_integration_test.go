package mysql

import (
	"context"
	"fmt"
	"strings"
	"testing"

	sc "dbeer/helper/internal/schemacompare"
)

func TestSchemaDefinitionFromRealCapture(t *testing.T) {
	session := integrationSession(t)
	settings := integrationSettings(t)
	for _, generated := range []bool{false, true} {
		name := fmt.Sprintf("dbeer_definition_%x_%t", session.connectionID, generated)
		clone := name + "_copy"
		t.Run(fmt.Sprintf("generated_%t", generated), func(t *testing.T) {
			for _, table := range []string{name, clone} {
				run(t, session, "DROP TABLE IF EXISTS "+QuoteIdentifier(table))
				defer run(t, session, "DROP TABLE IF EXISTS "+QuoteIdentifier(table))
			}
			// Explicit session mode makes the original and preview literals comparable.
			run(t, session, "SET SESSION sql_mode='STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'")
			sql := "CREATE TABLE " + QuoteIdentifier(name) + " (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, amount DECIMAL(30,9) NOT NULL DEFAULT 9007199254740993.123456789, `no``te` VARCHAR(255) DEFAULT 'owner''s \\\\ note' COMMENT 'column''s comment', KEY note_idx (`no``te`(12) DESC)"
			if generated {
				sql += ", double_amount DECIMAL(31,9) GENERATED ALWAYS AS (amount * 2) STORED"
			}
			sql += ") ENGINE=InnoDB DEFAULT CHARACTER SET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='table''s comment'"
			run(t, session, sql)
			opened, err := Open(context.Background(), settings)
			if err != nil {
				t.Fatal("capture open failed")
			}
			defer opened.Close()
			reader := opened.(*Session)
			if err = reader.SetReadOnly(context.Background(), true); err != nil {
				t.Fatal("read-only capture setup failed")
			}
			collector := sc.NewCollector(context.Background(), sc.DefaultLimits())
			if err = reader.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{settings.Database}, Limits: sc.DefaultLimits()}, collector); err != nil {
				t.Fatalf("schema capture failed: %T", err)
			}
			var selected *sc.Table
			for i := range collector.Capture.Tables {
				if collector.Capture.Tables[i].Ref.Name == name {
					selected = &collector.Capture.Tables[i]
					break
				}
			}
			if selected == nil {
				t.Fatal("created table missing from frozen capture")
			}
			copied := *selected
			copied.Ref.Name = clone
			frozen := collector.Capture
			frozen.Tables = []sc.Table{copied}
			definition, err := RenderSchemaDefinition(context.Background(), frozen, copied.Ref)
			if err != nil {
				t.Fatalf("frozen definition failed: %T", err)
			}
			if definition.Limited != generated {
				t.Fatalf("unexpected definition completeness: limited=%t generated=%t", definition.Limited, generated)
			}
			for _, fragment := range []string{"CREATE TABLE ", "`id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT", "`amount` DECIMAL(30, 9) NOT NULL DEFAULT 9007199254740993.123456789", "`no``te` VARCHAR(255)", "DEFAULT 'owner''s \\\\ note'", "COMMENT 'column''s comment'", "COMMENT = 'table''s comment'", "`no``te`(12) DESC"} {
				if !strings.Contains(definition.SQL, fragment) {
					t.Fatal("frozen SQL definition lost a known catalog fact")
				}
			}
			if strings.Contains(definition.SQL, "/*") {
				t.Fatal("known table definition contains an unavailable SQL placeholder")
			}
			if generated && !strings.Contains(definition.SQL, "-- Incomplete generated column dependencies") {
				t.Fatal("uncaptured expression dependencies were not disclosed")
			}
			// Recreate only disposable fixtures to verify the preview's SQL grammar.
			run(t, session, definition.SQL)
			recreated := sc.NewCollector(context.Background(), sc.DefaultLimits())
			if err = reader.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{settings.Database}, Limits: sc.DefaultLimits()}, recreated); err != nil {
				t.Fatalf("recreated schema capture failed: %T", err)
			}
			var recreatedTable *sc.Table
			for i := range recreated.Capture.Tables {
				if recreated.Capture.Tables[i].Ref.Name == clone {
					recreatedTable = &recreated.Capture.Tables[i]
					break
				}
			}
			if recreatedTable == nil {
				t.Fatal("recreated table missing from capture")
			}
			// The capture records effective charset/collation, not whether the
			// original DDL spelled them explicitly. SHOW CREATE preserves this
			// spelling distinction, so compare every captured semantic fact.
			scope := func(context sc.CaptureContext, table sc.Table) sc.Capture {
				return sc.Capture{Context: context, Tables: []sc.Table{table}, Inventories: []sc.Inventory{{Schema: settings.Database, Existence: "present", Tables: sc.Complete([]sc.Ref{table.Ref}), Types: sc.Complete[sc.Ref](nil)}}}
			}
			mappings := sc.Mappings{Schemas: []sc.NamePair{{Source: settings.Database, Target: settings.Database}}, Tables: []sc.TablePair{{Source: sc.QualifiedName{Schema: settings.Database, Name: name}, Target: sc.QualifiedName{Schema: settings.Database, Name: clone}, Columns: []sc.NamePair{}, Constraints: []sc.NamePair{}, Indexes: []sc.NamePair{}}}, Types: []sc.ObjectPair{}}
			result, err := sc.Build(context.Background(), t.TempDir(), scope(collector.Capture.Context, *selected), scope(recreated.Capture.Context, *recreatedTable), mappings)
			if err != nil {
				t.Fatalf("round-trip comparison failed: %T", err)
			}
			defer result.Close()
			for _, difference := range result.Report.Differences {
				if difference.Kind != "indeterminate" {
					t.Fatalf("rendered SQL changed a captured fact: property=%s kind=%s", difference.Property, difference.Kind)
				}
			}
			if !generated && !result.Report.Summary.FullEquality {
				t.Fatal("ordinary table round trip did not preserve all captured facts")
			}
			if generated && (result.Report.Summary.FullEquality || result.Report.Summary.IndeterminateObjects != 1) {
				t.Fatal("uncaptured expression dependencies incorrectly established full equality")
			}
		})
	}
}
