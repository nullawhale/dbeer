package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"strings"

	"github.com/jackc/pgx/v5"
)

// Fixed structure catalog reads retain the user's search_path while selecting
// core operators explicitly. This reader never receives editor SQL or DDL.
type pgStructureCatalogReader struct{ structureReader }

func pgCatalogReader(q structureReader) structureReader {
	if _, ok := q.(pgStructureCatalogReader); ok {
		return q
	}
	return pgStructureCatalogReader{q}
}
func (q pgStructureCatalogReader) Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
	guarded, ok := pgStructureCatalogSQL(sql)
	if !ok {
		return nil, tableedit.ErrUnsupported
	}
	return q.structureReader.Query(ctx, guarded, args...)
}
func (q pgStructureCatalogReader) QueryRow(ctx context.Context, sql string, args ...any) pgx.Row {
	guarded, ok := pgStructureCatalogSQL(sql)
	if !ok {
		return pgStructureCatalogError{}
	}
	return q.structureReader.QueryRow(ctx, guarded, args...)
}

type pgStructureCatalogError struct{}

func (pgStructureCatalogError) Scan(...any) error { return tableedit.ErrUnsupported }

type pgCatalogToken struct{ text, kind string }

func pgStructureCatalogSQL(sql string) (string, bool) {
	if len(sql) == 0 || len(sql) > 128<<10 {
		return "", false
	}
	tokens, ok := pgCatalogTokens(sql)
	if !ok || len(tokens) == 0 || (tokens[0].text != "SELECT" && tokens[0].text != "WITH") {
		return "", false
	}
	out, ok := pgCatalogOperators(tokens)
	return strings.Join(out, " "), ok
}
func pgCatalogTokens(sql string) ([]pgCatalogToken, bool) {
	out := []pgCatalogToken{}
	for i := 0; i < len(sql); {
		c := sql[i]
		if strings.ContainsRune(" \t\r\n", rune(c)) {
			i++
			continue
		}
		start := i
		kind := "punctuation"
		switch {
		case c == '\'' || c == '"':
			kind = "quoted"
			i++
			closed := false
			for i < len(sql) {
				if sql[i] == '\\' && c == '\'' {
					return nil, false
				}
				if sql[i] == c {
					i++
					if i < len(sql) && sql[i] == c {
						i++
						continue
					}
					closed = true
					break
				}
				i++
			}
			if !closed {
				return nil, false
			}
		case c == '$':
			kind = "parameter"
			i++
			for i < len(sql) && sql[i] >= '0' && sql[i] <= '9' {
				i++
			}
			if i == start+1 {
				return nil, false
			}
		case c >= '0' && c <= '9':
			kind = "number"
			i++
			for i < len(sql) && ((sql[i] >= '0' && sql[i] <= '9') || sql[i] == '.') {
				i++
			}
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_':
			kind = "word"
			i++
			for i < len(sql) && ((sql[i] >= 'a' && sql[i] <= 'z') || (sql[i] >= 'A' && sql[i] <= 'Z') || (sql[i] >= '0' && sql[i] <= '9') || sql[i] == '_') {
				i++
			}
		case strings.ContainsRune("+-*/<>=~!@#%^&|?", rune(c)):
			kind = "operator"
			if strings.HasPrefix(sql[i:], "--") || strings.HasPrefix(sql[i:], "/*") || strings.HasPrefix(sql[i:], "=>") {
				return nil, false
			}
			i++
			for _, op := range []string{"->>", "->", ">=", "<=", "<>", "!=", "||"} {
				if strings.HasPrefix(sql[start:], op) {
					i = start + len(op)
					break
				}
			}
		case c == ':':
			i++
			if i >= len(sql) || sql[i] != ':' {
				return nil, false
			}
			i++
		case strings.ContainsRune("().,[]", rune(c)):
			i++
		default:
			return nil, false
		}
		value := sql[start:i]
		if kind == "word" {
			value = strings.ToUpper(value)
		}
		out = append(out, pgCatalogToken{value, kind})
		if len(out) > 16384 {
			return nil, false
		}
	}
	return out, true
}
func pgCatalogOperators(tokens []pgCatalogToken) ([]string, bool) {
	out := []string{}
	for i := 0; i < len(tokens); i++ {
		t := tokens[i]
		switch t.text {
		case "LIKE", "ILIKE", "SIMILAR", "BETWEEN", "NULLIF", "GREATEST", "LEAST", "COLLATION", "OVERLAPS":
			return nil, false
		case "CASE":
			if i+1 == len(tokens) || tokens[i+1].text != "WHEN" {
				return nil, false
			}
		case "DISTINCT":
			if i+1 < len(tokens) && tokens[i+1].text == "FROM" {
				return nil, false
			}
		case "OPERATOR":
			if i+5 >= len(tokens) || tokens[i+1].text != "(" || tokens[i+2].text != "PG_CATALOG" || tokens[i+3].text != "." || tokens[i+4].kind != "operator" || tokens[i+5].text != ")" {
				return nil, false
			}
			value, ok := pgCatalogOperator(tokens[i+4].text)
			if !ok {
				return nil, false
			}
			out = append(out, value)
			i += 5
			continue
		case "NOT":
			if i+1 < len(tokens) && tokens[i+1].text == "IN" {
				i++
				t.text = "NOT IN"
			}
		}
		if t.text == "IN" || t.text == "NOT IN" {
			if i+1 == len(tokens) || tokens[i+1].text != "(" {
				return nil, false
			}
			depth, end := 1, i+2
			for ; end < len(tokens); end++ {
				if tokens[end].text == "(" {
					depth++
				}
				if tokens[end].text == ")" {
					depth--
					if depth == 0 {
						break
					}
				}
			}
			if depth != 0 || end == i+2 {
				return nil, false
			}
			inner, ok := pgCatalogOperators(tokens[i+2 : end])
			if !ok {
				return nil, false
			}
			op, quantifier := "=", "ANY"
			if t.text == "NOT IN" {
				op, quantifier = "<>", "ALL"
			}
			out = append(out, "OPERATOR(pg_catalog."+op+")", quantifier, "(")
			query := tokens[i+2].text == "SELECT" || tokens[i+2].text == "WITH"
			if !query {
				out = append(out, "ARRAY", "[")
			}
			out = append(out, inner...)
			if !query {
				out = append(out, "]")
			}
			out = append(out, ")")
			i = end
			continue
		}
		if t.kind == "operator" {
			if t.text == "*" && (i == 0 || tokens[i-1].text == "." || tokens[i-1].text == "SELECT" || tokens[i-1].text == "(" || tokens[i-1].text == ",") {
				out = append(out, t.text)
				continue
			}
			value, ok := pgCatalogOperator(t.text)
			if !ok {
				return nil, false
			}
			out = append(out, value)
		} else {
			out = append(out, t.text)
		}
	}
	return out, true
}
func pgCatalogOperator(value string) (string, bool) {
	if value == "!=" {
		value = "<>"
	}
	switch value {
	case "=", "<>", "<", ">", "<=", ">=", "+", "-", "*", "/", "%", "||", "->", "->>":
		return "OPERATOR(pg_catalog." + value + ")", true
	}
	return "", false
}
