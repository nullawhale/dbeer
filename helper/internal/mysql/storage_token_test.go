package mysql

import (
	"testing"

	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func TestStorageTokensKeepNullAndAllUnsignedMasksDistinct(t *testing.T) {
	seen := map[string]bool{}
	for _, value := range []wire.FieldValue{
		wire.NewFieldValue(wire.FieldValueTypeNull, 0, nil),
		wire.NewFieldValue(wire.FieldValueTypeUnsigned, 0, nil),
		wire.NewFieldValue(wire.FieldValueTypeUnsigned, 1, nil),
		wire.NewFieldValue(wire.FieldValueTypeUnsigned, ^uint64(0), nil),
	} {
		token, err := mysqlStorageToken([]wire.FieldValue{value})
		if err != nil || token == "" || seen[token] {
			t.Fatal("storage masks or SQL NULL collapsed")
		}
		seen[token] = true
	}
	left, _ := mysqlStorageToken([]wire.FieldValue{wire.NewFieldValue(wire.FieldValueTypeUnsigned, 1, nil)})
	right, _ := mysqlStorageToken([]wire.FieldValue{wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte("1"))})
	if left != right {
		t.Fatal("wire integer encoding changed storage identity")
	}
}

func TestBrowseCollectorStripsTransportColumnsAndBoundsStorageTokens(t *testing.T) {
	c := newCollector(protocol.Command{})
	c.hiddenStorageFields = 1
	c.maxRows = 1
	result := wire.NewResultReserveResultset(2)
	defer result.Close()
	result.Fields = []*wire.Field{{Name: []byte("e"), Type: wire.MYSQL_TYPE_STRING, Charset: 45, Flag: wire.ENUM_FLAG}, {Name: []byte("__dbeer_storage_0"), Type: wire.MYSQL_TYPE_LONGLONG, Flag: wire.UNSIGNED_FLAG}}
	if err := c.columns(result); err != nil {
		t.Fatal(err)
	}
	for _, ordinal := range []uint64{0, 1} {
		if err := c.row([]wire.FieldValue{wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte("")), wire.NewFieldValue(wire.FieldValueTypeUnsigned, ordinal, nil)}); err != nil {
			t.Fatal(err)
		}
	}
	response := c.finishSingle(result, 0, "idle")
	if len(response.Columns) != 1 || response.Columns[0].Name != "e" || len(response.Rows) != 1 || len(response.Rows[0]) != 1 || len(response.StorageTokens) != 1 || !response.Truncated {
		t.Fatal("transport-only storage metadata leaked or lost row alignment")
	}
	if response.Columns[0].NativeType != "ENUM" {
		t.Fatal("ENUM wire flag lost its native type")
	}
}
