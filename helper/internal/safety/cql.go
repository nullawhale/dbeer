package safety

import "strings"

// CQL scripts use semicolons inside textual batches. Keeping their original
// byte ranges makes assessment and execution agree on the exact batch boundary.
func classifyCQLScript(sql string) []Statement {
	l := lexer{sql: sql, engine: "cassandra"}
	ts, ok := l.scan(0, 0)
	if !ok {
		return []Statement{{0, len(sql), Unknown, "ambiguous_or_invalid_syntax"}}
	}
	var result []Statement
	start, batch := 0, false
	for i := 0; i <= len(ts); i++ {
		if i == start && i < len(ts) && ts[i].text == "BEGIN" {
			batch = true
		}
		if i < len(ts) && ts[i].text != ";" {
			continue
		}
		if batch && i < len(ts) && !(i >= 2 && ts[i-2].text == "APPLY" && ts[i-1].text == "BATCH") {
			continue
		}
		if i > start {
			part := ts[start:i]
			kind, reason := classifyCQL(part)
			result = append(result, Statement{part[0].start, part[len(part)-1].end, kind, reason})
		}
		start = i + 1
		batch = false
	}
	return result
}

func classifyCQL(ts []token) (Kind, string) {
	if len(ts) == 0 || ts[0].kind != word {
		return Unknown, "unsupported_statement"
	}
	switch ts[0].text {
	case "USE":
		if len(ts) == 2 && isName(ts[1]) {
			return Read, "keyspace_selection"
		}
	case "SELECT":
		// Arbitrary UDFs and user-defined aggregates can have external side effects.
		// Permit only explicit native functions; qualified calls must use system.
		if len(ts) > 3 && contains(ts, "FROM") && cqlReadExpressions(ts) {
			return Read, "cql_select"
		}
	case "LIST":
		if cqlList(ts[1:]) {
			return Read, "cql_security_metadata"
		}
	case "DESCRIBE", "DESC":
		if cqlDescribe(ts[1:]) {
			return Read, "cql_schema_metadata"
		}
	case "INSERT":
		if len(ts) > 3 && ts[1].text == "INTO" {
			return Write, "cql_insert"
		}
	case "UPDATE":
		if len(ts) > 3 && contains(ts, "SET") {
			return Write, "cql_update"
		}
	case "DELETE":
		if contains(ts, "FROM") {
			return Destructive, "cql_delete"
		}
	case "TRUNCATE", "DROP":
		return Destructive, "cql_destructive"
	case "CREATE", "ALTER", "GRANT", "REVOKE":
		return Write, "cql_schema_or_security"
	case "ADD":
		if len(ts) > 4 && ts[1].text == "IDENTITY" && contains(ts, "TO") && contains(ts, "ROLE") {
			return Write, "cql_schema_or_security"
		}
	case "BEGIN":
		index := 1
		if index < len(ts) && oneOf(ts[index].text, "UNLOGGED", "COUNTER") {
			index++
		}
		if index >= len(ts) || ts[index].text != "BATCH" || len(ts) < index+4 || ts[len(ts)-2].text != "APPLY" || ts[len(ts)-1].text != "BATCH" {
			break
		}
		// All batch operations are writes. Delete retains its destructive warning.
		kind := Write
		for _, t := range ts[index+1 : len(ts)-2] {
			if t.kind == word && t.text == "DELETE" {
				kind = Destructive
			}
		}
		return kind, "cql_batch"
	}
	return Unknown, "unsupported_cql_structure"
}

var cqlReadFunctions = func() map[string]bool {
	functions := names(`
COUNT SUM AVG MIN MAX TOKEN TTL WRITETIME MAXWRITETIME TOJSON FROMJSON CAST
NOW UUID MINTIMEUUID MAXTIMEUUID TODATE TOTIMESTAMP TOUNIXTIMESTAMP DATEOF UNIXTIMESTAMPOF CURRENTDATE CURRENTTIME CURRENTTIMESTAMP CURRENTTIMEUUID
MIN_TIMEUUID MAX_TIMEUUID TO_DATE TO_TIMESTAMP TO_UNIX_TIMESTAMP CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP CURRENT_TIMEUUID TO_JSON FROM_JSON
ABS EXP LOG LOG10 ROUND MAP_KEYS MAP_VALUES COLLECTION_COUNT COLLECTION_MIN COLLECTION_MAX COLLECTION_SUM COLLECTION_AVG
MASK_NULL MASK_DEFAULT MASK_REPLACE MASK_INNER MASK_OUTER MASK_HASH SIMILARITY_COSINE SIMILARITY_DOT_PRODUCT SIMILARITY_EUCLIDEAN
`)
	// Cassandra 5 adds snake_case native names while retaining older spellings.
	// Only known type conversions are aliases; arbitrary underscore removal
	// could authorize an unrelated function name.
	for _, typ := range strings.Fields("ASCII BIGINT BOOLEAN COUNTER DATE DECIMAL DOUBLE DURATION FLOAT INET INT SMALLINT TEXT TIME TIMESTAMP TIMEUUID TINYINT UUID VARCHAR VARINT") {
		functions[typ+"ASBLOB"] = true
		functions["BLOBAS"+typ] = true
		functions[typ+"_AS_BLOB"] = true
		functions["BLOB_AS_"+typ] = true
	}
	return functions
}()

