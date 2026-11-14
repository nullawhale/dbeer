package mariadb

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func TestMariaDBDataRetainedWireBuffersAreOwned(t *testing.T) {
	c := newCollector(protocol.Command{ResultValues: protocol.NativeResultValuesFormat})
	r := wire.NewResultReserveResultset(1)
	defer r.Close()
	r.Fields = []*wire.Field{{Name: []byte("kept"), Table: []byte("alias"), OrgName: []byte("native"), OrgTable: []byte("origin"), Schema: []byte("schema"), Data: wire.FieldData("metadata"), DefaultValue: []byte("default"), Type: wire.MYSQL_TYPE_BLOB, Charset: 63}}
	if c.columns(r) != nil {
		t.Fatal("wire metadata capture failed")
	}
	raw := []byte{0, 255, 128}
	values := []wire.FieldValue{wire.NewFieldValue(wire.FieldValueTypeString, 0, raw)}
	if c.row(values) != nil {
		t.Fatal("first wire row capture failed")
	}
	for _, bytes := range [][]byte{r.Fields[0].Name, r.Fields[0].Table, r.Fields[0].OrgName, r.Fields[0].OrgTable, r.Fields[0].Schema, r.Fields[0].Data, r.Fields[0].DefaultValue} {
		bytes[0] = 'x'
	}
	raw[0] = 8
	if c.row(values) != nil {
		t.Fatal("second wire row capture failed")
	}
	f := c.originFields[0]
	if string(f.Name) != "kept" || string(f.Table) != "alias" || string(f.OrgName) != "native" || string(f.OrgTable) != "origin" || string(f.Schema) != "schema" || string(f.Data) != "metadata" || string(f.DefaultValue) != "default" || *c.response.Rows[0][0] != "AP+A" || *c.response.NativeValues[0][0].Value != "AP+A" {
		t.Fatal("retained row/native/field metadata aliases a reused driver buffer")
	}
}

func TestMariaDBDataNativeDecimalJSONBinaryAndBinding(t *testing.T) {
	s := dataIntegrationSession(t)
	dataRun(t, s, "CREATE TEMPORARY TABLE native_values(id INT,n DECIMAL(65,38),j JSON,b BLOB,s BIGINT UNSIGNED,p VARCHAR(10)) ENGINE=InnoDB")
	decimal := "123456789012345678901234567." + strings.Repeat("1234567890", 3) + "12345678"
	doc := ` { "a":1, "a":2, "b" :[1,2] } `
	params := []protocol.QueryParameter{myParameter("n", "decimal", decimal), myParameter("j", "text", doc)}
	r := s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: "INSERT INTO native_values VALUES(1,:n,:j,X'00FF80',18446744073709551615,''),(2,:n,:j,X'',0,'NULL')", Parameters: params})
	if r.Type != "query.result" {
		t.Fatal("native65,38/JSON/binary fixture insert failed")
	}
	for _, prepared := range []bool{false, true} {
		command := protocol.Command{Type: "execute", ResultValues: protocol.NativeResultValuesFormat, SQL: "SELECT n,j,b,s,p,NULL AS nil_value FROM native_values ORDER BY id"}
		if prepared {
			command.SQL = "SELECT n,j,b,s,p,NULL AS nil_value FROM native_values WHERE id>=:id ORDER BY id"
			command.Parameters = []protocol.QueryParameter{myParameter("id", "integer", "1")}
		}
		r = s.Execute(context.Background(), command)
		if r.Type != "query.result" || len(r.Rows) != 2 || !protocol.NativeMatrixValid(r.NativeValues, 2, 6) {
			t.Fatal("native text/prepared result is incomplete or invalid")
		}
		for i, row := range r.NativeValues {
			for k, value := range row {
				var facts struct {
					Engine string `json:"engine"`
				}
				if value.Engine != "mariadb" || value.TypeIdentity != r.Columns[k].TypeIdentity {
					t.Fatal("native engine or exact wire identity crossed adapters")
				}
				identity := strings.TrimPrefix(value.TypeIdentity, "unresolved:")
				if json.Unmarshal([]byte(identity), &facts) != nil || facts.Engine != "mariadb" {
					t.Fatal("wire identity facts do not prove MariaDB origin")
				}
			}
			if row[0].Kind != "decimal" || *row[0].Value != decimal || row[1].Kind != "text" || *row[1].Value != doc || row[2].Kind != "binary" || row[5].Kind != "null" {
				t.Fatal("decimal precision, duplicate JSON text, binary or SQL NULL changed")
			}
			wantBytes := []byte{0, 255, 128}
			wantUnsigned := "18446744073709551615"
			wantText := ""
			if i == 1 {
				wantBytes = []byte{}
				wantUnsigned = "0"
				wantText = "NULL"
			}
			if *row[2].Value != base64.StdEncoding.EncodeToString(wantBytes) || row[3].Kind != "integer" || *row[3].Value != wantUnsigned || row[4].Kind != "text" || *row[4].Value != wantText {
				t.Fatal("empty binary, unsigned integer or empty/text-NULL changed")
			}
		}
	}
}

