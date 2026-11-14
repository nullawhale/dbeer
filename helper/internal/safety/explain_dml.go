package safety

// ExplainTarget is classification evidence only; the original SQL is executed
// unchanged after the adapter adds its reviewed EXPLAIN prefix.
type ExplainTarget struct {
	Statement        string
	DataModifyingCTE bool
	MySQLMultiTable  bool
}

func (t ExplainTarget) DML() bool { return t.Statement != "select" || t.DataModifyingCTE }

// ClassifyExplainTarget admits one unwrapped SQL query or supported DML shape.
// It deliberately does not infer writes by searching quoted/comment text.
func ClassifyExplainTarget(engine, sql string) (ExplainTarget, bool) {
	if engine == "postgresql" {
		engine = "postgres"
	}
	if engine != "postgres" && engine != "mysql" && engine != "sqlite" {
		return ExplainTarget{}, false
	}
	l := lexer{sql: sql, engine: engine}
	ts, ok := l.scan(0, 0)
	if !ok {
		return ExplainTarget{}, false
	}
	if len(ts) > 0 && ts[len(ts)-1].text == ";" {
		ts = ts[:len(ts)-1]
	}
	if len(ts) == 0 || contains(ts, ";") {
		return ExplainTarget{}, false
	}
	target, ok := explainTargetTokens(engine, ts, 0)
	if !ok {
		return target, false
	}
	if !target.DML() {
		return target, VisualExplainTarget(engine, sql)
	}
	return target, true
}
func explainTargetTokens(engine string, ts []token, depth int) (ExplainTarget, bool) {
	fail := func() (ExplainTarget, bool) { return ExplainTarget{}, false }
	if depth > 128 || len(ts) == 0 || ts[0].kind != word {
		return fail()
	}
	cteWrite := false
	if ts[0].text == "WITH" {
		i := 1
		if i < len(ts) && ts[i].text == "RECURSIVE" {
			i++
		}
		for {
			if i >= len(ts) || !isName(ts[i]) {
				return fail()
			}
			i++
			if i < len(ts) && ts[i].kind == group {
				if !identifierList(ts[i]) {
					return fail()
				}
				i++
			}
			if i >= len(ts) || ts[i].text != "AS" {
				return fail()
			}
			i++
			if engine == "postgres" && i < len(ts) && ts[i].text == "NOT" {
				i++
				if i >= len(ts) || ts[i].text != "MATERIALIZED" {
					return fail()
				}
			}
			if engine == "postgres" && i < len(ts) && ts[i].text == "MATERIALIZED" {
				i++
			}
			if i >= len(ts) || ts[i].kind != group || ts[i].text != "(" {
				return fail()
			}
			body, ok := explainTargetTokens(engine, ts[i].children, depth+1)
			if !ok || body.DML() && engine != "postgres" {
				return fail()
			}
			cteWrite = cteWrite || body.DML()
			i++
			if i < len(ts) && ts[i].text == "," {
				i++
				continue
			}
			break
		}
		if i >= len(ts) {
			return fail()
		}
		target, ok := explainTargetTokens(engine, ts[i:], depth+1)
		target.DataModifyingCTE = target.DataModifyingCTE || cteWrite
		return target, ok
	}
	target := ExplainTarget{}
	switch ts[0].text {
	case "SELECT":
		target.Statement = "select"
	case "INSERT":
		target.Statement = "insert"
		// Server-specific conflict/priority clauses remain exact server syntax.
		if !contains(ts[1:], "INTO") {
			return fail()
		}
	case "UPDATE":
		target.Statement = "update"
		set := -1
		for i := 1; i < len(ts); i++ {
			if ts[i].kind == word && ts[i].text == "SET" {
				set = i
				break
			}
		}
		if set < 2 || set == len(ts)-1 {
			return fail()
		}
		if engine == "mysql" {
			for _, t := range ts[1:set] {
				if t.text == "," || t.kind == word && oneOf(t.text, "JOIN", "STRAIGHT_JOIN") {
					target.MySQLMultiTable = true
				}
			}
		}
	case "DELETE":
		target.Statement = "delete"
		from := -1
		for i := 1; i < len(ts); i++ {
			if ts[i].kind == word && ts[i].text == "FROM" {
				from = i
				break
			}
		}
		if from < 1 || from == len(ts)-1 {
			return fail()
		}
		if engine == "mysql" {
			i := 1
			for i < from && ts[i].kind == word && oneOf(ts[i].text, "LOW_PRIORITY", "QUICK", "IGNORE") {
				i++
			}
			target.MySQLMultiTable = i < from
			for _, t := range ts[from+1:] {
				if t.kind == word && t.text == "USING" {
					target.MySQLMultiTable = true
				}
				if t.kind == word && oneOf(t.text, "WHERE", "ORDER", "LIMIT") {
					break
				}
			}
		}
	default:
		return fail()
	}
	var safe func([]token) bool
	safe = func(tokens []token) bool {
		for _, t := range tokens {
			if t.text == ";" || t.kind == word && oneOf(t.text, "EXPLAIN", "EXECUTE", "CALL", "COPY", "LOAD", "MERGE", "CREATE", "DROP", "ALTER", "TRUNCATE", "GRANT", "REVOKE", "BEGIN", "COMMIT", "ROLLBACK", "PRAGMA", "ATTACH", "DETACH", "VACUUM") {
				return false
			}
			if t.kind == symbol && (oneOf(t.text, "$", ":", ":=") || (engine == "mysql" || engine == "sqlite") && oneOf(t.text, "?", "@")) {
				return false
			}
			if t.kind == group && !safe(t.children) {
				return false
			}
		}
		return true
	}
	return target, safe(ts)
}

