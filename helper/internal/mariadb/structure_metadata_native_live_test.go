package mariadb

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"fmt"
	"testing"
	"time"
)

func TestMariaDBStructureLoadNativeKindsAndExactMetadataLive(t *testing.T) {
	s := dataIntegrationSession(t)
	schema := dataIntegrationSettings(t).Database
	for _, kind := range []string{"ordinary", "partitioned", "myisam", "aria", "implicitHistory", "explicitHistory"} {
		t.Run(kind, func(t *testing.T) {
			name := fmt.Sprintf("g1_structure_%d", time.Now().UnixNano())
			q := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
			shape := "(id INT NOT NULL,n DECIMAL(65,38) DEFAULT 0.12345678901234567890123456789012345678,b VARBINARY(10) DEFAULT X'FF',empty_text VARCHAR(30) DEFAULT '',null_text VARCHAR(30) DEFAULT 'NULL',nullable VARCHAR(30) DEFAULT NULL,derived INT GENERATED ALWAYS AS(id*2) PERSISTENT,PRIMARY KEY(id),KEY native_idx(empty_text(5) DESC) IGNORED) ENGINE=InnoDB"
			expectedKind := ""
			switch kind {
			case "partitioned":
				shape += " PARTITION BY RANGE(id)(PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(MAXVALUE))"
				expectedKind = "mariaDBPartitions"
			case "myisam":
				shape = "(id INT PRIMARY KEY,n VARCHAR(30)) ENGINE=MyISAM"
				expectedKind = "mariaDBMyISAM"
			case "aria":
				shape = "(id INT PRIMARY KEY,n VARCHAR(30)) ENGINE=Aria"
				expectedKind = "mariaDBAria"
			case "implicitHistory":
				shape = "(id INT PRIMARY KEY,n VARCHAR(30)) ENGINE=InnoDB WITH SYSTEM VERSIONING"
				expectedKind = "mariaDBSystemVersioned"
			case "explicitHistory":
				shape = "(id INT PRIMARY KEY,n VARCHAR(30),started BIGINT UNSIGNED GENERATED ALWAYS AS ROW START,ended BIGINT UNSIGNED GENERATED ALWAYS AS ROW END,PERIOD FOR SYSTEM_TIME(started,ended)) ENGINE=InnoDB WITH SYSTEM VERSIONING"
				expectedKind = "mariaDBSystemVersioned"
			}
			dataRun(t, s, "CREATE TABLE "+q+shape)
			defer dataRun(t, s, "DROP TABLE IF EXISTS "+q)
			dataRun(t, s, "INSERT INTO "+q+"(id) VALUES(1)")
			target := tableedit.Target{Schema: schema, Table: name}
			b, err := s.StructureLoad(context.Background(), target)
			if err != nil || !tableedit.ValidBaseline(b) || b.Engine != "mariadb" || b.Facts == nil || len(b.Columns) < 2 {
				t.Fatalf("native structure load failed for %s: %T", kind, err)
			}
			if expectedKind == "" && b.Advanced != nil || expectedKind != "" && (b.Advanced == nil || len(b.Advanced.Kinds) != 1 || b.Advanced.Kinds[0] != expectedKind) {
				t.Fatal("native structure kind authority changed")
			}
			if kind == "ordinary" || kind == "partitioned" {
				binary, ok := tableedit.FindColumn(b, "b")
				if !ok || binary.Default.Value == nil || binary.Default.Value.Encoding != "base64" || binary.Default.Value.Value == nil || *binary.Default.Value.Value != "/w==" {
					t.Fatal("native structure default did not retain stored binary bytes")
				}
				amount, _ := tableedit.FindColumn(b, "n")
				if amount.Type.Value == nil || amount.Type.Value.Modifiers.Value == nil || amount.Type.Value.Modifiers.Value.Scale == nil || *amount.Type.Value.Modifiers.Value.Scale != 38 {
					t.Fatal("native structure type lost scale38")
				}
				if len(b.Indexes) != 2 {
					t.Fatal("native key/index capture changed")
				}
			}
			again, e := s.StructureLoad(context.Background(), target)
			if e != nil || again.Fingerprint != b.Fingerprint {
				t.Fatal("unchanged complete native structure fingerprint drifted")
			}
			dataRun(t, s, "SET SESSION time_zone='+03:00'")
			changed, e := s.StructureLoad(context.Background(), target)
			if e != nil || changed.Scope == b.Scope || changed.Fingerprint == b.Fingerprint {
				t.Fatal("native scope failed to bind active time zone")
			}
			dataRun(t, s, "SET SESSION time_zone='+00:00'")
			dataRun(t, s, "START TRANSACTION")
			if _, e := s.StructureLoad(context.Background(), target); e == nil {
				t.Fatal("active owner transaction authorized dedicated structure metadata")
			}
			dataRun(t, s, "ROLLBACK")
		})
	}
	name := fmt.Sprintf("g1_missing_%d", time.Now().UnixNano())
	b, e := s.StructureLoad(context.Background(), tableedit.Target{Schema: schema, Table: name, Create: true})
	if e != nil || !tableedit.ValidBaseline(b) || b.Facts.Table.Storage.Value == nil || *b.Facts.Table.Storage.Value != "InnoDB" {
		t.Fatal("missing target did not bind explicit intended native engine")
	}
}
