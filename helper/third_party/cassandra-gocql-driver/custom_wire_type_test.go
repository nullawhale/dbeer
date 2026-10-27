package gocql

import (
	"bytes"
	"testing"
)

func opaqueWireResolver(_ int, name string, resolved TypeInfo, _ error) (TypeInfo, error) {
	if _, ok := resolved.(VectorType); ok {
		return resolved, nil
	}
	return unknownTypeInfo(name), nil
}
func customTypeFrame(types *RegisteredTypes, name string) *framer {
	f := newFramer(nil, protoVersion5, types)
	f.writeShort(uint16(TypeCustom))
	f.writeString(name)
	return f
}

func TestCustomWireResolverPreservesUnknownClassAndLegacyAlias(t *testing.T) {
	for _, name := range []string{"com.example.ExternalType", "org.apache.cassandra.db.marshal.LexicalUUIDType", "org.apache.cassandra.db.marshal.DynamicCompositeType(a=>org.apache.cassandra.db.marshal.UTF8Type)"} {
		t.Run(name, func(t *testing.T) {
			types := GlobalTypes.Copy()
			types.customWireTypeResolver = opaqueWireResolver
			info, err := customTypeFrame(types, name).readTypeInfo()
			if err != nil || info.Type() != TypeCustom || info != unknownTypeInfo(name) {
				t.Fatalf("opaque identity lost: %T %v", info, err)
			}
			for _, data := range [][]byte{nil, {}, {0, 255, 1}} {
				var capture customWireCapture
				if err := Unmarshal(info, data, &capture); err != nil || !bytes.Equal(capture.data, data) || (capture.data == nil) != (data == nil) {
					t.Fatal("wire bytes/NULL/empty distinction lost")
				}
			}
		})
	}
	if _, err := customTypeFrame(GlobalTypes, "com.example.ExternalType").readTypeInfo(); err == nil {
		t.Fatal("opt-in changed global/default behavior")
	}
}

func TestCustomWireResolverPreservesVectorAndNestedOpaqueTypes(t *testing.T) {
	types := GlobalTypes.Copy()
	types.customWireTypeResolver = opaqueWireResolver
	info, err := customTypeFrame(types, "org.apache.cassandra.db.marshal.VectorType(org.apache.cassandra.db.marshal.FloatType,3)").readTypeInfo()
	vector, ok := info.(VectorType)
	if err != nil || !ok || vector.Dimensions != 3 || vector.SubType.Type() != TypeFloat {
		t.Fatal("native vector decoding changed")
	}
	data, err := Marshal(info, []float32{1.25, -2.5, 0})
	if err != nil {
		t.Fatal(err)
	}
	var values []float32
	if err := Unmarshal(info, data, &values); err != nil || len(values) != 3 || values[1] != -2.5 {
		t.Fatal("vector values changed")
	}
	f := newFramer(nil, protoVersion5, types)
	f.writeShort(uint16(TypeMap))
	f.writeShort(uint16(TypeText))
	f.writeShort(uint16(TypeCustom))
	f.writeString("com.example.NestedType")
	nested, err := f.readTypeInfo()
	if err != nil {
		t.Fatal(err)
	}
	collection, ok := nested.(CollectionType)
	if !ok || collection.Elem != unknownTypeInfo("com.example.NestedType") {
		t.Fatal("nested custom metadata bypassed session resolver")
	}
	copy := types.Copy()
	types.customWireTypeResolver = nil
	if _, err := customTypeFrame(copy, "com.example.CopiedType").readTypeInfo(); err != nil {
		t.Fatal("resolver was not copied with session types")
	}
}

func TestCustomWireResolverRejectsMalformedMetadataBeforeCallback(t *testing.T) {
	types := GlobalTypes.Copy()
	called := false
	types.customWireTypeResolver = func(int, string, TypeInfo, error) (TypeInfo, error) {
		called = true
		return unknownTypeInfo("unexpected"), nil
	}
	for _, name := range []string{"", "com.example.Type(", "com.example.Type(a))", "com.example.Type(a)extra", "vector<float,3", "org.apache.cassandra.db.marshal.VectorType(org.apache.cassandra.db.marshal.FloatType,bad)", "com.example.Type\x00"} {
		called = false
		if _, err := customTypeFrame(types, name).readTypeInfo(); err == nil || called {
			t.Fatal("malformed custom metadata was accepted or passed to callback")
		}
	}
	f := newFramer(nil, protoVersion5, types)
	f.writeShort(uint16(TypeCustom))
	f.writeShort(20)
	f.buf = append(f.buf, 'x')
	called = false
	if _, err := f.readTypeInfo(); err == nil || called {
		t.Fatal("truncated metadata reached resolver")
	}
	// An unknown native protocol code must still fail; this extension is
	// restricted to the custom-class discriminator.
	f = newFramer(nil, protoVersion5, types)
	f.writeShort(0x7fff)
	if _, err := f.readTypeInfo(); err == nil {
		t.Fatal("unknown native protocol type accepted")
	}
}

type customWireCapture struct{ data []byte }

func (c *customWireCapture) UnmarshalCQL(_ TypeInfo, data []byte) error {
	if data == nil {
		c.data = nil
	} else {
		c.data = append([]byte{}, data...)
	}
	return nil
}
