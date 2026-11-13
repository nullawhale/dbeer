package safety

// CQLTraceTarget uses the ordinary CQL classifier and scanner, including their
// function allowlist. Driver placeholders cannot reach tracing without values.
func CQLTraceTarget(sql string) bool {
	statements := Classify("cassandra", sql)
	if len(statements) != 1 || statements[0].Kind != Read || statements[0].Reason != "cql_select" {
		return false
	}
	l := lexer{sql: sql, engine: "cassandra"}
	tokens, ok := l.scan(0, 0)
	if !ok {
		return false
	}
	var valid func([]token, bool) bool
	valid = func(tokens []token, mapLiteral bool) bool {
		for i, t := range tokens {
			if t.kind == symbol && (t.text == "?" || t.text == ":" && (!mapLiteral || i == 0 || tokens[i-1].kind == symbol && tokens[i-1].text == ":")) {
				return false
			}
			if t.kind == group && !valid(t.children, t.text == "{") {
				return false
			}
		}
		return true
	}
	return valid(tokens, false)
}
