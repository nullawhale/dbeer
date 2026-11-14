package nativevalue

import "testing"

func TestMariaDBNativeIdentityAndTextRemainDistinct(t *testing.T) {
	text := `{"a":1,"a":2}`
	value := NativeScalar("text", text)
	value.Engine, value.NativeType, value.TypeIdentity = "mariadb", "longtext", "mariadb:text:binary-collation"
	if !value.Valid() || value.Value == nil || *value.Value != text {
		t.Fatal("MariaDB native text lost duplicate keys or engine identity")
	}
	value.Engine = "unrecognized-mariadb-fork"
	if value.Valid() {
		t.Fatal("unknown engine identity was admitted")
	}
}
