package mariadb

import (
	"context"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func TestMariaDBDefinitionNativeColumnClone(t *testing.T) {
	for _, mode := range []string{"", "NO_BACKSLASH_ESCAPES"} {
		name := mode
		if name == "" {
			name = "escaped"
		}
		t.Run(name, func(t *testing.T) {
			owner := schemaNativeAdmin(t)
			schemaName := fmt.Sprintf("data_render_%d", owner.connectionID)
			schema := QuoteIdentifier(schemaName)
			dataRun(t, owner, "SET SESSION sql_mode='"+mode+"'")
			dataRun(t, owner, "CREATE DATABASE "+schema+" CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
			t.Cleanup(func() {
				owner.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
			})
			source, clone := schema+".`source`", schema+".`clone`"
			dataRun(t, owner, "CREATE TABLE "+source+"(id BIGINT(20) UNSIGNED NOT NULL AUTO_INCREMENT,n DECIMAL(65,38) DEFAULT 0.125,b VARBINARY(8) DEFAULT x'00ff5c27',v VARCHAR(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT _utf8mb4 X'F09F98807127735C7461696C' INVISIBLE COMMENT 'retained q''s',g DECIMAL(65,38) GENERATED ALWAYS AS(n+1) STORED,bits BIT(8) DEFAULT b'10000001',changed TIMESTAMP(6) NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP(6),PRIMARY KEY(id)) ENGINE=InnoDB")
			dataRun(t, owner, "INSERT INTO "+source+"(id,n) VALUES(9007199254741105,123456789012345678901234567.12345678901234567890123456789012345678),(9007199254741106,NULL)")
			limits := sc.Limits{Nodes: 256, Members: 8192, Bytes: 8 << 20, Scalar: 65536}
			capture := func() sc.Capture {
				sink := sc.NewCollector(context.Background(), limits)
				if e := owner.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{schemaName}, Limits: limits}, sink); e != nil {
					t.Fatalf("native renderer fixture capture failed: %v", e)
				}
				return sink.Capture
			}
			before := capture()
			var table sc.Table
			for _, candidate := range before.Tables {
				if candidate.Ref.Name == "source" {
					table = candidate
				}
			}
			definitions := []string{}
			for _, column := range table.Columns.Items {
				definition, manual, e := RenderStructureColumnWithOptions(context.Background(), column, before.Context.EngineContext, table.Options)
				if e != nil || manual != "" || definition == "" {
					t.Fatalf("native column renderer refused property path: %s", column.Ref.Name)
				}
				definitions = append(definitions, definition)
			}
			if len(definitions) != 7 {
				t.Fatal("native renderer fixture columns incomplete")
			}
			dataRun(t, owner, "CREATE TABLE "+clone+"("+strings.Join(definitions, ",")+",PRIMARY KEY(id)) ENGINE=InnoDB")
			dataRun(t, owner, "INSERT INTO "+clone+"(id,n,b,v,bits,changed) SELECT id,n,b,v,bits,changed FROM "+source)
			query := func(table string) [][]*string {
				return dataRun(t, owner, "SELECT id,n,HEX(b),HEX(v),g,bits+0,changed FROM "+table+" ORDER BY id").Rows
			}
			if !reflect.DeepEqual(query(source), query(clone)) {
				t.Fatal("native rendered clone changed exact retained/generated values")
			}
			after := capture()
			var copied sc.Table
			for _, candidate := range after.Tables {
				if candidate.Ref.Name == "clone" {
					copied = candidate
				}
			}
			if len(copied.Columns.Items) != len(table.Columns.Items) {
				t.Fatal("native rendered column shape changed")
			}
			for i, column := range copied.Columns.Items {
				column.Ref = table.Columns.Items[i].Ref
				if !reflect.DeepEqual(column, table.Columns.Items[i]) {
					t.Fatalf("native rendered metadata changed column property path: %s", column.Ref.Name)
				}
			}
			dataRun(t, owner, "INSERT INTO "+clone+"(n) VALUES(2)")
			rows := dataRun(t, owner, "SELECT HEX(b),HEX(v),bits+0,g FROM "+clone+" WHERE id=9007199254741107").Rows
			if len(rows) != 1 || len(rows[0]) != 4 || rows[0][0] == nil || *rows[0][0] != "00FF5C27" || rows[0][1] == nil || *rows[0][1] != "F09F98807127735C7461696C" || rows[0][2] == nil || *rows[0][2] != "129" {
				t.Fatal("native rendered stored defaults or exact identity counter changed")
			}
		})
	}
}
