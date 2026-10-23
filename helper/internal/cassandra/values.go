package cassandra

import (
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"net"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	gocql "github.com/apache/cassandra-gocql-driver/v2"
	"gopkg.in/inf.v0"
)

var errValue = errors.New("Cassandra value could not be decoded losslessly")

// The wire custom-class name must survive legacy driver aliases. External
// Java implementations remain opaque: preserve bytes and identity without
// applying a built-in decoder or claiming semantic equivalence.
type opaqueCQLType string

func (t opaqueCQLType) String() string { return string(t) }
func (opaqueCQLType) Type() gocql.Type { return gocql.TypeCustom }
func (opaqueCQLType) Zero() any        { return []byte(nil) }
func (opaqueCQLType) Marshal(value any) ([]byte, error) {
	if value == nil {
		return nil, nil
	}
	if data, ok := value.([]byte); ok {
		if data == nil {
			return nil, nil
		}
		return append([]byte{}, data...), nil
	}
	return nil, errValue
}
func (opaqueCQLType) Unmarshal(data []byte, value any) error {
	if destination, ok := value.(*[]byte); ok {
		if data == nil {
			*destination = nil
		} else {
			*destination = append([]byte{}, data...)
		}
		return nil
	}
	return errValue
}
func resolveCustomWireType(_ int, name string, resolved gocql.TypeInfo, _ error) (gocql.TypeInfo, error) {
	if vector, ok := resolved.(gocql.VectorType); ok {
		vector.WireCustomClass = name
		return vector, nil
	}
	return opaqueCQLType(name), nil
}

// rawValue receives wire bytes before scalar zero-value conversion. Nil and an
// allocated empty byte slice therefore retain their distinct CQL meanings.
type rawValue struct {
	info gocql.TypeInfo
	data []byte
}

func (v *rawValue) UnmarshalCQL(info gocql.TypeInfo, data []byte) error {
	if wrapped, ok := info.(wholeTuple); ok {
		info = wrapped.TypeInfo
	}
	v.info = info
	v.data = nil
	if data != nil {
		v.data = append([]byte{}, data...)
	}
	return nil
}

// GoCQL's default scanner expands tuples and loses the distinction between a
// NULL tuple and a tuple containing NULLs. NoSkipMetadata gives each iterator
// its own result metadata; this wrapper keeps a tuple as one raw wire value.
// The scanner's expected argument count is retained with trailing nil slots.
type wholeTuple struct{ gocql.TypeInfo }

func (wholeTuple) Type() gocql.Type { return gocql.TypeCustom }

