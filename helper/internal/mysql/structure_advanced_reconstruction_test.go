package mysql

import (
	"context"
	"fmt"
	"math"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/tableedit"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func TestStructureAdvancedDataBinaryFrame(t *testing.T) {
	values := []wire.FieldValue{
		wire.NewFieldValue(wire.FieldValueTypeNull, 0, nil),
		wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte{}),
		wire.NewFieldValue(wire.FieldValueTypeFloat, math.Float64bits(math.Copysign(0, -1)), nil),
	}
	negative, err := myAdvancedDataFrame(values)
	if err != nil {
		t.Fatal(err)
	}
	values[2] = wire.NewFieldValue(wire.FieldValueTypeFloat, math.Float64bits(0), nil)
	positive, _ := myAdvancedDataFrame(values)
	if reflect.DeepEqual(negative, positive) {
		t.Fatal("binary proof conflated positive and negative zero")
	}
	values[1] = wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte("NULL"))
	text, _ := myAdvancedDataFrame(values)
	if reflect.DeepEqual(text, positive) {
		t.Fatal("binary proof conflated empty text and text NULL")
	}
}

func TestStructureAdvancedTimestampNativeInstantMySQLLive(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s := integrationSession(t)
	utc := integrationSession(t)
	ctx := context.Background()
	settings := integrationSettings(t)
	run(t, s, "SET SESSION sql_mode='STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION,NO_AUTO_VALUE_ON_ZERO'")
	run(t, utc, "SET SESSION sql_mode='STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION,NO_AUTO_VALUE_ON_ZERO'")
	run(t, utc, "SET SESSION time_zone='+00:00'")
	for _, engine := range []string{"MyISAM", "Partitions"} {
		t.Run(engine, func(t *testing.T) {
			name := fmt.Sprintf("e7_timestamp_%s_%d", engine, time.Now().UnixNano())
			target := tableedit.Target{Schema: settings.Database, Table: name}
			table := QuoteIdentifier(target.Schema) + "." + QuoteIdentifier(target.Table)
			suffix := " ENGINE=MyISAM"
			if engine == "Partitions" {
				suffix = " ENGINE=InnoDB PARTITION BY RANGE(id)(PARTITION p0 VALUES LESS THAN(3),PARTITION p1 VALUES LESS THAN MAXVALUE)"
			}
			run(t, utc, "CREATE TABLE "+table+"(id int PRIMARY KEY,ts timestamp(6) NULL,d datetime(6) NULL)"+suffix)
			defer run(t, utc, "DROP TABLE IF EXISTS "+table)
			run(t, utc, "INSERT INTO "+table+" VALUES(1,'2024-11-03 05:30:00.123456','2024-11-03 01:30:00.123456'),(2,NULL,NULL),(3,'0000-00-00 00:00:00','0000-00-00 00:00:00'),(4,'2024-11-03 05:30:00.999999','2024-11-03 01:30:00.999999')")
			run(t, s, "SET SESSION time_zone='America/New_York'")
			b, err := s.StructureLoad(ctx, target)
			if err != nil || b.Advanced == nil {
				t.Fatal("native timestamp fixture metadata unavailable")
			}
			condition := tableedit.Condition{Operation: tableedit.Operation{Kind: "reorder"}}
			proof, err := s.myAdvancedDataCapture(b, condition)
			if err != nil || !strings.Contains(proof.SQL, "UNIX_TIMESTAMP(`ts`)") {
				t.Fatal("native timestamp instant projection missing")
			}
			calendarSQL := "SELECT ts,d FROM " + table + " ORDER BY id"
			calendar, err := s.myAdvancedReadData(calendarSQL)
			if err != nil || len(calendar) != 4 || s.myAdvancedDataVerify(proof, target) != nil {
				t.Fatal("complete native timestamp control unavailable")
			}
			run(t, utc, "UPDATE "+table+" SET ts='2024-11-03 06:30:00.123456' WHERE id=1")
			folded, err := s.myAdvancedReadData(calendarSQL)
			if err != nil || !reflect.DeepEqual(calendar, folded) {
				t.Fatal("DST-fold positive control did not retain identical binary calendar fields")
			}
			if s.myAdvancedDataVerify(proof, target) == nil {
				t.Fatal("distinct native TIMESTAMP instants collapsed in a DST fold")
			}
			run(t, utc, "UPDATE "+table+" SET ts='2024-11-03 05:30:00.123456' WHERE id=1")
			if s.myAdvancedDataVerify(proof, target) != nil {
				t.Fatal("restoring the exact instant did not restore the native proof")
			}
			p, err := myAdvancedReconstructionPrepare(b, tableedit.Draft{AuthoringVersion: 5, AllowDestructive: true, Reconstruct: true, ColumnOrder: []string{"d", "ts", "id"}, Columns: []tableedit.Column{}})
			if err != nil {
				t.Fatal(err)
			}
			run(t, s, p.SQL[0])
			if s.myAdvancedDataVerify(proof, target) != nil {
				t.Fatal("native COPY/reorder changed timestamp instants, fractions, NULL or zero values")
			}
		})
	}
}

