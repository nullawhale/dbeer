// Package safety conservatively assesses SQL before it reaches a database.
// It is deliberately not a server SQL parser: unsupported or ambiguous syntax
// is unknown, rather than being guessed to be a read. Database privileges and
// the adapter's server read-only mode remain necessary additional boundaries.
package safety

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

type Kind string

const (
	Read        Kind = "read"
	Write       Kind = "write"
	Destructive Kind = "destructive"
	Unknown     Kind = "unknown"
)

// Statement uses UTF-8 byte offsets into the exact input, excluding surrounding
// whitespace/comments and the separating semicolon. No normalized SQL is used
// for either confirmation or execution.
type Statement struct {
	Start  int
	End    int
	Kind   Kind
	Reason string
}

// Classify returns every top-level statement in execution order. A lexical
// failure makes the whole input unknown, so a partially scanned script can
// never be authorized as a sequence of reads.
func Classify(engine, sql string) []Statement {
	if engine == "postgresql" {
		engine = "postgres"
	}
	if engine != "postgres" && engine != "mysql" {
		return []Statement{{0, len(sql), Unknown, "unsupported_dialect"}}
	}
	l := lexer{sql: sql, engine: engine}
	tokens, ok := l.scan(0, 0)
	if !ok {
		return []Statement{{0, len(sql), Unknown, "ambiguous_or_invalid_syntax"}}
	}
	var result []Statement
	start := 0
	for i := 0; i <= len(tokens); i++ {
		if i < len(tokens) && tokens[i].text != ";" {
			continue
		}
		if i > start {
			part := tokens[start:i]
			kind, reason := classify(engine, part, 0)
			result = append(result, Statement{part[0].start, part[len(part)-1].end, kind, reason})
		}
		start = i + 1
	}
	return result
}

type tokenKind uint8

const (
	word tokenKind = iota
	identifier
	literal
	symbol
	group
)

type token struct {
	kind     tokenKind
	text     string
	start    int
	end      int
	children []token
}

type lexer struct {
	sql    string
	engine string
	pos    int
	count  int
}

// The scanner builds a balanced token tree. Quotes, comments and dollar
// strings are opaque; parenthesized queries are assessed recursively below.
func (l *lexer) scan(close byte, depth int) ([]token, bool) {
	if depth > 128 {
		return nil, false
	}
	var result []token
	for l.pos < len(l.sql) {
		c := l.sql[l.pos]
		if isSpace(c) {
			l.pos++
			continue
		}
		if c == '-' && l.has("--") && (l.engine == "postgres" || l.pos+2 == len(l.sql) || isSpace(l.sql[l.pos+2])) {
			l.lineComment()
			continue
		}
		if c == '#' && l.engine == "mysql" {
			l.lineComment()
			continue
		}
		if l.has("/*") {
			if !l.comment() {
				return nil, false
			}
			continue
		}
		if c == ')' || c == ']' {
			if c != close {
				return nil, false
			}
			l.pos++
			return result, true
		}
		t := token{start: l.pos}
		switch {
		case c == '(' || c == '[':
			t.kind, t.text = group, string(c)
			l.pos++
			end := byte(')')
			if c == '[' {
				end = ']'
			}
			var ok bool
			t.children, ok = l.scan(end, depth+1)
			if !ok {
				return nil, false
			}
		case c == '\'':
			t.kind = literal
			if !l.quoted('\'', false) {
				return nil, false
			}
		case c == '"' || (c == '`' && l.engine == "mysql"):
			t.kind = identifier
			if !l.quoted(c, false) {
				return nil, false
			}
		case l.engine == "postgres" && (c == 'e' || c == 'E') && l.pos+1 < len(l.sql) && l.sql[l.pos+1] == '\'':
			t.kind = literal
			l.pos++
			if !l.quoted('\'', true) {
				return nil, false
			}
		case c == '$' && l.engine == "postgres":
			delimiter := l.dollarDelimiter()
			if delimiter == "" {
				t.kind, t.text = symbol, "$"
				l.pos++
			} else {
				t.kind = literal
				l.pos += len(delimiter)
				n := strings.Index(l.sql[l.pos:], delimiter)
				if n < 0 {
					return nil, false
				}
				l.pos += n + len(delimiter)
			}
		case isWordStart(l.sql[l.pos:]):
			t.kind = word
			for l.pos < len(l.sql) && isWordContinue(l.sql[l.pos:]) {
				_, n := utf8.DecodeRuneInString(l.sql[l.pos:])
				l.pos += n
			}
			t.text = asciiUpper(l.sql[t.start:l.pos])
		case c >= '0' && c <= '9':
			t.kind = literal
			for l.pos < len(l.sql) && (isNumberByte(l.sql[l.pos])) {
				l.pos++
			}
			t.text = l.sql[t.start:l.pos]
		case strings.ContainsRune(",;.*+-/%=<>!~^|&:@?", rune(c)):
			t.kind, t.text = symbol, string(c)
			l.pos++
			if c == ':' && l.pos < len(l.sql) && (l.sql[l.pos] == '=' || l.sql[l.pos] == ':') {
				t.text += string(l.sql[l.pos])
				l.pos++
			}
		default:
			return nil, false
		}
		t.end = l.pos
		l.count++
		if l.count > 200000 {
			return nil, false
		}
		result = append(result, t)
	}
	return result, close == 0
}