// ClassifyEstimatedExplain suppresses only the explained statement's DML effect.
// Expressions keep the ordinary function/side-effect policy: optimizers may
// evaluate routines while planning, including MySQL derived-table functions.
func ClassifyEstimatedExplain(engine, sql string) []Statement {
	target, ok := ClassifyExplainTarget(engine, sql)
	if !ok || !target.DML() {
		return Classify(engine, sql)
	}
	if engine == "postgresql" {
		engine = "postgres"
	}
	l := lexer{sql: sql, engine: engine}
	ts, ok := l.scan(0, 0)
	if !ok {
		return []Statement{{0, len(sql), Unknown, "unsupported_explain_expression"}}
	}
	if len(ts) > 0 && ts[len(ts)-1].text == ";" {
		ts = ts[:len(ts)-1]
	}
	kind, reason := estimatedExplainExpressions(engine, ts, 0)
	return []Statement{{ts[0].start, ts[len(ts)-1].end, kind, reason}}
}
func estimatedExplainExpressions(engine string, ts []token, depth int) (Kind, string) {
	if depth > 128 || len(ts) == 0 {
		return Unknown, "unsupported_explain_expression"
	}
	if ts[0].text == "WITH" {
		kind, reason := Read, "explain_without_dml_execution"
		i := 1
		if i < len(ts) && ts[i].text == "RECURSIVE" {
			i++
		}
		for {
			// ClassifyExplainTarget already validated each CTE declaration.
			i++
			if i < len(ts) && ts[i].kind == group {
				i++
			}
			i++
			if i < len(ts) && ts[i].text == "NOT" {
				i++
			}
			if i < len(ts) && ts[i].text == "MATERIALIZED" {
				i++
			}
			if i >= len(ts) || ts[i].kind != group {
				return Unknown, "unsupported_explain_expression"
			}
			body, why := estimatedExplainExpressions(engine, ts[i].children, depth+1)
			kind, reason = combine(kind, reason, body, why)
			i++
			if i < len(ts) && ts[i].text == "," {
				i++
				continue
			}
			break
		}
		body, why := estimatedExplainExpressions(engine, ts[i:], depth+1)
		return combine(kind, reason, body, why)
	}
	if ts[0].text == "SELECT" {
		return inspectQuery(engine, ts, depth+1)
	}
	if !oneOf(ts[0].text, "INSERT", "UPDATE", "DELETE") {
		return Unknown, "unsupported_explain_expression"
	}
	// These tokens are assessment-only. Reuse the existing expression grammar
	// with a read prefix; the exact user SQL is never changed or dispatched here.
	expressions := append([]token(nil), ts...)
	expressions[0].text = "SELECT"
	if ts[0].text == "INSERT" {
		i := 1
		for i < len(ts) && ts[i].text != "INTO" {
			i++
		}
		i++
		if i < len(ts) && ts[i].text == "ONLY" {
			i++
		}
		if i < len(ts) && isName(ts[i]) {
			i++
			for i+1 < len(ts) && ts[i].text == "." && isName(ts[i+1]) {
				i += 2
			}
			if i+1 < len(ts) && ts[i].text == "AS" && isName(ts[i+1]) {
				i += 2
			}
			if i < len(ts) && ts[i].kind == group && identifierList(ts[i]) {
				expressions[i].kind = symbol
				expressions[i].children = nil
			}
		}
		for j := i; j < len(ts); j++ {
			if ts[j].kind == word && ts[j].text == "SELECT" {
				break
			}
			if ts[j].kind == word && ts[j].text == "VALUES" {
				expressions[j].kind = symbol
				break
			}
		}
	}
	for i, t := range ts {
		if t.kind != word {
			continue
		}
		if t.text == "SET" && ts[0].text == "UPDATE" {
			expressions[i].kind = symbol
			break
		}
	}
	for i, t := range ts {
		if t.kind == group && identifierList(t) && i >= 2 && ts[i-1].kind == word && ts[i-1].text == "CONFLICT" && ts[i-2].text == "ON" {
			expressions[i].kind = symbol
			expressions[i].children = nil
		}
	}
	return inspectExpressions(engine, expressions, depth+1)
}
