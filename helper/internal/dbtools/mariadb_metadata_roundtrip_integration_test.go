package dbtools

import (
	"dbeer/helper/internal/mariadb"
	"dbeer/helper/internal/protocol"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestMariaDBRealToolsNativeMetadataRoundtrip(t *testing.T) {
	for _, test := range []struct{ name, definition, values string }{
		{"binaryDomain", "e ENUM(x'ff',x'00',x'4e554c4c') CHARACTER SET binary DEFAULT x'ff'", "(1,x'ff'),(2,x'00'),(3,x'4e554c4c')"},
		{"wideDomain", "e ENUM('😀','ordinary') CHARACTER SET utf8mb4 DEFAULT '😀'", "(1,'😀'),(2,'ordinary')"},
		{"binaryDefault", "e VARBINARY(8) DEFAULT x'00ff5c27'", "(1,x'00ff5c27'),(2,x'')"},
		{"wideDefault", "e VARCHAR(16) CHARACTER SET utf8mb4 DEFAULT '😀'", "(1,'😀'),(2,'ordinary')"},
		{"safeDefault", "e VARCHAR(16) CHARACTER SET utf8mb4 DEFAULT 'retained'", "(1,'retained'),(2,'ordinary')"},
	} {
		t.Run(test.name, func(t *testing.T) {
			settings, bin, session := mariaDBToolFixture(t)
			table := fmt.Sprintf("data_tool_domain_%d", time.Now().UnixNano())
			quoted := "`" + table + "`"
			mariaDBToolRun(t, session, "CREATE TABLE "+quoted+"(id INT PRIMARY KEY,"+test.definition+") ENGINE=InnoDB")
			t.Cleanup(func() { mariaDBToolRun(t, session, "DROP TABLE IF EXISTS "+quoted) })
			mariaDBToolRun(t, session, "INSERT INTO "+quoted+" VALUES"+test.values)
			mariaDBToolRun(t, session, "INSERT INTO "+quoted+"(id) VALUES(4)")
			capture := func() [][]*string {
				return mariaDBToolRun(t, session, "SELECT id,HEX(e) FROM "+quoted+" ORDER BY id").Rows
			}
			before := capture()
			manager, e := New(mariadb.Open, Options{Root: t.TempDir()})
			if e != nil {
				t.Fatal("native metadata utility manager unavailable")
			}
			defer manager.Close()
			path := filepath.Join(t.TempDir(), "native-domain.sql")
			if test.name == "binaryDomain" || test.name == "wideDomain" || test.name == "wideDefault" {
				result := manager.Handle(protocol.Command{Type: "dbtools.preview", DatabaseTools: &protocol.DatabaseToolsRequest{Connection: &settings, Operation: "dump", Format: "sql", Path: path, ToolPath: filepath.Join(bin, expectedTool("mariadb", "dump", "sql"))}})
				if result.DatabaseTools != nil || result.Category != "databaseTools" || (!strings.Contains(result.Message, "label domains") && !strings.Contains(result.Message, "literal text default")) {
					t.Fatal("known lossy native dump metadata was authorized")
				}
				if !reflect.DeepEqual(before, capture()) {
					t.Fatal("refused dump changed original rows")
				}
				return
			}

			dump := mariaDBToolPreview(t, manager, settings, bin, "dump", path)
			done := await(t, manager, start(t, manager, dump))
			if done.State != "completed" {
				t.Fatalf("native metadata dump did not complete: state=%s", done.State)
			}
			mariaDBToolCloseJob(manager, done)
			mariaDBToolRun(t, session, "DROP TABLE "+quoted)
			restore := mariaDBToolPreview(t, manager, settings, bin, "restore", path)
			done = await(t, manager, start(t, manager, restore))
			if done.State != "completed" {
				t.Fatalf("native metadata restore did not complete: state=%s", done.State)
			}
			mariaDBToolCloseJob(manager, done)
			if !reflect.DeepEqual(before, capture()) {
				t.Fatal("native dump lost label domains, stored defaults or exact text")
			}
			mariaDBToolRun(t, session, "INSERT INTO "+quoted+"(id) VALUES(5)")
			rows := mariaDBToolRun(t, session, "SELECT HEX(e) FROM "+quoted+" WHERE id=5").Rows
			if len(rows) != 1 || len(rows[0]) != 1 || !reflect.DeepEqual(rows[0][0], before[len(before)-1][1]) {
				t.Fatal("restored native stored default record changed")
			}
			if session.TransactionStatus() != "idle" {
				t.Fatal("native metadata utility altered the owning transaction")
			}
		})
	}
}