func (l *lexer) has(s string) bool { return strings.HasPrefix(l.sql[l.pos:], s) }

func (l *lexer) lineComment() {
	for l.pos < len(l.sql) && l.sql[l.pos] != '\n' && l.sql[l.pos] != '\r' {
		l.pos++
	}
}

func (l *lexer) comment() bool {
	l.pos += 2
	// MySQL executable comments and optimizer hints can change semantics or
	// lexical modes. They are intentionally unsupported instead of discarded.
	if l.engine == "mysql" && l.pos < len(l.sql) && (l.sql[l.pos] == '!' || l.sql[l.pos] == '+' || l.has("M!")) {
		return false
	}
	depth := 1
	for l.pos < len(l.sql) {
		if l.has("/*") {
			if l.engine != "postgres" || depth >= 128 {
				return false
			}
			depth++
			l.pos += 2
		} else if l.has("*/") {
			depth--
			l.pos += 2
			if depth == 0 {
				return true
			}
		} else {
			l.pos++
		}
	}
	return false
}

func (l *lexer) quoted(quote byte, escaped bool) bool {
	l.pos++
	for l.pos < len(l.sql) {
		c := l.sql[l.pos]
		l.pos++
		if c == '\\' {
			// Session SQL modes affect backslash interpretation. Only explicit
			// PostgreSQL E strings have a stable escape grammar here.
			if !escaped || l.pos == len(l.sql) {
				return false
			}
			l.pos++
		} else if c == quote {
			if l.pos < len(l.sql) && l.sql[l.pos] == quote {
				l.pos++
				continue
			}
			return true
		}
	}
	return false
}

func (l *lexer) dollarDelimiter() string {
	i := l.pos + 1
	if i < len(l.sql) && l.sql[i] == '$' {
		return "$$"
	}
	if i >= len(l.sql) || !isWordStart(l.sql[i:]) {
		return ""
	}
	for i < len(l.sql) {
		if l.sql[i] == '$' {
			return l.sql[l.pos : i+1]
		}
		if !isWordStart(l.sql[i:]) && !(l.sql[i] >= '0' && l.sql[i] <= '9') {
			return ""
		}
		_, n := utf8.DecodeRuneInString(l.sql[i:])
		i += n
	}
	return ""
}

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}
func isWordStart(s string) bool {
	r, _ := utf8.DecodeRuneInString(s)
	return r == '_' || unicode.IsLetter(r)
}
func isWordContinue(s string) bool {
	r, _ := utf8.DecodeRuneInString(s)
	return r == '_' || r == '$' || unicode.IsLetter(r) || unicode.IsDigit(r)
}
func isNumberByte(c byte) bool {
	return c >= '0' && c <= '9' || c == '.' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F' || c == 'x' || c == 'X'
}

