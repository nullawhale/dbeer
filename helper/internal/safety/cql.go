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

var cqlReadFunctions = names("COUNT SUM AVG MIN MAX TOKEN TTL WRITETIME MAXWRITETIME TOJSON CAST BLOBASASCII BLOBASBIGINT BLOBASBOOLEAN BLOBASCOUNTER BLOBASDECIMAL BLOBASDOUBLE BLOBASFLOAT BLOBASINET BLOBASINT BLOBASSMALLINT BLOBASDATE BLOBASDURATION BLOBASUUID BLOBASVARCHAR BLOBASVARINT BLOBASASCII BLOBASBLOB ASCIIASBLOB BIGINTASBLOB BOOLEANASBLOB COUNTERASBLOB DECIMALASBLOB DOUBLEASBLOB FLOATASBLOB INETASBLOB INTASBLOB SMALLINTASBLOB TEXTASBLOB TINYINTASBLOB TIMESTAMPASBLOB TIMEUUIDASBLOB UUIDASBLOB VARCHARASBLOB VARINTASBLOB NOW UUID MINTIMEUUID MAXTIMEUUID TODATE TOTIMESTAMP TOUNIXTIMESTAMP DATEOF UNIXTIMESTAMPOF CURRENTDATE CURRENTTIME CURRENTTIMESTAMP CURRENTTIMEUUID SIMILARITY_COSINE SIMILARITY_DOT_PRODUCT SIMILARITY_EUCLIDEAN")

func cqlReadExpressions(ts []token) bool {
	for i, t := range ts {
		if t.kind != group {
			continue
		}
		if i > 0 && isName(ts[i-1]) {
			name := ts[i-1]
			if name.kind != word {
				return false
			}
			syntax := oneOf(name.text, "IN", "FROM", "SELECT", "DISTINCT")
			qualified := i >= 2 && ts[i-2].text == "."
			cast := !qualified && name.text == "CAST" && contains(t.children, "AS")
			selector := !qualified && oneOf(name.text, "TTL", "WRITETIME") && len(t.children) == 1 && isName(t.children[0])
			countStar := !qualified && name.text == "COUNT" && len(t.children) == 1 && t.children[0].kind == symbol && t.children[0].text == "*"
			system := i >= 3 && ts[i-2].text == "." && ts[i-3].kind == word && ts[i-3].text == "SYSTEM" && cqlReadFunctions[name.text]
			// Name-only native allowlists are unsafe: a keyspace UDF/UDA can
			// overload a native spelling with different argument types. Only
			// explicitly system-qualified functions and parser syntax bypass
			// confirmation; resolution of every other call is unknown.
			if !syntax && !cast && !countStar && !selector && !system {
				return false
			}
			if qualified && !system {
				return false
			}
		}
		if !cqlReadExpressions(t.children) {
			return false
		}
	}
	return true
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