func cqlReadExpressions(ts []token) bool {
	return cqlExpressionContext(ts, false)
}

func cqlExpressionContext(ts []token, relation bool) bool {
	for i, t := range ts {
		if t.kind != group {
			continue
		}
		if t.text == "(" && i > 0 && isName(ts[i-1]) {
			name := ts[i-1]
			if name.kind != word {
				return false
			}
			syntax := cqlOperandGroup(ts, i, relation)
			qualified := i >= 2 && ts[i-2].text == "."
			cast := !qualified && name.text == "CAST" && contains(t.children, "AS")
			selector := !qualified && oneOf(name.text, "TTL", "WRITETIME", "MAXWRITETIME") && cqlColumnSelector(t.children)
			// Cassandra rewrites COUNT(1) to its native row-count aggregate before
			// resolving UDFs, just as the COUNT(*) grammar does.
			countRows := !qualified && name.text == "COUNT" && len(t.children) == 1 &&
				(t.children[0].kind == symbol && t.children[0].text == "*" || t.children[0].kind == literal && t.children[0].text == "1")
			system := i >= 3 && ts[i-2].text == "." && ts[i-3].kind == word && ts[i-3].text == "SYSTEM" && cqlReadFunctions[name.text]
			// Name-only native allowlists are unsafe: a keyspace UDF/UDA can
			// overload a native spelling with different argument types. Only
			// explicitly system-qualified functions and parser syntax bypass
			// confirmation; resolution of every other call is unknown.
			if !syntax && !cast && !countRows && !selector && !system {
				return false
			}
			if qualified && !system {
				return false
			}
		}
		nestedRelation := t.text == "(" && (relation && i == 0 || i > 0 && ts[i-1].kind == word && oneOf(ts[i-1].text, "WHERE", "AND"))
		if !cqlExpressionContext(t.children, nestedRelation) {
			return false
		}
	}
	return true
}

func cqlColumnSelector(ts []token) bool {
	if len(ts) == 0 || !isName(ts[0]) {
		return false
	}
	for i := 1; i < len(ts); i++ {
		if ts[i].kind == group && ts[i].text == "[" {
			continue
		}
		if ts[i].text != "." || i+1 == len(ts) || !isName(ts[i+1]) {
			return false
		}
		i++
	}
	return true
}

func cqlIdentifierList(ts []token) bool {
	if len(ts) == 0 || len(ts)%2 == 0 {
		return false
	}
	for i, t := range ts {
		if i%2 == 0 && !isName(t) || i%2 == 1 && t.text != "," {
			return false
		}
	}
	return true
}

// Parentheses in tuple relations and TOKEN's relation form are grammar, not
// UDF calls. Collection/vector brackets and UDT braces are handled separately
// by cqlReadExpressions and still recursively inspect their nested terms.
func cqlOperandGroup(ts []token, i int, relation bool) bool {
	name := ts[i-1].text
	switch name {
	case "SELECT":
		return i == 1
	case "DISTINCT", "JSON":
		return i == 2 && ts[0].text == "SELECT"
	case "IN":
		return i > 1
	case "WHERE", "AND":
		return true
	case "TOKEN":
		return (relation && i == 1 || i >= 2 && oneOf(ts[i-2].text, "WHERE", "AND")) && cqlIdentifierList(ts[i].children)
	}
	return false
}

// CQLKeyspace recognizes a standalone USE without sending unsupported USE to
// the driver's shared physical connections. Quoted identifiers preserve case.
func CQLKeyspace(sql string) (string, bool) {
	l := lexer{sql: sql, engine: "cassandra"}
	ts, ok := l.scan(0, 0)
	if !ok {
		return "", false
	}
	if len(ts) == 3 && ts[2].text == ";" {
		ts = ts[:2]
	}
	if len(ts) != 2 || ts[0].text != "USE" || !isName(ts[1]) {
		return "", false
	}
	raw := sql[ts[1].start:ts[1].end]
	if ts[1].kind == identifier {
		return strings.ReplaceAll(raw[1:len(raw)-1], `""`, `"`), true
	}
	return strings.ToLower(raw), true
}