func classify(engine string, ts []token, depth int) (Kind, string) {
	if len(ts) == 0 || depth > 128 || contains(ts, ";") {
		return Unknown, "unsupported_structure"
	}
	if len(ts) == 1 && ts[0].kind == group && ts[0].text == "(" {
		return classify(engine, ts[0].children, depth+1)
	}
	if len(ts) > 2 && ts[0].kind == group && queryStart(ts[0]) && oneOf(ts[1].text, "UNION", "INTERSECT", "EXCEPT") {
		left, leftReason := classify(engine, ts[0].children, depth+1)
		index := 2
		if index < len(ts) && oneOf(ts[index].text, "ALL", "DISTINCT") {
			index++
		}
		if index >= len(ts) || !queryStart(ts[index]) {
			return Unknown, "unsupported_set_operand"
		}
		right, rightReason := classify(engine, ts[index:], depth+1)
		return combine(left, leftReason, right, rightReason)
	}
	if ts[0].kind != word {
		return Unknown, "unsupported_statement"
	}
	switch ts[0].text {
	case "WITH":
		return classifyWith(engine, ts, depth+1)
	case "SELECT", "VALUES", "TABLE":
		if len(ts) < 2 || (ts[0].text == "TABLE" && !isName(ts[1])) {
			return Unknown, "unsupported_query"
		}
		return inspectQuery(engine, ts, depth+1)
	case "SHOW":
		if len(ts) < 2 {
			return Unknown, "unsupported_show"
		}
		if engine == "postgres" {
			if len(ts) == 2 && isName(ts[1]) || words(ts, "SHOW", "TIME", "ZONE") || words(ts, "SHOW", "TRANSACTION", "ISOLATION", "LEVEL") || words(ts, "SHOW", "SESSION", "AUTHORIZATION") {
				return Read, "read"
			}
			return Unknown, "unsupported_show"
		}
		return inspectExpressions(engine, ts[1:], depth+1)
	case "EXPLAIN":
		return classifyExplain(engine, ts[1:], depth+1)
	case "DESC", "DESCRIBE":
		if engine != "mysql" || len(ts) < 2 {
			return Unknown, "unsupported_statement"
		}
		if queryStart(ts[1]) {
			return classifyExplain(engine, ts[1:], depth+1)
		}
		return inspectExpressions(engine, ts[1:], depth+1)
	case "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE":
		if len(ts) < 2 || (ts[0].text == "REPLACE" && engine != "mysql") || (ts[0].text == "MERGE" && engine != "postgres") {
			return Unknown, "unsupported_statement"
		}
		if ts[0].text == "DELETE" || ts[0].text == "MERGE" || ts[0].text == "REPLACE" || ts[0].text == "UPDATE" && !contains(ts, "WHERE") {
			return Destructive, "destructive_statement"
		}
		return Write, "data_change"
	case "CREATE":
		if len(ts) < 3 {
			return Unknown, "unsupported_definition"
		}
		if len(ts) > 2 && words(ts[:3], "CREATE", "OR", "REPLACE") {
			return Destructive, "replace_definition"
		}
		return Write, "definition_change"
	case "ALTER", "DROP", "TRUNCATE", "RENAME":
		if len(ts) < 2 {
			return Unknown, "unsupported_definition"
		}
		return Destructive, "destructive_statement"
	case "GRANT", "REVOKE", "COMMENT", "SECURITY", "REFRESH", "REINDEX", "VACUUM", "ANALYZE", "OPTIMIZE", "REPAIR", "LOAD", "IMPORT", "LOCK", "UNLOCK":
		if len(ts) < 2 {
			return Unknown, "unsupported_statement"
		}
		return Write, "database_or_session_change"
	case "COPY":
		return classifyCopy(engine, ts, depth+1)
	case "BEGIN", "START":
		return classifyBegin(engine, ts)
	case "COMMIT", "END", "ROLLBACK", "ABORT":
		return classifyTransactionEnd(engine, ts)
	case "SAVEPOINT":
		if len(ts) == 2 && isName(ts[1]) {
			return Read, "transaction_control"
		}
	case "RELEASE":
		if len(ts) == 2 && isName(ts[1]) || len(ts) == 3 && ts[1].text == "SAVEPOINT" && isName(ts[2]) {
			return Read, "transaction_control"
		}
	}
	// SET/RESET/DISCARD can override server read-only defaults, as can dynamic
	// SQL, procedures and language blocks. None is safe to infer from its name.
	return Unknown, "unsupported_statement"
}

func classifyWith(engine string, ts []token, depth int) (Kind, string) {
	i := 1
	if i < len(ts) && ts[i].text == "RECURSIVE" {
		i++
	}
	result, reason := Read, "read"
	for {
		if i >= len(ts) || !isName(ts[i]) {
			return Unknown, "unsupported_cte"
		}
		i++
		if i < len(ts) && ts[i].kind == group {
			if !identifierList(ts[i]) {
				return Unknown, "unsupported_cte_columns"
			}
			i++
		}
		if i >= len(ts) || ts[i].text != "AS" {
			return Unknown, "unsupported_cte"
		}
		i++
		if engine == "postgres" && i < len(ts) && ts[i].text == "NOT" {
			i++
			if i >= len(ts) || ts[i].text != "MATERIALIZED" {
				return Unknown, "unsupported_cte"
			}
		}
		if engine == "postgres" && i < len(ts) && ts[i].text == "MATERIALIZED" {
			i++
		}
		if i >= len(ts) || ts[i].kind != group || ts[i].text != "(" {
			return Unknown, "unsupported_cte"
		}
		kind, why := classify(engine, ts[i].children, depth+1)
		if engine == "mysql" && kind != Read {
			return Unknown, "unsupported_cte_body"
		}
		result, reason = combine(result, reason, kind, why)
		i++
		if i < len(ts) && ts[i].text == "," {
			i++
			continue
		}
		break
	}
	if i >= len(ts) {
		return Unknown, "missing_cte_statement"
	}
	kind, why := classify(engine, ts[i:], depth+1)
	return combine(result, reason, kind, why)
}