func renderValue(info gocql.TypeInfo, data []byte, nested bool) (*string, error) {
	if data == nil {
		return nil, nil
	}
	text, err := cqlValue(info, data, nested, 0)
	if err != nil {
		return nil, err
	}
	return &text, nil
}
func quoteText(text string) string       { return "'" + strings.ReplaceAll(text, "'", "''") + "'" }
func quoteIdentifier(text string) string { return `"` + strings.ReplaceAll(text, `"`, `""`) + `"` }
func qualified(keyspace, object string) string {
	return quoteIdentifier(keyspace) + "." + quoteIdentifier(object)
}
func cqlValue(info gocql.TypeInfo, data []byte, nested bool, depth int) (string, error) {
	if depth > 64 || info == nil {
		return "", errValue
	}
	if data == nil {
		return "null", nil
	}
	if vector, ok := info.(gocql.VectorType); ok {
		var values []rawValue
		// Decode vector framing with the driver, retaining each element's raw bytes.
		if err := vector.Unmarshal(data, &values); err != nil {
			return "", errValue
		}
		parts := make([]string, len(values))
		for i, v := range values {
			var err error
			parts[i], err = cqlValue(v.info, v.data, true, depth+1)
			if err != nil {
				return "", err
			}
		}
		return "[" + strings.Join(parts, ", ") + "]", nil
	}
	switch info.Type() {
	case gocql.TypeText, gocql.TypeVarchar, gocql.TypeAscii:
		if !utf8.Valid(data) {
			return "", errValue
		}
		text := string(data)
		if nested {
			text = quoteText(text)
		}
		return text, nil
	case gocql.TypeBlob, gocql.TypeCustom:
		// CQL custom Java types use the blob literal/wire representation.
		// VectorType is handled above before its TypeCustom discriminator.
		if nested {
			return "0x" + hex.EncodeToString(data), nil
		}
		return base64.StdEncoding.EncodeToString(data), nil
	case gocql.TypeDecimal:
		var value inf.Dec
		if gocql.Unmarshal(info, data, &value) != nil {
			return "", errValue
		}
		// A valid wire decimal has a signed 32-bit scale. Expanding its
		// fractional/integer zero padding can otherwise allocate gigabytes
		// from a five-byte value before any display budget is checked.
		scale := int64(value.Scale())
		if scale > 4096 || scale < -4096 {
			return value.UnscaledBig().String() + "E" + strconv.FormatInt(-scale, 10), nil
		}
		return value.String(), nil
	case gocql.TypeVarint:
		var value big.Int
		if gocql.Unmarshal(info, data, &value) != nil {
			return "", errValue
		}
		return value.String(), nil
	case gocql.TypeBigInt, gocql.TypeCounter, gocql.TypeInt, gocql.TypeSmallInt, gocql.TypeTinyInt:
		var value int64
		if gocql.Unmarshal(info, data, &value) != nil {
			return "", errValue
		}
		return strconv.FormatInt(value, 10), nil
	case gocql.TypeBoolean:
		var value bool
		if gocql.Unmarshal(info, data, &value) != nil {
			return "", errValue
		}
		return strconv.FormatBool(value), nil
	case gocql.TypeFloat:
		var value float32
		if gocql.Unmarshal(info, data, &value) != nil {
			return "", errValue
		}
		return strconv.FormatFloat(float64(value), 'g', -1, 32), nil
	case gocql.TypeDouble:
		var value float64
		if gocql.Unmarshal(info, data, &value) != nil {
			return "", errValue
		}
		return strconv.FormatFloat(value, 'g', -1, 64), nil
	case gocql.TypeUUID, gocql.TypeTimeUUID:
		var value gocql.UUID
		if gocql.Unmarshal(info, data, &value) != nil {
			return "", errValue
		}
		return value.String(), nil
	case gocql.TypeInet:
		var value net.IP
		if gocql.Unmarshal(info, data, &value) != nil {
			return "", errValue
		}
		if nested {
			return quoteText(value.String()), nil
		}
		return value.String(), nil
	case gocql.TypeDate:
		var value string
		if gocql.Unmarshal(info, data, &value) != nil {
			return "", errValue
		}
		if nested {
			value = quoteText(value)
		}
		return value, nil
	case gocql.TypeTimestamp:
		// Milliseconds retain the complete signed 64-bit timestamp range. Formatting
		// as an RFC3339 date would lose values outside time.Time's printable range.
		var value int64
		if gocql.Unmarshal(info, data, &value) != nil {
			return "", errValue
		}
		return strconv.FormatInt(value, 10), nil
	case gocql.TypeTime:
		var value int64
		if gocql.Unmarshal(info, data, &value) != nil {
			return "", errValue
		}
		if value < 0 || value >= int64(24*time.Hour) {
			return "", errValue
		}
		text := fmt.Sprintf("%02d:%02d:%02d.%09d", value/int64(time.Hour), value/int64(time.Minute)%60, value/int64(time.Second)%60, value%int64(time.Second))
		if nested {
			text = quoteText(text)
		}
		return text, nil
	case gocql.TypeDuration:
		var value gocql.Duration
		if gocql.Unmarshal(info, data, &value) != nil {
			return "", errValue
		}
		// A single leading sign is required by the CQL duration literal grammar.
		sign := ""
		months, days, nanos := int64(value.Months), int64(value.Days), value.Nanoseconds
		if months < 0 || days < 0 || nanos < 0 {
			sign = "-"
			months = -months
			days = -days
			if nanos == -1<<63 {
				return "-" + strconv.FormatInt(months, 10) + "mo" + strconv.FormatInt(days, 10) + "d9223372036854775808ns", nil
			}
			nanos = -nanos
		}
		return sign + strconv.FormatInt(months, 10) + "mo" + strconv.FormatInt(days, 10) + "d" + strconv.FormatInt(nanos, 10) + "ns", nil
	case gocql.TypeList, gocql.TypeSet, gocql.TypeMap:
		collection, ok := info.(gocql.CollectionType)
		if !ok || len(data) < 4 {
			return "", errValue
		}
		count := int(binary.BigEndian.Uint32(data))
		data = data[4:]
		if count > len(data)/4 {
			return "", errValue
		}
		parts := make([]string, 0, count)
		for i := 0; i < count; i++ {
			raw, rest, ok := takeBytes(data)
			if !ok {
				return "", errValue
			}
			data = rest
			typ := collection.Elem
			if info.Type() == gocql.TypeMap {
				typ = collection.Key
			}
			text, err := cqlValue(typ, raw, true, depth+1)
			if err != nil {
				return "", err
			}
			if info.Type() == gocql.TypeMap {
				raw, rest, ok = takeBytes(data)
				if !ok {
					return "", errValue
				}
				data = rest
				value, err := cqlValue(collection.Elem, raw, true, depth+1)
				if err != nil {
					return "", err
				}
				text += ": " + value
			}
			parts = append(parts, text)
		}
		if len(data) != 0 {
			return "", errValue
		}
		if info.Type() == gocql.TypeList {
			return "[" + strings.Join(parts, ", ") + "]", nil
		}
		return "{" + strings.Join(parts, ", ") + "}", nil
	case gocql.TypeTuple:
		tuple, ok := info.(gocql.TupleTypeInfo)
		if !ok {
			return "", errValue
		}
		parts := make([]string, len(tuple.Elems))
		for i, typ := range tuple.Elems {
			raw, rest, ok := takeBytes(data)
			if !ok {
				return "", errValue
			}
			data = rest
			var err error
			parts[i], err = cqlValue(typ, raw, true, depth+1)
			if err != nil {
				return "", err
			}
		}
		if len(data) != 0 {
			return "", errValue
		}
		return "(" + strings.Join(parts, ", ") + ")", nil
	case gocql.TypeUDT:
		udt, ok := info.(gocql.UDTTypeInfo)
		if !ok {
			return "", errValue
		}
		parts := make([]string, len(udt.Elements))
		for i, field := range udt.Elements {
			var raw []byte
			if len(data) > 0 {
				var ok bool
				raw, data, ok = takeBytes(data)
				if !ok {
					return "", errValue
				}
			}
			text, err := cqlValue(field.Type, raw, true, depth+1)
			if err != nil {
				return "", err
			}
			parts[i] = quoteIdentifier(field.Name) + ": " + text
		}
		if len(data) != 0 {
			return "", errValue
		}
		return "{" + strings.Join(parts, ", ") + "}", nil
	}
	return "", errValue
}
func takeBytes(data []byte) ([]byte, []byte, bool) {
	if len(data) < 4 {
		return nil, nil, false
	}
	n := int32(binary.BigEndian.Uint32(data))
	data = data[4:]
	if n == -1 {
		return nil, data, true
	}
	if n < 0 || int64(n) > int64(len(data)) {
		return nil, nil, false
	}
	return data[:n], data[n:], true
}
func typeName(info gocql.TypeInfo) string {
	if info == nil {
		return "unknown"
	}
	if v, ok := info.(gocql.VectorType); ok {
		return fmt.Sprintf("vector<%s, %d>", typeName(v.SubType), v.Dimensions)
	}
	if t, ok := info.(gocql.TupleTypeInfo); ok {
		parts := make([]string, len(t.Elems))
		for i, e := range t.Elems {
			parts[i] = typeName(e)
		}
		return "tuple<" + strings.Join(parts, ", ") + ">"
	}
	if c, ok := info.(gocql.CollectionType); ok {
		if info.Type() == gocql.TypeMap {
			return "map<" + typeName(c.Key) + ", " + typeName(c.Elem) + ">"
		}
		name := "list"
		if info.Type() == gocql.TypeSet {
			name = "set"
		}
		return name + "<" + typeName(c.Elem) + ">"
	}
	if u, ok := info.(gocql.UDTTypeInfo); ok {
		return qualified(u.Keyspace, u.Name)
	}
	if info.Type() == gocql.TypeCustom {
		return quoteText(fmt.Sprint(info))
	}
	// Driver v2 scalar TypeInfo values do not implement fmt.Stringer. Formatting
	// the implementation struct produces "{}" or "{13}", not a CQL type name.
	// Cassandra canonicalizes the varchar alias to text in system_schema.
	names := map[gocql.Type]string{
		gocql.TypeAscii: "ascii", gocql.TypeText: "text", gocql.TypeVarchar: "text", gocql.TypeBlob: "blob",
		gocql.TypeBigInt: "bigint", gocql.TypeCounter: "counter", gocql.TypeInt: "int", gocql.TypeSmallInt: "smallint", gocql.TypeTinyInt: "tinyint",
		gocql.TypeBoolean: "boolean", gocql.TypeDecimal: "decimal", gocql.TypeVarint: "varint", gocql.TypeFloat: "float", gocql.TypeDouble: "double",
		gocql.TypeUUID: "uuid", gocql.TypeTimeUUID: "timeuuid", gocql.TypeInet: "inet", gocql.TypeDate: "date", gocql.TypeTime: "time",
		gocql.TypeTimestamp: "timestamp", gocql.TypeDuration: "duration",
	}
	if name, ok := names[info.Type()]; ok {
		return name
	}
	return "unknown"
}

func binaryCQLType(info gocql.TypeInfo) bool {
	if _, vector := info.(gocql.VectorType); vector {
		return false
	}
	return info.Type() == gocql.TypeBlob || info.Type() == gocql.TypeCustom
}
