package mongodb

import (
	"errors"
	"fmt"
	"strconv"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
	"go.mongodb.org/mongo-driver/v2/bson"
)

var errNativeDocument = errors.New("MongoDB native value exceeds its supported bounds")

func nativeDocument(raw bson.Raw) (protocol.NativeValue, error) {
	if len(raw) > protocol.MaxNativeValueBytes || raw.Validate() != nil {
		return protocol.NativeValue{}, errNativeDocument
	}
	nodes := 0
	value, err := nativeBSONValue(bson.RawValue{Type: bson.TypeEmbeddedDocument, Value: raw}, 0, &nodes)
	if err == nil {
		return value, nil
	}
	value = protocol.NativeBinary(raw)
	value.Kind = "opaque"
	value.Engine, value.NativeType, value.TypeIdentity = "mongodb", "BSON document", "mongodb:bson:wire:v1"
	if value.Valid() {
		return value, nil
	}
	return value, errNativeDocument
}

func nativeBSONValue(raw bson.RawValue, depth int, nodes *int) (protocol.NativeValue, error) {
	*nodes++
	if depth > protocol.MaxNativeValueDepth || *nodes > protocol.MaxNativeValueNodes || len(raw.Value) > protocol.MaxNativeValueBytes || raw.Validate() != nil {
		return protocol.NativeValue{}, errNativeDocument
	}
	value := protocol.NativeValue{Kind: "null"}
	switch raw.Type {
	case bson.TypeNull:
	case bson.TypeString:
		value = protocol.NativeScalar("text", raw.StringValue())
	case bson.TypeInt32:
		value = protocol.NativeScalar("integer", strconv.FormatInt(int64(raw.Int32()), 10))
	case bson.TypeInt64:
		value = protocol.NativeScalar("integer", strconv.FormatInt(raw.Int64(), 10))
	case bson.TypeDouble:
		value = protocol.NativeFloat64(raw.Double())
	case bson.TypeBoolean:
		value = protocol.NativeScalar("boolean", strconv.FormatBool(raw.Boolean()))
	case bson.TypeDecimal128:
		value = protocol.NativeScalar("decimal", raw.Decimal128().String())
		if !value.Valid() {
			value = protocol.NativeBinary(raw.Value)
			value.Kind = "opaque"
		}
	case bson.TypeBinary:
		subtype, data := raw.Binary()
		value = protocol.NativeBinary(data)
		value.NativeType = fmt.Sprintf("binary:%02x", subtype)
	case bson.TypeObjectID:
		id := raw.ObjectID()
		value = protocol.NativeBinary(id[:])
	case bson.TypeDateTime:
		value = protocol.NativeScalar("integer", strconv.FormatInt(raw.DateTime(), 10))
	case bson.TypeTimestamp:
		timestamp, increment := raw.Timestamp()
		value = protocol.NativeValue{Kind: "tuple", Items: []protocol.NativeValue{protocol.NativeScalar("integer", strconv.FormatUint(uint64(timestamp), 10)), protocol.NativeScalar("integer", strconv.FormatUint(uint64(increment), 10))}}
		*nodes += 2
	case bson.TypeEmbeddedDocument:
		if depth == protocol.MaxNativeValueDepth {
			value = protocol.NativeBinary(raw.Value)
			value.Kind = "opaque"
			break
		}
		elements, err := raw.Document().Elements()
		if err != nil || len(elements) > (protocol.MaxNativeValueNodes-*nodes)/2 {
			return value, errNativeDocument
		}
		value = protocol.NativeValue{Kind: "object", Entries: make([]protocol.NativeEntry, 0, len(elements))}
		for _, element := range elements {
			name := element.Key()
			if !utf8.ValidString(name) {
				return value, errNativeDocument
			}
			*nodes++
			child, err := nativeBSONValue(element.Value(), depth+1, nodes)
			if err != nil {
				return value, err
			}
			value.Entries = append(value.Entries, protocol.NativeEntry{Key: protocol.NativeScalar("text", name), Value: child})
		}
	case bson.TypeArray:
		if depth == protocol.MaxNativeValueDepth {
			value = protocol.NativeBinary(raw.Value)
			value.Kind = "opaque"
			break
		}
		children, err := raw.Array().Values()
		if err != nil || len(children) > protocol.MaxNativeValueNodes-*nodes {
			return value, errNativeDocument
		}
		value = protocol.NativeValue{Kind: "list", Items: make([]protocol.NativeValue, 0, len(children))}
		for _, child := range children {
			item, err := nativeBSONValue(child, depth+1, nodes)
			if err != nil {
				return value, err
			}
			value.Items = append(value.Items, item)
		}
	default:
		value = protocol.NativeBinary(raw.Value)
		value.Kind = "opaque"
	}
	if value.Value != nil && !utf8.ValidString(*value.Value) {
		value = protocol.NativeBinary(raw.Value)
		value.Kind = "opaque"
	}
	value.Engine = "mongodb"
	if value.NativeType == "" {
		value.NativeType = raw.Type.String()
	}
	if *nodes > protocol.MaxNativeValueNodes || !value.Valid() {
		return value, errNativeDocument
	}
	return value, nil
}