func identifierList(t token) bool {
	if t.text != "(" || len(t.children) == 0 {
		return false
	}
	for i, child := range t.children {
		if i%2 == 0 && !isName(child) || i%2 == 1 && child.text != "," {
			return false
		}
	}
	return len(t.children)%2 == 1
}

func inspectQuery(engine string, ts []token, depth int) (Kind, string) {
	result, reason := Read, "read"
	for i, t := range ts {
		if t.kind != word {
			continue
		}
		switch t.text {
		case "INTO":
			result, reason = combine(result, reason, Write, "select_into")
		case "FOR":
			if i+1 < len(ts) && (ts[i+1].text == "UPDATE" || ts[i+1].text == "SHARE" || ts[i+1].text == "NO" || ts[i+1].text == "KEY") {
				result, reason = combine(result, reason, Write, "locking_read")
			}
		case "LOCK":
			result, reason = combine(result, reason, Write, "locking_read")
		case "INSERT", "DELETE", "MERGE", "REPLACE", "CREATE", "ALTER", "DROP", "TRUNCATE", "SET", "RESET", "CALL", "DO", "EXECUTE", "PREPARE", "COPY", "LOAD", "PROCEDURE":
			if i+1 < len(ts) && ts[i+1].kind == group && (t.text == "REPLACE" || t.text == "TRUNCATE" && engine == "mysql") {
				continue
			}
			return Unknown, "unsupported_query_clause"
		case "UPDATE":
			if i == 0 || ts[i-1].text != "FOR" && ts[i-1].text != "KEY" {
				return Unknown, "unsupported_query_clause"
			}
		}
	}
	kind, why := inspectExpressions(engine, ts, depth+1)
	return combine(result, reason, kind, why)
}

func inspectExpressions(engine string, ts []token, depth int) (Kind, string) {
	return inspectExpressionContext(engine, ts, depth, "")
}

func inspectExpressionContext(engine string, ts []token, depth int, parentFunction string) (Kind, string) {
	if depth > 128 || contains(ts, ";") {
		return Unknown, "unsupported_expression"
	}
	result, reason := Read, "read"
	for i, t := range ts {
		if t.text == ":=" {
			result, reason = combine(result, reason, Write, "variable_assignment")
		}
		if t.kind != group {
			continue
		}
		kind, why := Read, "read"
		if queryStructure(t.children) {
			kind, why = classify(engine, t.children, depth+1)
		} else {
			parent := ""
			if i > 0 && ts[i-1].kind == word {
				parent = ts[i-1].text
			}
			kind, why = inspectExpressionContext(engine, t.children, depth+1, parent)
		}
		result, reason = combine(result, reason, kind, why)
		if t.text != "(" {
			continue
		}
		if i == 0 || ts[i-1].kind != word && ts[i-1].kind != identifier {
			continue
		}
		name := ts[i-1]
		qualified := i >= 2 && ts[i-2].text == "."
		if !qualified && name.kind == word && syntaxOperandGroup(engine, ts, i) {
			continue
		}
		if i >= 2 && identifierList(t) && (ts[i-2].text == "AS" || ts[i-2].kind == group) {
			// Column names attached to a table/subquery alias are declarations,
			// rather than calls of the alias as a user-defined function.
			continue
		}
		mysqlConvertType := engine == "mysql" && parentFunction == "CONVERT" && i == len(ts)-1 && i >= 3 && ts[i-2].text == ","
		if mysqlConvertType {
			commas := 0
			for _, argument := range ts {
				if argument.text == "," {
					commas++
				}
			}
			mysqlConvertType = commas == 1
		}
		if i >= 2 && name.kind == word && typeModifier(engine, name.text) &&
			(parentFunction == "CAST" && ts[i-2].text == "AS" || engine == "postgres" && ts[i-2].text == "::" || mysqlConvertType) && numericModifiers(t.children) {
			continue
		}
		// A qualified or quoted name may refer to a user function even when
		// the spelling matches a built-in; only pg_catalog is recognized.
		if name.kind == identifier || qualified && !(engine == "postgres" && i >= 3 && ts[i-3].text == "PG_CATALOG" && ts[i-3].kind == word) {
			result, reason = combine(result, reason, Unknown, "unknown_function")
			continue
		}
		if engine == "postgres" && postgresWriteFunctions[name.text] {
			result, reason = combine(result, reason, Write, "function_side_effect")
		} else if name.text == "LAST_INSERT_ID" && engine == "mysql" && len(t.children) > 0 {
			result, reason = combine(result, reason, Write, "function_side_effect")
		} else if !readFunction(engine, name.text) {
			result, reason = combine(result, reason, Unknown, "unknown_function")
		}
	}
	return result, reason
}

