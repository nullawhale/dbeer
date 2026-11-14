package mcpbridge

import (
	"reflect"

	"dbeer/helper/internal/nativevalue"
	"github.com/google/jsonschema-go/jsonschema"
)

// SDK inference cannot infer recursive Go types. Describe the same native wire
// tree through a local reference; shared NativeValue still owns validation.
func nativeToolOutputSchema() *jsonschema.Schema {
	ref := func() *jsonschema.Schema { return &jsonschema.Schema{Ref: "#/$defs/nativeValue"} }
	schema, err := jsonschema.For[toolOutput](&jsonschema.ForOptions{TypeSchemas: map[reflect.Type]*jsonschema.Schema{
		reflect.TypeFor[nativevalue.NativeValue](): ref(),
	}})
	if err != nil {
		panic("Invalid DBeer native result schema.")
	}
	text := func() *jsonschema.Schema { return &jsonschema.Schema{Type: "string"} }
	closed := func() *jsonschema.Schema { return &jsonschema.Schema{Not: &jsonschema.Schema{}} }
	entry := &jsonschema.Schema{Type: "object", Required: []string{"key", "value"}, Properties: map[string]*jsonschema.Schema{"key": ref(), "value": ref()}, AdditionalProperties: closed()}
	schema.Defs = map[string]*jsonschema.Schema{"nativeValue": {
		Type: "object", Required: []string{"kind"}, AdditionalProperties: closed(),
		Properties: map[string]*jsonschema.Schema{
			"kind":  {Type: "string", Enum: []any{"null", "text", "integer", "decimal", "boolean", "float32", "float64", "binary", "list", "tuple", "set", "map", "object", "native", "opaque"}},
			"value": text(), "engine": text(), "nativeType": text(), "typeIdentity": text(),
			"items": {Type: "array", Items: ref()}, "entries": {Type: "array", Items: entry},
		},
	}}
	return schema
}
