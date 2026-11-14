package mariadb

import (
	"context"
	"encoding/base64"
	"testing"

	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func TestMariaDBRowsNativeLiveUUIDInetAndGeometryRoundTrip(t *testing.T) {
	s := dataIntegrationSession(t)
	name, qualified := rowFixture(t, s, "(id INT PRIMARY KEY,u UUID,a INET4,b INET6,p POINT) ENGINE=InnoDB")
	dataRun(t, s, "INSERT INTO "+qualified+" VALUES(1,'550e8400-e29b-41d4-a716-446655440000','192.0.2.1','2001:db8::1',ST_GeomFromText('POINT(1.25 2.5)',4326))")
	r, err := s.work.client.Execute("SELECT u,a,b,p FROM " + qualified)
	if err != nil || r.RowNumber() != 1 {
		t.Fatal("native UUID/INET/geometry value fixture unavailable")
	}
	expected := []string{"550e8400-e29b-41d4-a716-446655440000", "192.0.2.1", "2001:db8::1"}
	for i, want := range expected {
		if r.Values[0][i].Type != wire.FieldValueTypeString || binaryColumn(r.Fields[i]) || string(r.Values[0][i].AsString()) != want {
			t.Fatal("native UUID/INET wire representation is not the proved canonical text form")
		}
		switch r.Fields[i].Type {
		case wire.MYSQL_TYPE_STRING, wire.MYSQL_TYPE_VAR_STRING, wire.MYSQL_TYPE_VARCHAR:
		default:
			t.Fatal("native UUID/INET did not use the proved string wire family")
		}
	}
	if !binaryColumn(r.Fields[3]) || r.Fields[3].Type != wire.MYSQL_TYPE_GEOMETRY || len(r.Values[0][3].AsString()) != 25 {
		t.Fatal("native geometry did not retain its SRID plus WKB internal bytes")
	}
	geometry := base64.StdEncoding.EncodeToString(r.Values[0][3].AsString())
	r.Close()
	request := rowRequest(t, s, name, 1)
	request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "u", Value: rowCell("550e8400-e29b-41d4-a716-446655440001")}, {Column: "a", Value: rowCell("192.0.2.2")}, {Column: "b", Value: rowCell("::ffff:192.0.2.2")}, {Column: "p", Value: protocol.CellValue{Kind: "binary", Value: &geometry}}}
	if out := rowApply(t, s, request); out.Type != "query.result" {
		t.Fatalf("native UUID/INET/geometry writer refused exact native values: %s/%s", out.Category, out.SQLState)
	}
	actual := s.Execute(context.Background(), protocol.Command{SQL: "SELECT u,a,b,ST_SRID(p),ST_AsText(p) FROM " + qualified, ResultValues: protocol.NativeResultValuesFormat})
	if len(actual.NativeValues) != 1 || len(actual.NativeValues[0]) != 5 {
		t.Fatal("native UUID/INET round trip omitted its exact native value matrix")
	}
	want := []string{"550e8400-e29b-41d4-a716-446655440001", "192.0.2.2", "::ffff:192.0.2.2", "4326", "POINT(1.25 2.5)"}
	for i, value := range want {
		if actual.Rows[0][i] == nil || *actual.Rows[0][i] != value {
			t.Fatal("native UUID/INET or geometry coordinates/SRID changed during a bound write")
		}
	}
	importRequest := protocol.TableImportRequest{Schema: request.Schema, Table: name}
	description := importCommand(s, "import.describe", &importRequest)
	if description.TableImport == nil {
		t.Fatal("native UUID/INET/geometry import metadata unavailable")
	}
	importRequest.Fingerprint = description.TableImport.Fingerprint
	importRequest.Columns = []string{"id", "u", "a", "b", "p"}
	importRequest.Rows = [][]protocol.CellValue{{rowCell("2"), rowCell(want[0]), rowCell(want[1]), rowCell(want[2]), {Kind: "binary", Value: &geometry}}}
	if out := importCommand(s, "import.apply", &importRequest); out.Type != "import.apply.result" {
		t.Fatalf("native UUID/INET/geometry import refused exact native values: %s/%s", out.Category, out.SQLState)
	}
	actual = dataRun(t, s, "SELECT HEX(p),ST_SRID(p) FROM "+qualified+" ORDER BY id")
	if len(actual.Rows) != 2 || *actual.Rows[0][0] != *actual.Rows[1][0] || *actual.Rows[0][1] != "4326" || *actual.Rows[1][1] != "4326" {
		t.Fatal("native geometry internal bytes were confused with plain WKB during import")
	}
}
