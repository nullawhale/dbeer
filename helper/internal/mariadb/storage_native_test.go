package mariadb

import (
	"math"
	"strings"
	"testing"

	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func TestMariaDBStorageExactNamespaceNullOrderAndFloatBits(t *testing.T) {
	value := func(text string) wire.FieldValue {
		return wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte(text))
	}
	token := func(values ...wire.FieldValue) string {
		t.Helper()
		result, err := MariaDBStorageToken(values)
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	base := token(value("9007199254740993"), value("epoch:1729992600.123456"))
	if !strings.HasPrefix(base, "mariadb.storage.v1:") || strings.Contains(base, "9007199254740993") || base == token(value("9007199254740992"), value("epoch:1729992600.123456")) || base == token(value("epoch:1729992600.123456"), value("9007199254740993")) {
		t.Fatal("storage identity lost namespace, exact number or ordered field proof")
	}
	if token(wire.NewFieldValue(wire.FieldValueTypeNull, 0, nil)) == token(value("")) || token(value("zero:0000-00-00 00:00:00")) == token(value("epoch:0")) {
		t.Fatal("storage NULL, empty or zero sentinel was conflated")
	}
	if token(wire.NewFieldValue(wire.FieldValueTypeFloat, math.Float64bits(0), nil)) == token(wire.NewFieldValue(wire.FieldValueTypeFloat, math.Float64bits(math.Copysign(0, -1)), nil)) {
		t.Fatal("native float sign bit was discarded")
	}
	if empty, err := MariaDBStorageToken(nil); err != nil || empty != "" {
		t.Fatal("empty storage projection invented a token")
	}
}

func TestMariaDBStorageProjectionBoundsAndNativeTimestampDialect(t *testing.T) {
	kinds := map[string]string{"t`ime": "timestamp", "choice": "enum", "a_float": "float", "ordinary": "longtext"}
	names := MariaDBStorageColumns(kinds)
	if strings.Join(names, ",") != "a_float,choice,t`ime" {
		t.Fatal("storage field ordering changed")
	}
	projections := MariaDBStorageProjections(names, kinds)
	if len(projections) != 3 || !strings.Contains(projections[0], " AS DOUBLE)") || !strings.Contains(projections[1], " AS UNSIGNED)") || !strings.Contains(projections[2], "UNIX_TIMESTAMP(`t``ime`)") || !strings.Contains(projections[2], "zero:") {
		t.Fatal("native storage representation changed")
	}
	visible := MariaDBStableProjection("t`ime", "timestamp")
	if !strings.Contains(visible, "TIMESTAMPADD(SECOND,FLOOR(UNIX_TIMESTAMP(`t``ime`))") || strings.Contains(visible, "AT TIME ZONE") || strings.Contains(visible, "SET ") {
		t.Fatal("timestamp projection inherited another engine's syntax or changed state")
	}
	if MariaDBStorageProjections([]string{"missing"}, kinds) != nil || MariaDBStorageProjections([]string{"choice", "choice"}, kinds) != nil {
		t.Fatal("unproved or duplicate storage column was rendered")
	}
}