func classifyExplain(engine string, ts []token, depth int) (Kind, string) {
	if len(ts) == 0 {
		return Unknown, "unsupported_explain"
	}
	analyze := false
	i := 0
	if engine == "postgres" && ts[0].kind == group {
		options := ts[0].children
		for j := 0; j < len(options); {
			if options[j].kind != word || !explainOptions[options[j].text] {
				return Unknown, "unsupported_explain_option"
			}
			name := options[j].text
			j++
			value := "TRUE"
			if j < len(options) && options[j].text != "," {
				value = options[j].text
				if options[j].kind != word && options[j].kind != literal {
					return Unknown, "unsupported_explain_option"
				}
				j++
			}
			if name == "ANALYZE" || name == "ANALYSE" {
				switch value {
				case "TRUE", "ON", "1":
					analyze = true
				case "FALSE", "OFF", "0":
				default:
					return Unknown, "unsupported_explain_option"
				}
			}
			if j < len(options) {
				if options[j].text != "," || j+1 == len(options) {
					return Unknown, "unsupported_explain_option"
				}
				j++
			}
		}
		i++
	}
	for i < len(ts) {
		if ts[i].text == "ANALYZE" || ts[i].text == "ANALYSE" {
			analyze = true
			i++
		} else if engine == "postgres" && ts[i].text == "VERBOSE" {
			i++
		} else if engine == "mysql" && ts[i].text == "FORMAT" {
			if i+2 >= len(ts) || ts[i+1].text != "=" || !oneOf(ts[i+2].text, "JSON", "TREE", "TRADITIONAL") {
				return Unknown, "unsupported_explain_option"
			}
			i += 3
		} else {
			break
		}
	}
	if i >= len(ts) {
		return Unknown, "missing_explain_statement"
	}
	kind, reason := classify(engine, ts[i:], depth+1)
	if kind == Unknown || analyze {
		return kind, reason
	}
	return Read, "explain_without_execution"
}

func classifyCopy(engine string, ts []token, depth int) (Kind, string) {
	if engine != "postgres" || len(ts) < 4 {
		return Unknown, "unsupported_copy"
	}
	for _, t := range ts {
		if t.text == "PROGRAM" {
			return Unknown, "external_program"
		}
	}
	for i, t := range ts {
		if t.text == "FROM" {
			return Write, "copy_from"
		}
		if t.text == "TO" && i+1 < len(ts) {
			if ts[i+1].text != "STDOUT" {
				return Write, "copy_to_file"
			}
			if ts[1].kind == group {
				return classify(engine, ts[1].children, depth+1)
			}
			if !isName(ts[1]) {
				return Unknown, "unsupported_copy_source"
			}
			return Read, "copy_to_stdout"
		}
	}
	return Unknown, "unsupported_copy"
}

func classifyBegin(engine string, ts []token) (Kind, string) {
	i := 1
	if ts[0].text == "START" {
		if len(ts) < 2 || ts[1].text != "TRANSACTION" {
			return Unknown, "unsupported_transaction"
		}
		i++
	} else if i < len(ts) && oneOf(ts[i].text, "WORK", "TRANSACTION") {
		i++
	}
	for i < len(ts) {
		switch {
		case ts[i].text == ",":
			i++
		case i+1 < len(ts) && ts[i].text == "READ" && ts[i+1].text == "WRITE":
			return Write, "read_write_transaction"
		case i+1 < len(ts) && ts[i].text == "READ" && ts[i+1].text == "ONLY":
			i += 2
		case engine == "postgres" && ts[i].text == "DEFERRABLE":
			i++
		case engine == "postgres" && i+1 < len(ts) && ts[i].text == "NOT" && ts[i+1].text == "DEFERRABLE":
			i += 2
		case engine == "mysql" && i+2 < len(ts) && words(ts[i:i+3], "WITH", "CONSISTENT", "SNAPSHOT"):
			i += 3
		case i+2 < len(ts) && ts[i].text == "ISOLATION" && ts[i+1].text == "LEVEL":
			i += 2
			if ts[i].text == "SERIALIZABLE" {
				i++
			} else if i+1 < len(ts) && (ts[i].text == "READ" && oneOf(ts[i+1].text, "COMMITTED", "UNCOMMITTED") || words(ts[i:i+2], "REPEATABLE", "READ")) {
				i += 2
			} else {
				return Unknown, "unsupported_transaction"
			}
		default:
			return Unknown, "unsupported_transaction"
		}
	}
	return Read, "transaction_control"
}

