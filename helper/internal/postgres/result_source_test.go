package postgres

import (
	"testing"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestPostgresResultSourceUsesAttributesAndCanonicalOrder(t *testing.T) {
	metadata := []postgresSourceColumn{
		{attribute: 1, oid: 20, column: protocol.ResultSourceColumn{Name: "id", NativeType: "bigint", TableIndex: 0, PrimaryKey: 1, Editable: true}},
		{attribute: 3, oid: 17, column: protocol.ResultSourceColumn{Name: "key", NativeType: "bytea", TableIndex: 1, PrimaryKey: 2, Editable: true}},
		{attribute: 4, oid: 25, column: protocol.ResultSourceColumn{Name: "note", NativeType: "text", TableIndex: 2, Editable: true}},
	}
	fields := []pgconn.FieldDescription{
		{Name: "duplicate label", TableOID: 99, TableAttributeNumber: 4, DataTypeOID: 25},
		{Name: "duplicate label", TableOID: 99, TableAttributeNumber: 3, DataTypeOID: 17},
		{Name: "not id", TableOID: 99, TableAttributeNumber: 1, DataTypeOID: 20},
	}
	source := mapPostgresResultSource("schema", "records", fields, metadata)
	if source.ReadOnlyReason != "" || source.Schema != "schema" || source.Table != "records" || len(source.Columns) != 3 || source.Columns[0].Name != "note" || source.Columns[0].TableIndex != 2 || source.Columns[1].PrimaryKey != 2 || source.Columns[2].NativeType != "bigint" {
		t.Fatal("source mapping relied on labels or contiguous attribute numbers")
	}
	partial := mapPostgresResultSource("schema", "records", fields[1:], metadata)
	if partial.Table != "records" || partial.ReadOnlyReason == "" || len(partial.Columns) != 2 {
		t.Fatal("full key projection did not retain read-only source navigation")
	}
	for _, bad := range [][]pgconn.FieldDescription{
		fields[:2],
		{fields[1], fields[1], fields[2]},
		{{Name: "id", TableOID: 99, TableAttributeNumber: 1, DataTypeOID: 25}, fields[1], fields[0]},
		{{Name: "id", TableOID: 99, TableAttributeNumber: 0, DataTypeOID: 20}, fields[1], fields[0]},
	} {
		if denied := mapPostgresResultSource("schema", "records", bad, metadata); denied.Table != "" || denied.ReadOnlyReason == "" {
			t.Fatal("incomplete, repeated, changed or computed source was trusted")
		}
	}
	metadata[0].column.PrimaryKey, metadata[1].column.PrimaryKey = 0, 0
	if source := mapPostgresResultSource("schema", "records", fields, metadata); source.Table != "" || source.ReadOnlyReason == "" {
		t.Fatal("keyless table exposed source actions")
	}
}

func TestPostgresSourceFieldsDetectChangedOrigins(t *testing.T) {
	before := []pgconn.FieldDescription{{Name: "value", TableOID: 99, TableAttributeNumber: 1, DataTypeOID: 23, TypeModifier: -1}}
	if !samePostgresSourceFields(before, before) || samePostgresSourceFields(before, nil) {
		t.Fatal("source field identity changed")
	}
	for _, mutation := range []func(*pgconn.FieldDescription){
		func(f *pgconn.FieldDescription) { f.TableOID++ },
		func(f *pgconn.FieldDescription) { f.TableAttributeNumber++ },
		func(f *pgconn.FieldDescription) { f.DataTypeOID++ },
		func(f *pgconn.FieldDescription) { f.TypeModifier++ },
		func(f *pgconn.FieldDescription) { f.Name = "renamed" },
	} {
		after := append([]pgconn.FieldDescription{}, before...)
		mutation(&after[0])
		if samePostgresSourceFields(before, after) {
			t.Fatal("changed result origin was not detected")
		}
	}
}
