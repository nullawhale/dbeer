package mysql

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"dbeer/helper/internal/exportfile"
	"dbeer/helper/internal/protocol"
)

func TestNativeMySQLActualTypedRowsAndCompleteExport(t *testing.T) {
	session := integrationSession(t)
	command := protocol.Command{Type: "execute", RequestID: "native", ResultValues: protocol.NativeResultValuesFormat,
		SQL: `SELECT CAST(18446744073709551615 AS UNSIGNED),CAST('9007199254740993.000000001' AS DECIMAL(30,9)),X'00ff',NULL,'','NULL'`}
	result := session.Execute(context.Background(), command)
	if result.Type != "query.result" || len(result.Rows) != 1 || !protocol.NativeMatrixValid(result.NativeValues, 1, 6) {
		t.Fatal("actual native result missing")
	}
	row := result.NativeValues[0]
	if row[0].Kind != "integer" || *row[0].Value != "18446744073709551615" || row[1].Kind != "decimal" || *row[1].Value != "9007199254740993.000000001" || row[2].Kind != "binary" || *row[2].Value != "AP8=" || row[3].Kind != "null" || *row[4].Value != "" || *row[5].Value != "NULL" {
		t.Fatal("actual native storage/wire values changed")
	}
	name := fmt.Sprintf("dbeer_native_export_%x", session.connectionID)
	quoted := QuoteIdentifier(name)
	run(t, session, "CREATE TABLE "+quoted+"(id INT PRIMARY KEY,value TEXT) ENGINE=InnoDB")
	t.Cleanup(func() { run(t, session, "DROP TABLE IF EXISTS "+quoted) })
	run(t, session, "INSERT INTO "+quoted+" SELECT a.n+10*b.n+100*c.n,REPEAT('x',4096) FROM (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)a CROSS JOIN (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)b CROSS JOIN (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11)c")
	browse := session.Execute(context.Background(), protocol.Command{Type: "catalog", RequestID: "browse", ResultValues: protocol.NativeResultValuesFormat, Catalog: &protocol.CatalogRequest{Kind: "browse", Schema: integrationSettings(t).Database, Object: name, ObjectKind: "table"}})
	if browse.Type != "query.result" || len(browse.Rows) != 200 || !protocol.NativeMatrixValid(browse.NativeValues, 200, 2) || browse.NativeValues[0][0].Kind != "integer" || *browse.NativeValues[0][0].Value != "0" || browse.NativeValues[199][0].Kind != "integer" || *browse.NativeValues[199][0].Value != "199" {
		t.Fatal("typed MySQL browse changed native values")
	}
	path := filepath.Join(t.TempDir(), "complete.json")
	writer, err := exportfile.NewWithNative(protocol.ExportRequest{Path: path, Format: "json"}, true)
	if err != nil {
		t.Fatal("export create")
	}
	defer writer.Abort()
	command.SQL = "SELECT id,value FROM " + quoted + " ORDER BY id"
	result = session.ExecuteWithSink(context.Background(), command, writer)
	if result.Type != "query.result" || result.RowCount != 1200 || !result.Truncated || len(result.NativeValues) != len(result.Rows) || len(result.Rows) >= 1200 || writer.Commit() != nil {
		t.Fatal("full typed execution/export failed or lost display pairing")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("export read")
	}
	var document struct {
		Version            int
		NativeValuesFormat string
		ResultSets         []struct {
			Rows []struct {
				Values       []*string
				NativeValues []protocol.NativeValue
			}
			Metadata struct {
				RowCount          int64
				DisplayedRowCount int64
				Truncated         bool
			}
		}
	}
	if json.Unmarshal(data, &document) != nil || document.Version != 2 || document.NativeValuesFormat != "nativeV1" || len(document.ResultSets) != 1 {
		t.Fatal("typed export document invalid")
	}
	set := document.ResultSets[0]
	if len(set.Rows) != 1200 || set.Metadata.RowCount != 1200 || set.Metadata.DisplayedRowCount != 1200 || set.Metadata.Truncated || set.Rows[1199].NativeValues[0].Kind != "integer" || *set.Rows[1199].NativeValues[0].Value != "1199" || len(data) <= protocol.MaxNativeValueBytes {
		t.Fatal("complete export inherited display cap or changed exact final row")
	}
	command.ResultValues = ""
	command.SQL = "SELECT 1"
	if result = session.Execute(context.Background(), command); result.Type != "query.result" || result.NativeValues != nil {
		t.Fatal("legacy MySQL ABI acquired unsolicited values")
	}
}
