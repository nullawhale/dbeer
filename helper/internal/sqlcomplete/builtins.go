package sqlcomplete

// Built-ins are available offline. Polymorphic results are described rather
// than guessed from incomplete expressions. User-defined signatures come from
// the adapters and are never inferred from this registry.
func builtinSignatures(name, engine string) []FunctionSignature {
	p := func(name, typ string) FunctionParameter { return FunctionParameter{Name: name, Type: typ} }
	optional := func(value FunctionParameter) FunctionParameter { value.Optional = true; return value }
	variadic := func(value FunctionParameter) FunctionParameter { value.Variadic = true; return value }
	sig := func(result string, parameters ...FunctionParameter) FunctionSignature {
		return FunctionSignature{Parameters: parameters, ReturnType: result}
	}
	common := map[string][]FunctionSignature{
		"COUNT":    {sig("bigint", p("expression", "any / *"))},
		"MIN":      {sig("same as value", p("value", "sortable"))},
		"MAX":      {sig("same as value", p("value", "sortable"))},
		"COALESCE": {sig("common type of values", variadic(p("values", "any")))},
		"NULLIF":   {sig("type of value1", p("value1", "any"), p("value2", "any"))},
		"ABS":      {sig("same numeric type as value", p("value", "numeric"))},
	}
	if values := common[name]; len(values) > 0 {
		return values
	}
	if engine == "mysql" {
		values := map[string][]FunctionSignature{
			"SUM":          {sig("DECIMAL / DOUBLE", p("value", "numeric"))},
			"AVG":          {sig("DECIMAL / DOUBLE", p("value", "numeric"))},
			"LOWER":        {sig("string", p("value", "string"))},
			"UPPER":        {sig("string", p("value", "string"))},
			"LENGTH":       {sig("integer", p("value", "string"))},
			"SUBSTRING":    {sig("string", p("value", "string"), p("position", "integer"), optional(p("length", "integer")))},
			"ROUND":        {sig("numeric", p("value", "numeric"), optional(p("decimals", "integer")))},
			"IFNULL":       {sig("common type of values", p("value", "any"), p("fallback", "any"))},
			"CONCAT":       {sig("string", variadic(p("values", "any")))},
			"NOW":          {sig("datetime", optional(p("precision", "integer")))},
			"DATE_FORMAT":  {sig("string", p("date", "date / datetime"), p("format", "string"))},
			"JSON_EXTRACT": {sig("json", p("document", "json"), variadic(p("paths", "string")))},
			"GROUP_CONCAT": {sig("string", variadic(p("expressions", "any")))},
		}
		return values[name]
	}
	if name == "SUM" || name == "AVG" {
		values := []FunctionSignature{}
		for _, typ := range []string{"smallint", "integer", "bigint", "numeric", "real", "double precision", "interval"} {
			result := typ
			if name == "SUM" {
				if typ == "smallint" || typ == "integer" {
					result = "bigint"
				}
				if typ == "bigint" {
					result = "numeric"
				}
			}
			if name == "AVG" {
				if typ == "smallint" || typ == "integer" || typ == "bigint" {
					result = "numeric"
				}
				if typ == "real" {
					result = "double precision"
				}
			}
			values = append(values, sig(result, p("value", typ)))
		}
		return values
	}
	values := map[string][]FunctionSignature{
		"LOWER":              {sig("text", p("value", "text"))},
		"UPPER":              {sig("text", p("value", "text"))},
		"LENGTH":             {sig("integer", p("value", "text")), sig("integer", p("value", "bytea"))},
		"SUBSTRING":          {sig("text", p("value", "text"), p("start", "integer"), optional(p("count", "integer"))), sig("text", p("value", "text"), p("pattern", "text")), sig("bytea", p("value", "bytea"), p("start", "integer"), optional(p("count", "integer")))},
		"ROUND":              {sig("numeric", p("value", "numeric")), sig("numeric", p("value", "numeric"), p("scale", "integer")), sig("double precision", p("value", "double precision"))},
		"NOW":                {sig("timestamp with time zone")},
		"DATE_TRUNC":         {sig("timestamp", p("field", "text"), p("value", "timestamp")), sig("timestamp with time zone", p("field", "text"), p("value", "timestamp with time zone"), optional(p("time_zone", "text"))), sig("interval", p("field", "text"), p("value", "interval"))},
		"STRING_AGG":         {sig("text", p("value", "text"), p("delimiter", "text")), sig("bytea", p("value", "bytea"), p("delimiter", "bytea"))},
		"ARRAY_AGG":          {sig("array", p("value", "any"))},
		"JSONB_BUILD_OBJECT": {sig("jsonb", variadic(p("key_value_pairs", "any")))},
		"GENERATE_SERIES":    {sig("SETOF integer", p("start", "integer"), p("stop", "integer"), optional(p("step", "integer"))), sig("SETOF bigint", p("start", "bigint"), p("stop", "bigint"), optional(p("step", "bigint"))), sig("SETOF numeric", p("start", "numeric"), p("stop", "numeric"), optional(p("step", "numeric"))), sig("SETOF timestamp", p("start", "timestamp"), p("stop", "timestamp"), p("step", "interval"))},
	}
	return values[name]
}