func TestStructureAdvancedNativeDataMySQLLive(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s := integrationSession(t)
	ctx := context.Background()
	settings := integrationSettings(t)
	run(t, s, "SET SESSION sql_mode='STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION,NO_AUTO_VALUE_ON_ZERO'")
	for _, kind := range []string{"MyISAM", "Partitions"} {
		t.Run(kind, func(t *testing.T) {
			name := fmt.Sprintf("e7_data_%s_%d", kind, time.Now().UnixNano())
			target := tableedit.Target{Schema: settings.Database, Table: name}
			table := QuoteIdentifier(target.Schema) + "." + QuoteIdentifier(target.Table)
			suffix := " ENGINE=MyISAM ROW_FORMAT=DYNAMIC COMMENT='retained table'"
			if kind == "Partitions" {
				suffix = " ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='retained table' PARTITION BY RANGE(id)(PARTITION p0 VALUES LESS THAN(100) COMMENT 'retained lower',PARTITION p1 VALUES LESS THAN MAXVALUE COMMENT 'retained upper')"
			}
			run(t, s, "CREATE TABLE "+table+"(id int NOT NULL AUTO_INCREMENT PRIMARY KEY,payload varchar(50) COMMENT 'retained column',n decimal(30,4),b varbinary(4),base int,g int GENERATED ALWAYS AS(base*2) STORED,v int GENERATED ALWAYS AS(base+1) VIRTUAL,choice enum('','x'),f double,KEY retained_idx(n))"+suffix)
			defer run(t, s, "DROP TABLE IF EXISTS "+table)
			run(t, s, "INSERT INTO "+table+"(id,payload,n,b,base,choice,f) VALUES(0,'',12345678901234567890.1234,0x00ff,3,'',1.2345678901234567),(101,'NULL',NULL,NULL,4,'x',-3.25),(102,NULL,-12345678901234567890.1234,0x0000,4,NULL,NULL)")
			run(t, s, "ALTER TABLE "+table+" AUTO_INCREMENT=1000")
			load := func() tableedit.Baseline {
				t.Helper()
				b, err := s.StructureLoad(ctx, target)
				if err != nil || b.Advanced == nil {
					t.Fatalf("advanced native load: %v", err)
				}
				return b
			}
			b := load()
			order := []string{"payload", "n", "b", "base", "g", "v", "choice", "f", "id"}
			p, err := myAdvancedReconstructionPrepare(b, tableedit.Draft{AuthoringVersion: 5, AllowDestructive: true, Reconstruct: true, ColumnOrder: order, Columns: []tableedit.Column{}})
			if err != nil {
				t.Fatal(err)
			}
			proof, err := s.myAdvancedDataCapture(b, p.Conditions[0])
			if err != nil || proof == nil || len(proof.Rows) != 3 {
				t.Fatalf("complete native rows: %v", err)
			}
			run(t, s, p.SQL[0])
			if err = s.myAdvancedDataVerify(proof, target); err != nil {
				t.Fatal(err)
			}
			fresh := load()
			if !tableedit.VerifyColumnOrder(b, fresh, order, false) || !mysqlReconstructionPreserved(b, fresh) || !reflect.DeepEqual(b.AdvancedEvidence, fresh.AdvancedEvidence) {
				t.Fatal("native COPY changed retained full definition/partition/engine/trigger metadata")
			}
			for _, selected := range []string{"g", "id", "id"} {
				b = load()
				change := tableedit.ColumnChange{Name: selected}
				if selected == "g" {
					change.Generated = &tableedit.Generation{Storage: "stored", Expression: "base*3"}
				} else {
					old, _ := tableedit.FindColumn(b, "id")
					kind := "none"
					if old.Identity.Value != nil && old.Identity.Value.Kind == "none" {
						kind = "autoIncrement"
					}
					change.Identity = &tableedit.Identity{Kind: kind}
				}
				condition := tableedit.Condition{Operation: tableedit.Operation{Kind: "changeColumn", Change: &change}}
				proof, err = s.myAdvancedDataCapture(b, condition)
				if err != nil {
					t.Fatal(err)
				}
				column, _ := tableedit.FindColumn(b, selected)
				steps, err := mysqlAuthoredChange(ctx, b, column, change, table)
				if err != nil {
					t.Fatal(err)
				}
				for _, step := range steps {
					run(t, s, step)
				}
				if err = s.myAdvancedDataVerify(proof, target); err != nil {
					t.Fatal(err)
				}
				fresh = load()
				if !myAdvancedGenerationPreserved(b, fresh, condition) {
					t.Fatal("selected generation/identity lost an unaffected native property")
				}
			}
			run(t, s, "ALTER TABLE "+table+" ADD COLUMN required int NULL")
			b = load()
			backfillColumn := "required"
			backfill := tableedit.Condition{Operation: tableedit.Operation{Kind: "backfill", Name: &backfillColumn}}
			proof, err = s.myAdvancedDataCapture(b, backfill)
			if err != nil {
				t.Fatal(err)
			}
			run(t, s, "UPDATE "+table+" SET required=id+1 WHERE required IS NULL")
			if err = s.myAdvancedDataVerify(proof, target); err != nil {
				t.Fatal(err)
			}
			run(t, s, "ALTER TABLE "+table+" MODIFY required int NOT NULL")
			b = load()
			proof, err = s.myAdvancedDataCapture(b, tableedit.Condition{Operation: tableedit.Operation{Kind: "backfill"}})
			if err != nil {
				t.Fatal(err)
			}
			run(t, s, "UPDATE "+table+" SET payload='unexpected' WHERE id=0")
			if s.myAdvancedDataVerify(proof, target) == nil {
				t.Fatal("unexpected retained value change was accepted")
			}
		})
	}
}