type dataNativeSink struct {
	first     []protocol.NativeValue
	rows      int
	failAfter int
	slow      bool
}

func (*dataNativeSink) Begin(int, []protocol.Column) error { return nil }
func (s *dataNativeSink) NativeRow(_ int, values []protocol.NativeValue) error {
	if s.first == nil {
		s.first = values
	}
	return nil
}
func (s *dataNativeSink) Row(_ int, _ []*string) error {
	s.rows++
	if s.slow && s.rows <= 3 {
		time.Sleep(time.Millisecond)
	}
	if s.failAfter > 0 && s.rows == s.failAfter {
		return errors.New("synthetic sink failure")
	}
	return nil
}
func (*dataNativeSink) End(int, protocol.ResultSet) error { return nil }

func TestMariaDBDataNativeStreamOwnershipAndSinkFailureDrain(t *testing.T) {
	s := dataIntegrationSession(t)
	sql := "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<1000) SELECT n,REPEAT('x',1024) FROM seq CROSS JOIN (SELECT 1 AS pair UNION ALL SELECT 2) pairs LIMIT 1301"
	for _, failed := range []bool{false, true} {
		sink := &dataNativeSink{slow: true}
		if failed {
			sink.failAfter = 2
		}
		r := s.ExecuteWithSink(context.Background(), protocol.Command{Type: "execute", ResultValues: protocol.NativeResultValuesFormat, SQL: sql}, sink)
		want := 1301
		if failed {
			want = 2
		}
		if r.Type != "query.result" || r.RowCount != 1301 || sink.rows != want || s.closed.Load() || len(sink.first) != 2 || sink.first[1].Value == nil || *sink.first[1].Value != strings.Repeat("x", 1024) {
			t.Fatal("stream backpressure/sink failure lost rows, borrowed bytes or native completion")
		}
		if *dataRun(t, s, "SELECT 1").Rows[0][0] != "1" {
			t.Fatal("sink failure left unread protocol packets")
		}
	}
}

func TestMariaDBDataNativeProcedureResultsDrain(t *testing.T) {
	s := dataIntegrationSession(t)
	name := dataQuoteIdentifier(fmt.Sprintf("dbeer_data_proc_%d", s.connectionID))
	dataRun(t, s, "CREATE PROCEDURE "+name+"(IN p BIGINT) BEGIN SELECT p AS first_value;SELECT p+1 AS second_value;END")
	defer dataRun(t, s, "DROP PROCEDURE IF EXISTS "+name)
	for _, prepared := range []bool{false, true} {
		command := protocol.Command{Type: "execute", ResultValues: protocol.NativeResultValuesFormat, SQL: "CALL " + name + "(7)"}
		if prepared {
			command.SQL = "CALL " + name + "(:p)"
			command.Parameters = []protocol.QueryParameter{myParameter("p", "integer", "7")}
		}
		r := s.Execute(context.Background(), command)
		if r.Type != "query.result" || len(r.ResultSets) != 3 || len(r.ResultSets[0].Rows) != 1 || len(r.ResultSets[1].Rows) != 1 || *r.ResultSets[0].Rows[0][0] != "7" || *r.ResultSets[1].Rows[0][0] != "8" || !protocol.NativeMatrixValid(r.ResultSets[0].NativeValues, 1, 1) || !protocol.NativeMatrixValid(r.ResultSets[1].NativeValues, 1, 1) {
			t.Fatal("CALL text/prepared/native result boundaries were not retained")
		}
		if *dataRun(t, s, "SELECT 1").Rows[0][0] != "1" {
			t.Fatal("CALL left unread terminal packets")
		}
	}
}
