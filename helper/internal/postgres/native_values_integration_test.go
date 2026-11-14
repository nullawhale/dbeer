package postgres

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"dbeer/helper/internal/exportfile"
	"dbeer/helper/internal/protocol"
)

func TestNativePostgresActualTypedRowsAndCompleteExport(t *testing.T) {
	f := newChangeFixture(t)
	session := &Session{conn: f.conn}
	command := protocol.Command{Type: "execute", RequestID: "native", ResultValues: protocol.NativeResultValuesFormat,
		SQL: `SELECT 9007199254740993.00000001::numeric, decode('00ff','hex'),NULL::text,''::text,'NULL'::text,'[0:1]={1,2}'::integer[],'-0'::real`}
	result := session.Execute(context.Background(), command)
	if result.Type != "query.result" || len(result.Rows) != 1 || !protocol.NativeMatrixValid(result.NativeValues, 1, 7) {
		t.Fatal("actual native result missing")
	}
	row := result.NativeValues[0]
	if row[0].Kind != "decimal" || *row[0].Value != "9007199254740993.00000001" || row[1].Kind != "binary" || *row[1].Value != "AP8=" || row[2].Kind != "null" || *row[3].Value != "" || *row[4].Value != "NULL" || row[5].Kind != "native" || *row[5].Value != "[0:1]={1,2}" || row[6].Kind != "float32" || *row[6].Value != "80000000" || !row[6].Comparable() {
		t.Fatal("actual native storage/wire values changed")
	}
	f.exec("CREATE TABLE " + f.table("native_browse") + "(id integer PRIMARY KEY,value numeric(40,9),items integer[]);INSERT INTO " + f.table("native_browse") + " VALUES(1,9007199254740993.000000001,'[0:1]={1,2}')")
	browse := session.Execute(context.Background(), protocol.Command{Type: "catalog", RequestID: "browse", ResultValues: protocol.NativeResultValuesFormat, Catalog: &protocol.CatalogRequest{Kind: "browse", Schema: f.schema, Object: "native_browse", ObjectKind: "table"}})
	if browse.Type != "query.result" || len(browse.Rows) != 1 || !protocol.NativeMatrixValid(browse.NativeValues, 1, 3) || browse.NativeValues[0][1].Kind != "decimal" || *browse.NativeValues[0][1].Value != "9007199254740993.000000001" || browse.NativeValues[0][2].Kind != "native" || *browse.NativeValues[0][2].Value != "[0:1]={1,2}" {
		t.Fatal("typed PostgreSQL browse changed native values")
	}
	path := filepath.Join(t.TempDir(), "complete.json")
	writer, err := exportfile.NewWithNative(protocol.ExportRequest{Path: path, Format: "json"}, true)
	if err != nil {
		t.Fatal("export create")
	}
	defer writer.Abort()
	command.SQL = "SELECT n,repeat('x',2048) FROM generate_series(1,2500)n"
	result = session.ExecuteWithSink(context.Background(), command, writer)
	if result.Type != "query.result" || result.RowCount != 2500 || !result.Truncated || len(result.NativeValues) != len(result.Rows) || len(result.Rows) >= 2500 || writer.Commit() != nil {
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
	if len(set.Rows) != 2500 || set.Metadata.RowCount != 2500 || set.Metadata.DisplayedRowCount != 2500 || set.Metadata.Truncated || set.Rows[2499].NativeValues[0].Kind != "integer" || *set.Rows[2499].NativeValues[0].Value != "2500" || len(data) <= protocol.MaxNativeValueBytes {
		t.Fatal("complete export inherited display cap or changed exact final row")
	}
	command.ResultValues = ""
	command.SQL = "SELECT 1"
	if result = session.Execute(context.Background(), command); result.Type != "query.result" || result.NativeValues != nil {
		t.Fatal("legacy PostgreSQL ABI acquired unsolicited values")
	}
}

func TestNativePostgresBinaryFloatEvidenceIgnoresRoundedSessionOutput(t *testing.T) {
	f := newChangeFixture(t)
	if _, err := f.conn.Exec(context.Background(), "SET extra_float_digits=-3"); err != nil {
		t.Fatal("rounded session setup failed")
	}
	session := &Session{conn: f.conn}
	sql := "SELECT 1.234567890123456::float8,1.234567890123457::float8"
	legacy := session.Execute(context.Background(), protocol.Command{Type: "execute", RequestID: "legacy", SQL: sql})
	if legacy.Type != "query.result" || len(legacy.Rows) != 1 || *legacy.Rows[0][0] != *legacy.Rows[0][1] || !strings.HasPrefix(legacy.Columns[0].TypeIdentity, "unresolved:") || legacy.NativeValues != nil {
		t.Fatal("legacy rounded output changed")
	}
	result := session.Execute(context.Background(), protocol.Command{Type: "execute", RequestID: "binary", ResultValues: protocol.NativeResultValuesFormat, SQL: sql})
	if result.Type != "query.result" || len(result.NativeValues) != 1 || len(result.NativeValues[0]) != 2 {
		t.Fatal("binary typed output unavailable")
	}
	left, right := result.NativeValues[0][0], result.NativeValues[0][1]
	if left.Kind != "float64" || right.Kind != "float64" || left.Value == nil || right.Value == nil || *left.Value == *right.Value || !left.Comparable() || !right.Comparable() || strings.HasPrefix(left.TypeIdentity, "unresolved:") {
		t.Fatal("binary evidence inherited rounded output or lost distinct stored bits")
	}
	var digits string
	if f.conn.QueryRow(context.Background(), "SELECT current_setting('extra_float_digits')").Scan(&digits) != nil || digits != "-3" {
		t.Fatal("typed result changed caller precision setting")
	}
}

func TestNativePostgresFiniteFloatOriginalUsesExactBitsDuringPreviewApply(t *testing.T) {
	f := newChangeFixture(t)
	f.exec("CREATE TABLE " + f.table("native_floats") + "(id integer PRIMARY KEY,value real);INSERT INTO " + f.table("native_floats") + " VALUES(1,'-0'::real)")
	session := &Session{conn: f.conn}
	browse := protocol.Command{Type: "catalog", RequestID: "browse", ResultValues: protocol.NativeResultValuesFormat, Catalog: &protocol.CatalogRequest{Kind: "browse", Schema: f.schema, Object: "native_floats", ObjectKind: "table"}}
	before := session.Execute(context.Background(), browse)
	if before.Type != "query.result" || len(before.NativeValues) != 1 || len(before.StorageTokens) != 1 || before.NativeValues[0][1].Kind != "float32" || *before.NativeValues[0][1].Value != "80000000" {
		t.Fatal("float original storage evidence unavailable")
	}
	one, negativeZero, next := "1", "-0.0", "1.5"
	request := protocol.ChangesRequest{Schema: f.schema, Table: "native_floats", Columns: []protocol.SnapshotColumn{{Name: "id", Engine: "postgresql", NativeType: "integer"}, {Name: "value", Engine: "postgresql", NativeType: "real"}}, Changes: []protocol.RowChange{{Kind: "update", Original: []protocol.CellValue{{Kind: "text", Value: &one}, {Kind: "text", Value: &negativeZero}}, StorageToken: before.StorageTokens[0], Values: []protocol.ColumnAssignment{{Column: "value", Value: protocol.CellValue{Kind: "text", Value: &next}}}}}}
	if preview := session.Execute(context.Background(), protocol.Command{Type: "changes.preview", RequestID: "preview", Changes: &request}); preview.Type != "query.result" {
		t.Fatal("typed float preview failed")
	}
	unchanged := session.Execute(context.Background(), browse)
	if unchanged.Type != "query.result" || *unchanged.NativeValues[0][1].Value != "80000000" {
		t.Fatal("preview changed float storage")
	}
	if applied := session.Execute(context.Background(), protocol.Command{Type: "changes.apply", RequestID: "apply", Changes: &request}); applied.Type != "query.result" {
		t.Fatal("typed float apply failed")
	}
	after := session.Execute(context.Background(), browse)
	if after.Type != "query.result" || *after.NativeValues[0][1].Value != "3fc00000" {
		t.Fatal("typed float binding did not round trip")
	}
}
