package sqlcomplete

import "strings"

// Cassandra 4.1 and 5.0 spellings. Availability of newer functions is checked
// by the connected server; offline completion does not guess its version.
func cassandraFunctions() []string {
	names := strings.Fields("COUNT SUM AVG MIN MAX TOKEN TTL WRITETIME MAXWRITETIME UUID NOW CURRENTTIMESTAMP CURRENTDATE CURRENTTIME CURRENTTIMEUUID TODATE TOTIMESTAMP TOUNIXTIMESTAMP MINTIMEUUID MAXTIMEUUID CAST TOJSON FROMJSON ABS EXP LOG LOG10 ROUND MAP_KEYS MAP_VALUES COLLECTION_COUNT COLLECTION_MIN COLLECTION_MAX COLLECTION_SUM COLLECTION_AVG MASK_NULL MASK_DEFAULT MASK_REPLACE MASK_INNER MASK_OUTER MASK_HASH SIMILARITY_COSINE SIMILARITY_DOT_PRODUCT SIMILARITY_EUCLIDEAN")
	for _, typ := range cassandraBlobTypes {
		names = append(names, typ+"ASBLOB", "BLOBAS"+typ)
	}
	return names
}

var cassandraBlobTypes = strings.Fields("ASCII BIGINT BOOLEAN COUNTER DATE DECIMAL DOUBLE DURATION FLOAT INET INT SMALLINT TEXT TIME TIMESTAMP TIMEUUID TINYINT UUID VARCHAR VARINT")

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
	if engine == "cassandra" {
		for _, typ := range cassandraBlobTypes {
			if name == typ+"ASBLOB" || name == typ+"_AS_BLOB" {
				return []FunctionSignature{sig("blob", p("value", strings.ToLower(typ)))}
			}
			if name == "BLOBAS"+typ || name == "BLOB_AS_"+typ {
				return []FunctionSignature{sig(strings.ToLower(typ), p("value", "blob"))}
			}
		}
		switch name {
		case "COUNT":
			return []FunctionSignature{sig("bigint", p("expression", "column / *"))}
		case "SUM", "AVG":
			return []FunctionSignature{sig("same as value", p("value", "numeric"))}
		case "MIN", "MAX":
			return []FunctionSignature{sig("same as value", p("value", "sortable"))}
		case "TOKEN":
			return []FunctionSignature{sig("partitioner token", variadic(p("partition_key", "partition key component")))}
		case "TTL":
			return []FunctionSignature{sig("int", p("column", "non-primary-key column"))}
		case "WRITETIME":
			return []FunctionSignature{sig("bigint", p("column", "non-primary-key column"))}
		case "MAXWRITETIME":
			return []FunctionSignature{sig("bigint", p("column", "non-primary-key column"))}
		case "UUID":
			return []FunctionSignature{sig("uuid")}
		case "NOW", "CURRENT_TIMEUUID", "CURRENTTIMEUUID":
			return []FunctionSignature{sig("timeuuid")}
		case "CURRENT_TIMESTAMP", "CURRENTTIMESTAMP":
			return []FunctionSignature{sig("timestamp")}
		case "CURRENT_DATE", "CURRENTDATE":
			return []FunctionSignature{sig("date")}
		case "CURRENT_TIME", "CURRENTTIME":
			return []FunctionSignature{sig("time")}
		case "TO_DATE", "TODATE":
			return []FunctionSignature{sig("date", p("value", "timeuuid / timestamp"))}
		case "TO_TIMESTAMP", "TOTIMESTAMP":
			return []FunctionSignature{sig("timestamp", p("value", "timeuuid / date"))}
		case "DATEOF":
			return []FunctionSignature{sig("timestamp", p("value", "timeuuid"))}
		case "UNIXTIMESTAMPOF":
			return []FunctionSignature{sig("bigint", p("value", "timeuuid"))}
		case "TO_UNIX_TIMESTAMP", "TOUNIXTIMESTAMP":
			return []FunctionSignature{sig("bigint", p("value", "timeuuid / timestamp / date"))}
		case "MIN_TIMEUUID", "MAX_TIMEUUID", "MINTIMEUUID", "MAXTIMEUUID":
			return []FunctionSignature{sig("timeuuid", p("value", "timestamp"))}
		case "TOJSON", "TO_JSON":
			return []FunctionSignature{sig("text", p("value", "any"))}
		case "FROMJSON", "FROM_JSON":
			return []FunctionSignature{sig("column type", p("value", "text"))}
		case "CAST":
			return []FunctionSignature{sig("target type", p("expression", "value AS native_type"))}
		case "ABS", "EXP", "LOG", "LOG10", "ROUND":
			return []FunctionSignature{sig("same as value", p("value", "numeric"))}
		case "MAP_KEYS":
			return []FunctionSignature{sig("set<key type>", p("value", "map<key type, value type>"))}
		case "MAP_VALUES":
			return []FunctionSignature{sig("list<value type>", p("value", "map<key type, value type>"))}
		case "COLLECTION_COUNT":
			return []FunctionSignature{sig("int", p("value", "map / set / list"))}
		case "COLLECTION_MIN", "COLLECTION_MAX":
			return []FunctionSignature{sig("element type", p("value", "set / list"))}
		case "COLLECTION_SUM", "COLLECTION_AVG":
			return []FunctionSignature{sig("element type", p("value", "numeric set / list"))}
		case "MASK_NULL", "MASK_DEFAULT":
			return []FunctionSignature{sig("same as value", p("value", "any"))}
		case "MASK_REPLACE":
			return []FunctionSignature{sig("same as value", p("value", "any"), p("replacement", "same as value"))}
		case "MASK_INNER", "MASK_OUTER":
			return []FunctionSignature{sig("same as value", p("value", "text / varchar / ascii"), p("begin", "int"), p("end", "int")),
				sig("same as value", p("value", "text / varchar / ascii"), p("begin", "int"), p("end", "int"), p("padding", "text"))}
		case "MASK_HASH":
			return []FunctionSignature{sig("blob", p("value", "any")), sig("blob", p("value", "any"), p("algorithm", "text"))}
		case "SIMILARITY_COSINE", "SIMILARITY_DOT_PRODUCT", "SIMILARITY_EUCLIDEAN":
			return []FunctionSignature{sig("float", p("left", "vector<float, n>"), p("right", "vector<float, n>"))}
		default:
			return nil
		}
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