func classifyTransactionEnd(engine string, ts []token) (Kind, string) {
	i := 1
	if i < len(ts) && oneOf(ts[i].text, "WORK", "TRANSACTION") {
		i++
	}
	if ts[0].text == "ROLLBACK" && i < len(ts) && ts[i].text == "TO" {
		i++
		if i < len(ts) && ts[i].text == "SAVEPOINT" {
			i++
		}
		if i+1 == len(ts) && isName(ts[i]) {
			return Read, "transaction_control"
		}
		return Unknown, "unsupported_transaction"
	}
	if i < len(ts) && ts[i].text == "AND" {
		i++
		if i < len(ts) && ts[i].text == "NO" {
			i++
		}
		if i < len(ts) && ts[i].text == "CHAIN" {
			i++
		} else {
			return Unknown, "unsupported_transaction"
		}
	}
	if engine == "mysql" && i < len(ts) {
		if ts[i].text == "NO" {
			i++
		}
		if i < len(ts) && ts[i].text == "RELEASE" {
			i++
		}
	}
	if i != len(ts) {
		return Unknown, "unsupported_transaction"
	}
	return Read, "transaction_control"
}

func queryStart(t token) bool {
	if t.kind == group && t.text == "(" {
		return len(t.children) > 0 && queryStart(t.children[0])
	}
	return t.kind == word && oneOf(t.text, "SELECT", "WITH", "VALUES", "TABLE")
}

func queryStructure(tokens []token) bool {
	if len(tokens) == 0 || !queryStart(tokens[0]) {
		return false
	}
	return tokens[0].kind != group || len(tokens) == 1 || oneOf(tokens[1].text, "UNION", "INTERSECT", "EXCEPT")
}

// A keyword before parentheses is not automatically syntax: FILTER, OVER,
// ZONE, BY and many other keyword spellings are legal user function names.
// Exempt only the operand position established by the surrounding token tree.
func syntaxOperandGroup(engine string, tokens []token, groupIndex int) bool {
	nameIndex := groupIndex - 1
	name := tokens[nameIndex].text
	before := func(offset int, text string) bool {
		return nameIndex-offset >= 0 && tokens[nameIndex-offset].kind == word && tokens[nameIndex-offset].text == text
	}
	endsExpression := func(index int) bool {
		if index < 0 {
			return false
		}
		token := tokens[index]
		if token.kind == group || token.kind == identifier || token.kind == literal {
			return true
		}
		if token.kind == symbol && token.text == "*" {
			return true
		}
		return token.kind == word && (!expressionKeywords[token.text] || oneOf(token.text, "NULL", "TRUE", "FALSE", "END"))
	}
	queryPrefix := func() bool {
		return len(tokens) > 0 && tokens[0].kind == word && oneOf(tokens[0].text, "SELECT", "TABLE", "VALUES")
	}
	switch name {
	case "SELECT", "VALUES":
		return nameIndex == 0
	case "DISTINCT":
		return before(1, "SELECT")
	case "EXISTS":
		return queryStructure(tokens[groupIndex].children)
	case "ROW":
		return true // dedicated row constructor grammar
	case "ARRAY":
		return engine == "postgres" // MySQL has no ARRAY constructor
	case "ANY", "SOME":
		return nameIndex > 0 && tokens[nameIndex-1].kind == symbol
	case "ALL":
		return before(1, "SELECT") || before(1, "UNION") || before(1, "INTERSECT") || before(1, "EXCEPT") || nameIndex > 0 && tokens[nameIndex-1].kind == symbol
	case "UNION", "INTERSECT", "EXCEPT":
		return nameIndex > 0 && queryStructure(tokens[groupIndex].children)
	case "OVER", "FILTER":
		return nameIndex > 0 && tokens[nameIndex-1].kind == group && tokens[nameIndex-1].text == "("
	case "BY":
		return before(1, "ORDER") || before(1, "GROUP") || before(1, "PARTITION")
	case "ZONE":
		return engine == "postgres" && before(1, "TIME") && before(2, "AT") && endsExpression(nameIndex-3)
	case "FIRST", "NEXT":
		return before(1, "FETCH")
	case "TO":
		return before(1, "SIMILAR") && endsExpression(nameIndex-2)
	case "GROUP":
		return before(1, "WITHIN") && nameIndex > 1 && tokens[nameIndex-2].kind == group
	case "SETS":
		return before(1, "GROUPING") && before(2, "BY") && before(3, "GROUP")
	case "ROLLUP", "CUBE":
		if before(1, "BY") && before(2, "GROUP") {
			return true
		}
		if nameIndex == 0 || tokens[nameIndex-1].text != "," {
			return false
		}
		inGrouping := false
		for index := 0; index < nameIndex; index++ {
			if tokens[index].kind != word {
				continue
			}
			if tokens[index].text == "GROUP" && index+1 < nameIndex && tokens[index+1].text == "BY" {
				inGrouping = true
			} else if oneOf(tokens[index].text, "HAVING", "ORDER", "LIMIT", "OFFSET", "UNION", "INTERSECT", "EXCEPT") {
				inGrouping = false
			}
		}
		return inGrouping
	case "IN", "BETWEEN", "LIKE", "ILIKE", "SIMILAR", "IS", "AND", "OR":
		return endsExpression(nameIndex-1) || before(1, "NOT") && endsExpression(nameIndex-2)
	case "NOT":
		return nameIndex == 0 || before(1, "SELECT") || before(1, "WHERE") || before(1, "HAVING") || before(1, "AND") || before(1, "OR") || before(1, "IS") || before(1, "WHEN")
	case "CASE":
		return groupIndex+1 < len(tokens) && tokens[groupIndex+1].text == "WHEN"
	case "WHEN", "THEN", "ELSE":
		for _, token := range tokens[:nameIndex] {
			if token.kind == word && token.text == "CASE" {
				return true
			}
		}
		return false
	case "WHERE":
		return nameIndex == 0 || queryPrefix() && endsExpression(nameIndex-1)
	case "FROM", "HAVING", "ON", "LIMIT", "OFFSET", "JOIN", "USING":
		return queryPrefix() && endsExpression(nameIndex-1)
	case "LATERAL":
		return (before(1, "FROM") || before(1, "JOIN") || nameIndex > 0 && tokens[nameIndex-1].text == ",") && queryStructure(tokens[groupIndex].children)
	case "INTERVAL":
		return engine == "mysql" && groupIndex+1 < len(tokens) && tokens[groupIndex+1].kind == word && oneOf(tokens[groupIndex+1].text, "MICROSECOND", "SECOND", "MINUTE", "HOUR", "DAY", "WEEK", "MONTH", "QUARTER", "YEAR", "SECOND_MICROSECOND", "MINUTE_MICROSECOND", "MINUTE_SECOND", "HOUR_MICROSECOND", "HOUR_SECOND", "HOUR_MINUTE", "DAY_MICROSECOND", "DAY_SECOND", "DAY_MINUTE", "DAY_HOUR", "YEAR_MONTH")
	}
	return false
}
func isName(t token) bool { return t.kind == word || t.kind == identifier }
func contains(ts []token, value string) bool {
	for _, t := range ts {
		if t.text == value && (t.kind == word || t.kind == symbol) {
			return true
		}
	}
	return false
}
func words(ts []token, values ...string) bool {
	if len(ts) != len(values) {
		return false
	}
	for i, value := range values {
		if ts[i].kind != word || ts[i].text != value {
			return false
		}
	}
	return true
}
func oneOf(value string, choices ...string) bool {
	for _, choice := range choices {
		if value == choice {
			return true
		}
	}
	return false
}

