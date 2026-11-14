package mysql

import (
	"strconv"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func nativeMySQLRow(columns []protocol.Column, fields []*wire.Field, values []wire.FieldValue, rawText [][]byte) []protocol.NativeValue {
	row := make([]protocol.NativeValue, len(values))
	for index, raw := range values {
		column, field := columns[index], fields[index]
		value := protocol.NativeValue{Kind: "null"}
		if raw.Type != wire.FieldValueTypeNull {
			switch raw.Type {
			case wire.FieldValueTypeSigned:
				value = protocol.NativeScalar("integer", strconv.FormatInt(raw.AsInt64(), 10))
			case wire.FieldValueTypeUnsigned:
				value = protocol.NativeScalar("integer", strconv.FormatUint(raw.AsUint64(), 10))
			case wire.FieldValueTypeFloat:
				if rawText != nil {
					value = protocol.NativeScalar("native", string(rawText[index]))
				} else if field.Type == wire.MYSQL_TYPE_FLOAT {
					value = protocol.NativeFloat32(float32(raw.AsFloat64()))
				} else {
					value = protocol.NativeFloat64(raw.AsFloat64())
				}
			case wire.FieldValueTypeString:
				data := raw.AsString()
				if binaryColumn(field) {
					value = protocol.NativeBinary(data)
				} else if !utf8.Valid(data) {
					value = protocol.NativeBinary(data)
					value.Kind = "opaque"
				} else {
					text := string(data)
					value = protocol.NativeScalar("native", text)
					switch field.Type {
					case wire.MYSQL_TYPE_TINY, wire.MYSQL_TYPE_SHORT, wire.MYSQL_TYPE_LONG, wire.MYSQL_TYPE_INT24, wire.MYSQL_TYPE_LONGLONG, wire.MYSQL_TYPE_YEAR:
						value = protocol.NativeScalar("integer", text)
					case wire.MYSQL_TYPE_NEWDECIMAL, wire.MYSQL_TYPE_DECIMAL:
						value = protocol.NativeScalar("decimal", text)
					case wire.MYSQL_TYPE_VARCHAR, wire.MYSQL_TYPE_VAR_STRING, wire.MYSQL_TYPE_STRING, wire.MYSQL_TYPE_BLOB, wire.MYSQL_TYPE_TINY_BLOB, wire.MYSQL_TYPE_MEDIUM_BLOB, wire.MYSQL_TYPE_LONG_BLOB:
						if field.Flag&(wire.ENUM_FLAG|wire.SET_FLAG) == 0 {
							value = protocol.NativeScalar("text", text)
						}
					}
				}
			default:
				value.Kind = "invalid"
			}
		}
		value.Engine, value.NativeType, value.TypeIdentity = "mysql", column.NativeType, column.TypeIdentity
		row[index] = value
	}
	return row
}
