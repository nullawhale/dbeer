package mysql

import (
	"context"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/resultsource"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func mysqlOriginField(name string, kind byte) *wire.Field {
	return &wire.Field{Schema: []byte("test"), OrgTable: []byte("records"), OrgName: []byte(name), Name: []byte("misleading label"), Type: kind, Charset: 45, Decimal: 31}
}

func TestMySQLResultSourceRequiresServerOrigins(t *testing.T) {
	selection, reason := resultsource.Parse("SELECT r.id AS value FROM test.records AS r", "mysql")
	if reason != "" {
		t.Fatal("supported SELECT was refused")
	}
	field := mysqlOriginField("id", wire.MYSQL_TYPE_LONG)
	if schema, table, ok := mysqlResultOrigin(selection, []*wire.Field{field}); !ok || schema != "test" || table != "records" {
		t.Fatal("server origin was replaced by a display label")
	}
	for _, mutation := range []func(*wire.Field){
		func(f *wire.Field) { f.OrgName = nil },
		func(f *wire.Field) { f.OrgTable = []byte("view") },
		func(f *wire.Field) { f.Schema = []byte("other") },
	} {
		copy := *field
		mutation(&copy)
		if _, _, ok := mysqlResultOrigin(selection, []*wire.Field{&copy}); ok {
			t.Fatal("untrusted or mismatched server origin was accepted")
		}
	}
}

func TestMySQLResultSourcePreservesCanonicalOrderAndExactKey(t *testing.T) {
	metadata := []mysqlSourceColumn{
		{name: "id", nativeType: "bigint unsigned", dataType: "bigint", primaryKey: 1},
		{name: "part", nativeType: "varbinary(8)", dataType: "varbinary", primaryKey: 2},
		{name: "amount", nativeType: "decimal(40,20)", dataType: "decimal"},
		{name: "computed", nativeType: "int", dataType: "int", generated: true},
	}
	fields := []*wire.Field{mysqlOriginField("amount", wire.MYSQL_TYPE_NEWDECIMAL), mysqlOriginField("part", wire.MYSQL_TYPE_VAR_STRING), mysqlOriginField("computed", wire.MYSQL_TYPE_LONG), mysqlOriginField("id", wire.MYSQL_TYPE_LONGLONG)}
	fields[1].Charset = 63
	fields[3].Flag = wire.UNSIGNED_FLAG
	source := mysqlSourceForFields("test", "records", fields, metadata)
	if source.ReadOnlyReason != "" || len(source.Columns) != 4 || source.Columns[0].Name != "amount" || source.Columns[0].TableIndex != 2 || source.Columns[1].PrimaryKey != 2 || source.Columns[3].PrimaryKey != 1 || source.Columns[2].Editable || !source.Columns[2].Generated || source.Columns[3].NativeType != "bigint unsigned" {
		t.Fatal("exact full projection lost its canonical mapping, generated state or composite key")
	}
	partial := mysqlSourceForFields("test", "records", []*wire.Field{fields[1], fields[3]}, metadata)
	if partial.Table != "records" || len(partial.Columns) != 2 || partial.ReadOnlyReason == "" {
		t.Fatal("full-key projection did not retain navigation separately from edit permission")
	}
	missing := mysqlSourceForFields("test", "records", []*wire.Field{fields[3]}, metadata)
	if missing.Table != "" || len(missing.Columns) != 0 || missing.ReadOnlyReason == "" {
		t.Fatal("incomplete composite key gained source navigation")
	}
}