func numericModifiers(ts []token) bool {
	if len(ts) == 0 || len(ts)%2 == 0 {
		return false
	}
	for i, t := range ts {
		if i%2 == 0 {
			if t.kind != literal || t.text == "" {
				return false
			}
			for _, c := range t.text {
				if c < '0' || c > '9' {
					return false
				}
			}
		} else if t.text != "," {
			return false
		}
	}
	return true
}
func combine(a Kind, ar string, b Kind, br string) (Kind, string) {
	priority := map[Kind]int{Read: 0, Write: 1, Destructive: 2, Unknown: 3}
	if priority[b] > priority[a] {
		return b, br
	}
	return a, ar
}
func names(values string) map[string]bool {
	result := make(map[string]bool)
	for _, value := range strings.Fields(values) {
		result[value] = true
	}
	return result
}

// PostgreSQL/MySQL SQL keywords are ASCII. Unicode case folding can turn a
// distinct user-defined identifier (for example abſ) into an allowlisted ABS.
func asciiUpper(value string) string {
	bytes := []byte(value)
	for index, c := range bytes {
		if c >= 'a' && c <= 'z' {
			bytes[index] = c - ('a' - 'A')
		}
	}
	return string(bytes)
}

var expressionKeywords = names("SELECT IN EXISTS ANY ALL SOME AS OVER FILTER PARTITION GROUP BY ORDER FROM WHERE HAVING ON USING DISTINCT VALUES ROW ARRAY WITHIN ROLLUP CUBE GROUPING SETS NOT AND OR UNION INTERSECT EXCEPT JOIN INNER OUTER LEFT RIGHT FULL CROSS LATERAL CASE WHEN THEN ELSE BETWEEN LIKE ILIKE SIMILAR TO IS ZONE LIMIT OFFSET FETCH FIRST NEXT INTERVAL")
var postgresTypeModifiers = names("NUMERIC DECIMAL CHAR VARCHAR CHARACTER NCHAR TIME TIMESTAMP INTERVAL BIT VARBIT FLOAT")
var mysqlTypeModifiers = names("DECIMAL CHAR NCHAR TIME DATETIME BINARY FLOAT")

