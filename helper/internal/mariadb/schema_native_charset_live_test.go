package mariadb

import (
	"context"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"fmt"
	"testing"
)

func TestMariaDBSchemaNativeTextDefaultCharsets(t *testing.T) {
	owner := schemaNativeAdmin(t)
	name := fmt.Sprintf("data_charset_%d", owner.connectionID)
	schema := QuoteIdentifier(name)
	dataRun(t, owner, "CREATE DATABASE "+schema+" CHARACTER SET utf8mb4")
	t.Cleanup(func() {
		owner.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
	})
	dataRun(t, owner, "CREATE TABLE "+schema+".`t`(id INT,l VARCHAR(8) CHARACTER SET latin1 DEFAULT _latin1 X'C3A9',u VARCHAR(8) CHARACTER SET utf16 DEFAULT _utf16 X'00C300A9',c VARCHAR(8) CHARACTER SET ucs2 DEFAULT _ucs2 X'00E9') ENGINE=InnoDB")
	dataRun(t, owner, "INSERT INTO "+schema+".`t`(id) VALUES(1),(2)")
	limits := sc.Limits{Nodes: 256, Members: 8192, Bytes: 8 << 20, Scalar: 65536}
	sink := sc.NewCollector(context.Background(), limits)
	if e := owner.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, sink); e != nil {
		t.Fatalf("native charset default metadata unavailable: %v", e)
	}
	if len(sink.Capture.Tables) != 1 {
		t.Fatal("native charset fixture missing")
	}
	expected := map[string]string{"l": "Ã©", "u": "Ã©", "c": "é"}
	seen := 0
	for _, column := range sink.Capture.Tables[0].Columns.Items {
		if value, present := expected[column.Ref.Name]; present {
			seen++
			if column.Default.Value == nil || column.Default.Value.Encoding != "text" || column.Default.Value.Value == nil || *column.Default.Value.Value != value {
				t.Fatal("native source-charset default was reinterpreted as merely valid UTF8")
			}
		}
	}
	if seen != len(expected) {
		t.Fatal("native charset default columns incomplete")
	}
}
