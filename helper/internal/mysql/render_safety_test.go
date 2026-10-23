package mysql

import (
	"strings"
	"testing"

	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func TestOrdinaryQueryTypeIdentityRejectsPotentiallyLossyRendering(t *testing.T) {
	for _, field := range []*wire.Field{
		{Type: wire.MYSQL_TYPE_FLOAT, Charset: 63, Decimal: 31},
		{Type: wire.MYSQL_TYPE_DOUBLE, Charset: 63, Decimal: 6},
		{Type: wire.MYSQL_TYPE_TIMESTAMP, Charset: 63, Decimal: 6},
		{Type: wire.MYSQL_TYPE_TIMESTAMP2, Charset: 63, Decimal: 6},
		{Type: wire.MYSQL_TYPE_VAR_STRING, Charset: 8},
		{Type: wire.MYSQL_TYPE_BLOB, Charset: 33},
	} {
		if !strings.HasPrefix(mysqlWireTypeIdentity(field), "unresolved:") {
			t.Fatal("potentially lossy query rendering gained exact identity")
		}
	}
	for _, field := range []*wire.Field{
		{Type: wire.MYSQL_TYPE_DOUBLE, Charset: 63, Decimal: 31},
		{Type: wire.MYSQL_TYPE_DATETIME, Charset: 63, Decimal: 6},
		{Type: wire.MYSQL_TYPE_VAR_STRING, Charset: 45},
		{Type: wire.MYSQL_TYPE_VAR_STRING, Charset: 255},
		{Type: wire.MYSQL_TYPE_VAR_STRING, Charset: 309},
		{Type: wire.MYSQL_TYPE_BLOB, Charset: 63},
	} {
		if strings.HasPrefix(mysqlWireTypeIdentity(field), "unresolved:") {
			t.Fatal("proven wire rendering became unresolved")
		}
	}
}
