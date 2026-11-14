package cassandra

import (
	"bytes"
	"encoding/binary"
	"math"

	"dbeer/helper/internal/protocol"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

func nativeCQLValue(info gocql.TypeInfo, data []byte, depth int, nodes *int) (protocol.NativeValue, error) {
	*nodes++
	value := protocol.NativeValue{Kind: "null"}
	if info == nil || depth > protocol.MaxNativeValueDepth || *nodes > protocol.MaxNativeValueNodes {
		return value, errValue
	}
	decorate := func(value protocol.NativeValue) (protocol.NativeValue, error) {
		value.Engine, value.NativeType, value.TypeIdentity = "cassandra", typeName(info), cassandraResultTypeIdentity(info)
		if !value.Valid() {
			return value, errValue
		}
		return value, nil
	}
	if data == nil {
		return decorate(value)
	}
	if depth == protocol.MaxNativeValueDepth {
		value = protocol.NativeBinary(data)
		value.Kind = "opaque"
		return decorate(value)
	}
	if vector, ok := info.(gocql.VectorType); ok {
		var values []rawValue
		if vector.Unmarshal(data, &values) != nil || len(values) > protocol.MaxNativeValueNodes-*nodes {
			return value, errValue
		}
		value = protocol.NativeValue{Kind: "list", Items: make([]protocol.NativeValue, 0, len(values))}
		for _, raw := range values {
			item, err := nativeCQLValue(raw.info, raw.data, depth+1, nodes)
			if err != nil {
				return value, err
			}
			value.Items = append(value.Items, item)
		}
		return decorate(value)
	}
	switch info.Type() {
	case gocql.TypeList, gocql.TypeSet, gocql.TypeMap:
		collection, ok := info.(gocql.CollectionType)
		if !ok || len(data) < 4 {
			return value, errValue
		}
		count := int(binary.BigEndian.Uint32(data))
		data = data[4:]
		if count > len(data)/4 || count > protocol.MaxNativeValueNodes-*nodes {
			return value, errValue
		}
		if info.Type() == gocql.TypeMap {
			value = protocol.NativeValue{Kind: "map", Entries: make([]protocol.NativeEntry, 0, count)}
		} else {
			value = protocol.NativeValue{Kind: "list", Items: make([]protocol.NativeValue, 0, count)}
			if info.Type() == gocql.TypeSet {
				value.Kind = "set"
			}
		}
		for i := 0; i < count; i++ {
			raw, rest, ok := takeBytes(data)
			if !ok {
				return value, errValue
			}
			data = rest
			typ := collection.Elem
			if info.Type() == gocql.TypeMap {
				typ = collection.Key
			}
			item, err := nativeCQLValue(typ, raw, depth+1, nodes)
			if err != nil {
				return value, err
			}
			if info.Type() == gocql.TypeMap {
				raw, rest, ok = takeBytes(data)
				if !ok {
					return value, errValue
				}
				data = rest
				child, err := nativeCQLValue(collection.Elem, raw, depth+1, nodes)
				if err != nil {
					return value, err
				}
				value.Entries = append(value.Entries, protocol.NativeEntry{Key: item, Value: child})
			} else {
				value.Items = append(value.Items, item)
			}
		}
		if len(data) != 0 {
			return value, errValue
		}
	case gocql.TypeTuple:
		tuple, ok := info.(gocql.TupleTypeInfo)
		if !ok || len(tuple.Elems) > protocol.MaxNativeValueNodes-*nodes {
			return value, errValue
		}
		value = protocol.NativeValue{Kind: "tuple", Items: make([]protocol.NativeValue, 0, len(tuple.Elems))}
		for _, typ := range tuple.Elems {
			raw, rest, ok := takeBytes(data)
			if !ok {
				return value, errValue
			}
			data = rest
			item, err := nativeCQLValue(typ, raw, depth+1, nodes)
			if err != nil {
				return value, err
			}
			value.Items = append(value.Items, item)
		}
		if len(data) != 0 {
			return value, errValue
		}
	case gocql.TypeUDT:
		udt, ok := info.(gocql.UDTTypeInfo)
		if !ok || len(udt.Elements) > (protocol.MaxNativeValueNodes-*nodes)/2 {
			return value, errValue
		}
		value = protocol.NativeValue{Kind: "object", Entries: make([]protocol.NativeEntry, 0, len(udt.Elements))}
		for _, field := range udt.Elements {
			var raw []byte
			if len(data) > 0 {
				var ok bool
				raw, data, ok = takeBytes(data)
				if !ok {
					return value, errValue
				}
			}
			*nodes++
			item, err := nativeCQLValue(field.Type, raw, depth+1, nodes)
			if err != nil {
				return value, err
			}
			value.Entries = append(value.Entries, protocol.NativeEntry{Key: protocol.NativeScalar("text", field.Name), Value: item})
		}
		if len(data) != 0 {
			return value, errValue
		}
	case gocql.TypeBlob, gocql.TypeCustom:
		value = protocol.NativeBinary(data)
		if info.Type() == gocql.TypeCustom {
			value.Kind = "opaque"
		}
	case gocql.TypeFloat:
		if len(data) != 4 {
			return value, errValue
		}
		value = protocol.NativeFloat32(math.Float32frombits(binary.BigEndian.Uint32(data)))
	case gocql.TypeDouble:
		if len(data) != 8 {
			return value, errValue
		}
		value = protocol.NativeFloat64(math.Float64frombits(binary.BigEndian.Uint64(data)))
	default:
		text, err := cqlValue(info, data, false, depth)
		if err != nil {
			return value, err
		}
		kind := "native"
		switch info.Type() {
		case gocql.TypeText, gocql.TypeVarchar, gocql.TypeAscii:
			kind = "text"
		case gocql.TypeBigInt, gocql.TypeCounter, gocql.TypeInt, gocql.TypeSmallInt, gocql.TypeTinyInt, gocql.TypeVarint, gocql.TypeTimestamp:
			kind = "integer"
		case gocql.TypeDecimal:
			kind = "decimal"
		case gocql.TypeBoolean:
			kind = "boolean"
		}
		value = protocol.NativeScalar(kind, text)
		if kind == "native" && info.Type() != gocql.TypeDuration {
			encoded, err := (textParameter{Value: text}).MarshalCQL(info)
			if err != nil || !bytes.Equal(encoded, data) {
				value = protocol.NativeBinary(data)
				value.Kind = "opaque"
			}
		}
	}
	return decorate(value)
}

func nativeCQLRow(values []rawValue) ([]protocol.NativeValue, error) {
	row := make([]protocol.NativeValue, len(values))
	nodes := 0
	for index, raw := range values {
		if raw.info == nil {
			return nil, errValue
		}
		value, err := nativeCQLValue(raw.info, raw.data, 0, &nodes)
		if err != nil {
			value = protocol.NativeBinary(raw.data)
			value.Kind = "opaque"
			value.Engine, value.NativeType, value.TypeIdentity = "cassandra", typeName(raw.info), cassandraResultTypeIdentity(raw.info)
			if raw.data == nil {
				value.Kind = "null"
				value.Value = nil
			}
			if !value.Valid() {
				return nil, errValue
			}
		}
		row[index] = value
	}
	if !protocol.NativeMatrixValid([][]protocol.NativeValue{row}, 1, len(row)) {
		return nil, errValue
	}
	return row, nil
}
