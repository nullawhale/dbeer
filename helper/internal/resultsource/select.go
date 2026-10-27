// Package resultsource recognizes a deliberately small SELECT surface. Its
// result is syntax evidence only: adapters must independently verify every
// origin against server metadata before exposing a source row or edit.
package resultsource

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

const Unsupported = "Only a direct SELECT from one base table can identify an editable source row. JOIN, CTE, DISTINCT, aggregates, computed columns and combined results are read only."
const maxSQLBytes = 1024 * 1024
const maxTokens = 65536

// Selection describes decoded identifiers, never display-column guesses.
// FromOffset is the byte position of FROM in the original statement.
type Selection struct {
	Schema     string
	Table      string
	Alias      string
	Columns    []Projection
	FromOffset int
	TableEnd   int
}

type Projection struct {
	Qualifier string
	Name      string
	Alias     string
	Star      bool
}

type token struct {
	text       string
	kind       byte
	start, end int
}

func (t token) keyword(value string) bool { return t.kind == 'i' && strings.EqualFold(t.text, value) }
func (t token) identifier() bool          { return t.kind == 'i' || t.kind == 'q' }

// Parse accepts direct identifiers (optionally aliased), one table, and bounded
// ordinary WHERE/ORDER BY/LIMIT/OFFSET clauses. Mode-sensitive quoting and all
// executable comments are refused rather than interpreted optimistically.
func Parse(sql, engine string) (Selection, string) {
	fail := func() (Selection, string) { return Selection{}, Unsupported }
	if engine != "postgresql" && engine != "mysql" || len(sql) > maxSQLBytes || !utf8.ValidString(sql) {
		return fail()
	}
	tokens, ok := lex(sql, engine)
	if !ok || len(tokens) < 4 || !tokens[0].keyword("SELECT") {
		return fail()
	}
	if tokens[len(tokens)-1].text == ";" {
		tokens = tokens[:len(tokens)-1]
	}
	for _, t := range tokens {
		if t.text == ";" {
			return fail()
		}
	}
	from := -1
	for i := 1; i < len(tokens); i++ {
		if tokens[i].keyword("FROM") {
			from = i
			break
		}
	}
	if from < 2 {
		return fail()
	}
	selection := Selection{FromOffset: tokens[from].start}
	for p := 1; p < from; {
		var column Projection
		if tokens[p].text == "*" {
			column.Star = true
			p++
		} else {
			if !tokens[p].identifier() || forbidden(tokens[p]) {
				return fail()
			}
			column.Name = tokens[p].text
			p++
			if p < from && tokens[p].text == "." {
				column.Qualifier = column.Name
				p++
				if p >= from {
					return fail()
				}
				if tokens[p].text == "*" {
					column.Name = ""
					column.Star = true
				} else if tokens[p].identifier() && !forbidden(tokens[p]) {
					column.Name = tokens[p].text
				} else {
					return fail()
				}
				p++
			}
		}
		if !column.Star && p < from && tokens[p].keyword("AS") {
			p++
			if p >= from || !tokens[p].identifier() || forbidden(tokens[p]) {
				return fail()
			}
			column.Alias = tokens[p].text
			p++
		} else if !column.Star && p < from && tokens[p].identifier() && !forbidden(tokens[p]) {
			column.Alias = tokens[p].text
			p++
		}
		selection.Columns = append(selection.Columns, column)
		if len(selection.Columns) > 4096 {
			return fail()
		}
		if p == from {
			break
		}
		if tokens[p].text != "," {
			return fail()
		}
		p++
		if p == from {
			return fail()
		}
	}
	p := from + 1
	if p >= len(tokens) || !tokens[p].identifier() || forbidden(tokens[p]) {
		return fail()
	}
	selection.Table = tokens[p].text
	selection.TableEnd = tokens[p].end
	p++
	if p < len(tokens) && tokens[p].text == "." {
		selection.Schema = selection.Table
		p++
		if p >= len(tokens) || !tokens[p].identifier() || forbidden(tokens[p]) {
			return fail()
		}
		selection.Table = tokens[p].text
		selection.TableEnd = tokens[p].end
		p++
	}
	if p < len(tokens) && tokens[p].keyword("AS") {
		p++
		if p >= len(tokens) || !tokens[p].identifier() || forbidden(tokens[p]) {
			return fail()
		}
		selection.Alias = tokens[p].text
		selection.TableEnd = tokens[p].end
		p++
	} else if p < len(tokens) && tokens[p].identifier() && !clause(tokens[p]) && !forbidden(tokens[p]) {
		selection.Alias = tokens[p].text
		selection.TableEnd = tokens[p].end
		p++
	}
	for _, col := range selection.Columns {
		qualifier := selection.Table
		if selection.Alias != "" {
			qualifier = selection.Alias
		}
		if col.Qualifier != "" && col.Qualifier != qualifier {
			return fail()
		}
	}
	lastClause := 0
	for p < len(tokens) {
		rank := 0
		switch {
		case tokens[p].keyword("WHERE"):
			rank = 1
			p++
		case tokens[p].keyword("ORDER"):
			rank = 2
			p++
			if p >= len(tokens) || !tokens[p].keyword("BY") {
				return fail()
			}
			p++
		case tokens[p].keyword("LIMIT"):
			rank = 3
			p++
		case tokens[p].keyword("OFFSET"):
			rank = 4
			p++
		default:
			return fail()
		}
		if rank <= lastClause {
			return fail()
		}
		lastClause = rank
		start := p
		depth := 0
		for p < len(tokens) && !(depth == 0 && clause(tokens[p])) {
			t := tokens[p]
			if forbidden(t) {
				return fail()
			}
			if t.text == "(" {
				// Function calls, including quoted/user functions, can change rows while
				// SELECT is running. Parenthesized predicates remain supported.
				if p > start && tokens[p-1].identifier() && !tokens[p-1].keyword("IN") && !tokens[p-1].keyword("AND") && !tokens[p-1].keyword("OR") && !tokens[p-1].keyword("NOT") {
					return fail()
				}
				depth++
				if depth > 64 {
					return fail()
				}
			}
			if t.text == ")" {
				depth--
				if depth < 0 {
					return fail()
				}
			}
			p++
		}
		if start == p || depth != 0 {
			return fail()
		}
	}
	return selection, ""
}

