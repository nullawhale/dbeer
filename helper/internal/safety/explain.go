package safety

// VisualExplainTarget reuses the dialect scanner; quoted text/comments never
// become statement boundaries or executable prefixes. Only unknown functions
// retain the existing review policy; other unknown syntax is unsupported.
func VisualExplainTarget(engine, sql string) bool {
	if engine == "postgresql" {
		engine = "postgres"
	}
	if engine != "postgres" && engine != "mysql" {
		return false
	}
	l := lexer{sql: sql, engine: engine}
	ts, ok := l.scan(0, 0)
	if !ok {
		return false
	}
	if len(ts) > 0 && ts[len(ts)-1].text == ";" {
		ts = ts[:len(ts)-1]
	}
	if len(ts) == 0 || ts[0].kind != word || !oneOf(ts[0].text, "SELECT", "WITH") || contains(ts, ";") {
		return false
	}

	var walk func([]token) bool
	walk = func(tokens []token) bool {
		for i, t := range tokens {
			if t.kind == word && t.text == "FOR" && i+1 < len(tokens) && oneOf(tokens[i+1].text, "UPDATE", "SHARE", "NO", "KEY") {
				return false
			}
			if t.kind == word && i+1 < len(tokens) && tokens[i+1].kind == group && (engine == "postgres" && postgresWriteFunctions[t.text] || engine == "mysql" && t.text == "LAST_INSERT_ID" && len(tokens[i+1].children) > 0) {
				return false
			}
			if t.kind == symbol && (oneOf(t.text, "$", ":", ":=") || engine == "mysql" && oneOf(t.text, "?", "@")) {
				return false
			}
			if t.kind == word && oneOf(t.text, "INSERT", "DELETE", "UPDATE", "MERGE", "INTO", "LOCK", "EXECUTE", "CALL", "COPY", "LOAD", "EXPLAIN") {
				return false
			}
			if t.kind == group && !walk(t.children) {
				return false
			}
		}
		return true
	}
	if !walk(ts) {
		return false
	}
	return visualExplainReadQuery(engine, ts, 0)
}

// CTE shape validation follows the same balanced-token grammar as classifyWith,
// while requiring a SELECT main statement and read-only CTE bodies. Unknown
// functions remain reviewable, including within MySQL CTEs.
func visualExplainReadQuery(engine string, ts []token, depth int) bool {
	if len(ts) == 0 || depth > 128 || ts[0].kind != word {
		return false
	}
	if ts[0].text == "SELECT" {
		kind, reason := inspectQuery(engine, ts, depth+1)
		return kind == Read || kind == Unknown && reason == "unknown_function"
	}
	if ts[0].text != "WITH" {
		return false
	}
	i := 1
	if i < len(ts) && ts[i].text == "RECURSIVE" {
		i++
	}
	for {
		if i >= len(ts) || !isName(ts[i]) {
			return false
		}
		i++
		if i < len(ts) && ts[i].kind == group {
			if !identifierList(ts[i]) {
				return false
			}
			i++
		}
		if i >= len(ts) || ts[i].text != "AS" {
			return false
		}
		i++
		if engine == "postgres" && i < len(ts) && ts[i].text == "NOT" {
			i++
			if i >= len(ts) || ts[i].text != "MATERIALIZED" {
				return false
			}
		}
		if engine == "postgres" && i < len(ts) && ts[i].text == "MATERIALIZED" {
			i++
		}
		if i >= len(ts) || ts[i].kind != group || ts[i].text != "(" || !visualExplainReadQuery(engine, ts[i].children, depth+1) {
			return false
		}
		i++
		if i < len(ts) && ts[i].text == "," {
			i++
			continue
		}
		break
	}
	return i < len(ts) && ts[i].kind == word && ts[i].text == "SELECT" && visualExplainReadQuery(engine, ts[i:], depth+1)
}
