package sqlite

import (
	"encoding/base64"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
)

func nativeSQLiteRow(values []protocol.SQLiteValue) []protocol.NativeValue {
	result := make([]protocol.NativeValue, len(values))
	for index, value := range values {
		native := protocol.NativeValue{Kind: "null"}
		switch value.Type {
		case "integer":
			native = protocol.NativeScalar("integer", value.Value)
		case "real":
			native = protocol.NativeScalar("float64", value.Value)
		case "text", "blob":
			data, err := base64.StdEncoding.Strict().DecodeString(value.Value)
			if err != nil {
				native.Kind = "invalid"
				break
			}
			if value.Type == "text" && utf8.Valid(data) {
				native = protocol.NativeScalar("text", string(data))
			} else {
				native = protocol.NativeBinary(data)
				if value.Type == "text" {
					native.Kind = "opaque"
				}
			}
		}
		native.Engine, native.NativeType = "sqlite", value.Type
		result[index] = native
	}
	return result
}
