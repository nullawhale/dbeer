package postgres

import (
	"encoding/binary"
	"encoding/hex"
	"math"
	"strconv"
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
)

// PostgreSQL's text protocol is already a typed wire representation. Unknown
// native text (including array bounds and custom output) stays labelled as such.
func nativePostgresRow(columns []protocol.Column, values [][]byte, formats ...[]int16) []protocol.NativeValue {
	row := make([]protocol.NativeValue, len(values))
	for index, raw := range values {
		column := columns[index]
		value := protocol.NativeValue{Kind: "null"}
		if raw != nil && len(formats) > 0 && index < len(formats[0]) && formats[0][index] == 1 {
			var ok bool
			value, _, ok = nativePostgresBinaryFloat(column.TypeOID, raw)
			if !ok {
				value.Kind = "invalid"
			}
			value.Engine, value.NativeType, value.TypeIdentity = "postgresql", column.NativeType, column.TypeIdentity
			row[index] = value
			continue
		}
		if raw != nil {
			text := string(raw)
			value = protocol.NativeScalar("native", text)
			if column.Encoding == "base64" {
				decoded, err := decodeBytea(raw)
				if err != nil {
					value.Kind = "invalid"
				} else {
					value = protocol.NativeBinary(decoded)
				}
			} else if !utf8.Valid(raw) {
				value = protocol.NativeBinary(raw)
				value.Kind = "opaque"
			} else {
				switch column.TypeOID {
				case 16:
					if text == "t" {
						value = protocol.NativeScalar("boolean", "true")
					} else if text == "f" {
						value = protocol.NativeScalar("boolean", "false")
					}
				case 20, 21, 23, 26:
					value = protocol.NativeScalar("integer", text)
				case 1700:
					candidate := protocol.NativeScalar("decimal", text)
					if candidate.Valid() {
						value = candidate
					}
				case 700, 701:
					// Rounded session output is wire text, not captured IEEE bits.
					if strings.HasPrefix(column.TypeIdentity, "unresolved:") {
						break
					}
					bits := 64
					if column.TypeOID == 700 {
						bits = 32
					}
					if floating, err := strconv.ParseFloat(text, bits); err == nil && !math.IsNaN(floating) {
						if bits == 32 {
							value = protocol.NativeFloat32(float32(floating))
						} else {
							value = protocol.NativeFloat64(floating)
						}
					}
				case 18, 19, 25, 1042, 1043:
					value = protocol.NativeScalar("text", text)
				}
			}
		}
		value.Engine, value.NativeType, value.TypeIdentity = "postgresql", column.NativeType, column.TypeIdentity
		row[index] = value
	}
	return row
}

func nativePostgresBinaryFloat(oid uint32, raw []byte) (protocol.NativeValue, string, bool) {
	if oid == 700 && len(raw) == 4 {
		value := protocol.NativeScalar("float32", hex.EncodeToString(raw))
		return value, strconv.FormatFloat(float64(math.Float32frombits(binary.BigEndian.Uint32(raw))), 'g', -1, 32), true
	}
	if oid == 701 && len(raw) == 8 {
		value := protocol.NativeScalar("float64", hex.EncodeToString(raw))
		return value, strconv.FormatFloat(math.Float64frombits(binary.BigEndian.Uint64(raw)), 'g', -1, 64), true
	}
	return protocol.NativeValue{}, "", false
}