func TestMySQLResultSourceRejectsMissingAmbiguousAndLossyEvidence(t *testing.T) {
	metadata := []mysqlSourceColumn{{name: "id", nativeType: "int", dataType: "int", primaryKey: 1}, {name: "value", nativeType: "float", dataType: "float"}}
	id, value := mysqlOriginField("id", wire.MYSQL_TYPE_LONG), mysqlOriginField("value", wire.MYSQL_TYPE_FLOAT)
	source := mysqlSourceForFields("test", "records", []*wire.Field{id, value}, metadata)
	if source.Table != "records" || !strings.Contains(source.ReadOnlyReason, "storage evidence") {
		t.Fatal("lossy non-key value was editable or prevented exact-key navigation")
	}
	metadata[0].dataType, metadata[0].nativeType = "float", "float"
	id.Type = wire.MYSQL_TYPE_FLOAT
	if unsafe := mysqlSourceForFields("test", "records", []*wire.Field{id, value}, metadata); unsafe.Table != "" {
		t.Fatal("lossy primary key gained source navigation")
	}
	metadata[0] = mysqlSourceColumn{name: "id", nativeType: "int", dataType: "int", primaryKey: 1}
	id.Type = wire.MYSQL_TYPE_LONG
	for _, fields := range [][]*wire.Field{{id, id}, {mysqlOriginField("absent", wire.MYSQL_TYPE_LONG)}} {
		if ambiguous := mysqlSourceForFields("test", "records", fields, metadata); ambiguous.Table != "" || ambiguous.ReadOnlyReason == "" {
			t.Fatal("ambiguous origin gained source navigation")
		}
	}
	metadata[0].primaryKey = 0
	if keyless := mysqlSourceForFields("test", "records", []*wire.Field{id, value}, metadata); keyless.Table != "" || keyless.ReadOnlyReason == "" {
		t.Fatal("keyless table gained source navigation")
	}
}

func TestMySQLResultSourceUnsupportedSQLDoesNotReadMetadata(t *testing.T) {
	collector := newCollector(protocol.Command{})
	if err := (&Session{}).attachResultSource(context.Background(), "SELECT 1 AS id", collector); err != nil || collector.response.Source == nil || collector.response.Source.ReadOnlyReason == "" {
		t.Fatal("unsupported SQL required a connection or acquired editable provenance")
	}
}

func TestMySQLResultSourceBoundsNativeMetadataBeforeSerialization(t *testing.T) {
	metadata := []mysqlSourceColumn{{name: "id", nativeType: "int", dataType: "int", primaryKey: 1}, {name: "choice", nativeType: strings.Repeat("x", 16_385), dataType: "enum"}}
	source := mysqlSourceForFields("test", "records", []*wire.Field{mysqlOriginField("id", wire.MYSQL_TYPE_LONG), mysqlOriginField("choice", wire.MYSQL_TYPE_ENUM)}, metadata)
	if source.Table != "" || len(source.Columns) != 0 || source.ReadOnlyReason == "" {
		t.Fatal("oversized source metadata would reject an otherwise valid query result at the client")
	}
}

func TestMySQLResultSourceMetadataTransportFailurePreservesCompletedRead(t *testing.T) {
	c := newCollector(protocol.Command{RequestID: "read", SessionID: "s", QueryID: "q"})
	result := wire.NewResultReserveResultset(1)
	defer result.Close()
	result.Fields = []*wire.Field{mysqlOriginField("id", wire.MYSQL_TYPE_LONGLONG)}
	if err := c.columns(result); err != nil {
		t.Fatal("test result metadata failed")
	}
	if err := c.row([]wire.FieldValue{wire.NewFieldValue(wire.FieldValueTypeUnsigned, ^uint64(0), nil)}); err != nil {
		t.Fatal("test row failed")
	}
	c.sourceReadCompleted = true
	failure := c.attachResults(protocol.Response{Type: "error", Category: "connection", OutcomeUnknown: true, TransactionStatus: "unknown"})
	if failure.OutcomeUnknown || !failure.SQLCompleted || len(failure.ResultSets) != 1 || len(failure.ResultSets[0].Rows) != 1 || *failure.ResultSets[0].Rows[0][0] != "18446744073709551615" || failure.ResultSets[0].Source == nil || failure.ResultSets[0].Source.Table != "" {
		t.Fatal("supplemental metadata failure lost a completed exact SELECT or exposed editable provenance")
	}
}