func clause(t token) bool {
	return t.keyword("WHERE") || t.keyword("ORDER") || t.keyword("LIMIT") || t.keyword("OFFSET")
}
func forbidden(t token) bool {
	if t.kind != 'i' {
		return false
	}
	switch strings.ToUpper(t.text) {
	case "SELECT", "FROM", "WITH", "RECURSIVE", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "OUTER", "UNION", "INTERSECT", "EXCEPT", "DISTINCT", "DISTINCTROW", "ALL", "GROUP", "HAVING", "WINDOW", "OVER", "INTO", "OUTFILE", "DUMPFILE", "FOR", "LOCK", "UPDATE", "DELETE", "INSERT", "RETURNING", "TABLESAMPLE", "ONLY", "LATERAL", "FETCH", "PROCEDURE", "SQL_CALC_FOUND_ROWS", "SQL_BUFFER_RESULT", "SQL_CACHE", "SQL_NO_CACHE", "STRAIGHT_JOIN", "HIGH_PRIORITY":
		return true
	}
	return false
}

func lex(sql, engine string) ([]token, bool) {
	var tokens []token
	for i := 0; i < len(sql); {
		r, n := utf8.DecodeRuneInString(sql[i:])
		if unicode.IsSpace(r) {
			i += n
			continue
		}
		if strings.HasPrefix(sql[i:], "--") {
			// MySQL starts -- comments only before whitespace; refusing the ambiguous
			// variant avoids interpreting subtraction differently from the server.
			if engine == "mysql" && i+2 < len(sql) && sql[i+2] > ' ' {
				return nil, false
			}
			for i < len(sql) && sql[i] != '\n' {
				i++
			}
			continue
		}
		if engine == "mysql" && sql[i] == '#' {
			for i < len(sql) && sql[i] != '\n' {
				i++
			}
			continue
		}
		if strings.HasPrefix(sql[i:], "/*") {
			if i+2 < len(sql) && (sql[i+2] == '!' || sql[i+2] == '+') {
				return nil, false
			}
			i += 2
			depth := 1
			for i < len(sql) && depth > 0 {
				if strings.HasPrefix(sql[i:], "/*") {
					if engine == "mysql" {
						return nil, false
					}
					depth++
					if depth > 64 {
						return nil, false
					}
					i += 2
				} else if strings.HasPrefix(sql[i:], "*/") {
					depth--
					i += 2
				} else {
					i++
				}
			}
			if depth != 0 {
				return nil, false
			}
			continue
		}
		start := i
		if sql[i] == '\'' || sql[i] == '"' || sql[i] == '`' {
			quote := sql[i]
			if quote == '`' && engine != "mysql" || quote == '"' && engine == "mysql" {
				return nil, false
			}
			i++
			var value strings.Builder
			closed := false
			for i < len(sql) {
				if sql[i] == '\\' || sql[i] == 0 {
					return nil, false
				}
				if sql[i] == quote {
					if i+1 < len(sql) && sql[i+1] == quote {
						value.WriteByte(quote)
						i += 2
						continue
					}
					i++
					closed = true
					break
				}
				value.WriteByte(sql[i])
				i++
			}
			if !closed {
				return nil, false
			}
			kind := byte('q')
			if quote == '\'' {
				kind = 's'
			}
			if kind == 'q' && value.Len() == 0 {
				return nil, false
			}
			tokens = append(tokens, token{value.String(), kind, start, i})
		} else if unicode.IsLetter(r) || r == '_' {
			i += n
			for i < len(sql) {
				next, size := utf8.DecodeRuneInString(sql[i:])
				if !unicode.IsLetter(next) && !unicode.IsDigit(next) && next != '_' && next != '$' {
					break
				}
				i += size
			}
			value := sql[start:i]
			if engine == "postgresql" {
				var b strings.Builder
				for _, ch := range value {
					if ch >= 'A' && ch <= 'Z' {
						ch += 'a' - 'A'
					}
					b.WriteRune(ch)
				}
				value = b.String()
			}
			tokens = append(tokens, token{value, 'i', start, i})
		} else {
			if sql[i] == 0 || sql[i] == '\\' || sql[i] == '$' {
				return nil, false
			}
			i++
			tokens = append(tokens, token{sql[start:i], 'p', start, i})
		}
		if len(tokens) > maxTokens {
			return nil, false
		}
	}
	return tokens, true
}