func typeModifier(engine, name string) bool {
	return engine == "postgres" && postgresTypeModifiers[name] || engine == "mysql" && mysqlTypeModifiers[name]
}

var explainOptions = names("ANALYZE ANALYSE VERBOSE COSTS SETTINGS GENERIC_PLAN BUFFERS SERIALIZE WAL TIMING SUMMARY MEMORY FORMAT")
var postgresWriteFunctions = names("NEXTVAL SETVAL PG_ADVISORY_LOCK PG_ADVISORY_XACT_LOCK PG_TRY_ADVISORY_LOCK PG_TRY_ADVISORY_XACT_LOCK PG_ADVISORY_UNLOCK PG_ADVISORY_UNLOCK_ALL")

// Positive per-dialect sets avoid assuming a builtin from the other engine is
// harmless. An unrecognized spelling can be a user-defined function.
var postgresReadFunctions = names("TRUNC PG_SLEEP PG_SLEEP_FOR PG_SLEEP_UNTIL PG_BACKEND_PID PG_IS_IN_RECOVERY PG_POSTMASTER_START_TIME CURRENT_DATABASE CURRENT_SCHEMA CURRENT_SCHEMAS CURRENT_SETTING PG_TYPEOF FORMAT_TYPE TO_CHAR TO_DATE TO_NUMBER TO_TIMESTAMP DATE_TRUNC DATE_PART GENERATE_SERIES GENERATE_SUBSCRIPTS UNNEST JSONB_BUILD_OBJECT JSONB_BUILD_ARRAY JSONB_AGG JSONB_OBJECT_AGG ARRAY_AGG STRING_AGG BOOL_AND BOOL_OR EVERY CLOCK_TIMESTAMP STATEMENT_TIMESTAMP TRANSACTION_TIMESTAMP AGE MAKE_DATE MAKE_TIME MAKE_TIMESTAMP BTRIM CHR STRPOS SPLIT_PART ARRAY_LENGTH ARRAY_LOWER ARRAY_UPPER ARRAY_POSITION ARRAY_TO_STRING CARDINALITY JSON_AGG JSON_OBJECT_AGG JSON_BUILD_OBJECT JSON_BUILD_ARRAY ENCODE DECODE TO_HEX REGEXP_MATCH REGEXP_MATCHES RANDOM")
var mysqlReadFunctions = names("SCHEMA TRUNCATE CHAR SYSTEM_USER USER DATABASE CONNECTION_ID FOUND_ROWS LAST_INSERT_ID IF IFNULL ISNULL GROUP_CONCAT BIT_XOR JSON_EXTRACT JSON_UNQUOTE JSON_ARRAY JSON_OBJECT JSON_ARRAYAGG JSON_OBJECTAGG JSON_TYPE JSON_VALID JSON_LENGTH JSON_KEYS SHA SHA1 SHA2 HEX UNHEX SLEEP RAND")
var commonReadFunctions = names(`
COUNT SUM MIN MAX AVG ABS ACOS ASIN ATAN ATAN2 CEIL CEILING COS COT DEGREES EXP FLOOR LN LOG LOG10 MOD PI POWER POW RADIANS ROUND SIGN SIN SQRT TAN
COALESCE NULLIF GREATEST LEAST CAST CONVERT EXTRACT POSITION SUBSTRING SUBSTR TRIM LTRIM RTRIM UPPER LOWER LENGTH CHAR_LENGTH CHARACTER_LENGTH OCTET_LENGTH BIT_LENGTH CONCAT CONCAT_WS REPLACE REVERSE LEFT RIGHT REPEAT LPAD RPAD ASCII
CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP LOCALTIME LOCALTIMESTAMP NOW
ROW_NUMBER RANK DENSE_RANK PERCENT_RANK CUME_DIST NTILE LAG LEAD FIRST_VALUE LAST_VALUE NTH_VALUE BIT_AND BIT_OR STDDEV STDDEV_POP STDDEV_SAMP VARIANCE VAR_POP VAR_SAMP
VERSION CURRENT_USER SESSION_USER MD5 REGEXP_REPLACE REGEXP_LIKE REGEXP_SUBSTR REGEXP_INSTR
`)

func readFunction(engine, name string) bool {
	return commonReadFunctions[name] || engine == "postgres" && postgresReadFunctions[name] || engine == "mysql" && mysqlReadFunctions[name]
}
