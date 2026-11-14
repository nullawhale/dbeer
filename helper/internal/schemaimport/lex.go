package schemaimport

import (
	"context"
	"strings"
	"unicode"
	"unicode/utf8"
)

type token struct {
	value, raw string
	kind       byte
	start, end int
}

func (t token) is(s string) bool { return t.kind == 'w' && asciiUpper(t.value) == s }
func asciiUpper(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'a' && c <= 'z' {
			b[i] = c - 32
		}
	}
	return string(b)
}
func asciiLower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}
func (t token) identifier(engine string) (string, bool) {
	if t.kind == 'q' {
		return t.value, true
	}
	if t.kind != 'w' {
		return "", false
	}
	if engine == "postgresql" {
		return asciiLower(t.value), true
	}
	return t.value, true
}
func nameRune(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' || r == '$' }

func lex(ctx context.Context, sql, engine string, noBackslash bool) ([]token, error) {
	if len(sql) > 128<<10 || !utf8.ValidString(sql) || strings.ContainsRune(sql, 0) {
		return nil, ErrLimit
	}
	out := []token{}
	for i := 0; i < len(sql); {
		if len(out) > 100000 {
			return nil, ErrLimit
		}
		if len(out)%1024 == 0 {
			if e := ctx.Err(); e != nil {
				return nil, e
			}
		}
		r, n := utf8.DecodeRuneInString(sql[i:])
		if unicode.IsSpace(r) {
			i += n
			continue
		}
		if strings.HasPrefix(sql[i:], "--") && ((engine != "mysql" && engine != "mariadb") || i+2 == len(sql) || sql[i+2] <= ' ') || (engine == "mysql" || engine == "mariadb") && sql[i] == '#' {
			for i < len(sql) && sql[i] != '\n' {
				i++
			}
			continue
		}
		if strings.HasPrefix(sql[i:], "/*") {
			// MySQL executable comments may carry statements and cannot be
			// treated as harmless whitespace by a portable source importer.
			if (engine == "mysql" || engine == "mariadb") && i+2 < len(sql) && (sql[i+2] == '!' || sql[i+2] == '+' || engine == "mariadb" && i+3 < len(sql) && sql[i+2] == 'M' && sql[i+3] == '!') {
				return nil, ErrUnsupported
			}
			i += 2
			depth := 1
			for i < len(sql) && depth > 0 {
				if strings.HasPrefix(sql[i:], "/*") && engine == "postgresql" {
					depth++
					i += 2
					if depth > 32 {
						return nil, ErrLimit
					}
				} else if strings.HasPrefix(sql[i:], "*/") {
					depth--
					i += 2
				} else {
					i++
				}
			}
			if depth != 0 {
				return nil, ErrInvalid
			}
			continue
		}
		start := i
		kind := byte('p')
		value := ""
		escape := false
		if engine == "postgresql" && (sql[i] == 'E' || sql[i] == 'e') && i+1 < len(sql) && sql[i+1] == '\'' {
			escape = true
			i++
		}
		if sql[i] == '\'' || sql[i] == '"' || ((engine == "mysql" || engine == "mariadb") || engine == "sqlite") && sql[i] == '`' || engine == "sqlite" && sql[i] == '[' {
			q := sql[i]
			end := q
			if q == '[' {
				end = ']'
			}
			kind = 's'
			if q != '\'' {
				kind = 'q'
			}
			i++
			var b strings.Builder
			closed := false
			for i < len(sql) {
				c := sql[i]
				if c == end {
					if i+1 < len(sql) && sql[i+1] == end && end != ']' {
						b.WriteByte(end)
						i += 2
						continue
					}
					i++
					closed = true
					break
				}
				if c == '\\' && kind == 's' && (escape || (engine == "mysql" || engine == "mariadb") && !noBackslash) {
					i++
					if i == len(sql) {
						return nil, ErrInvalid
					}
					switch sql[i] {
					case 'n':
						c = '\n'
					case 'r':
						c = '\r'
					case 't':
						c = '\t'
					case '0':
						return nil, ErrUnsupported
					case '\\', '\'', '"':
						c = sql[i]
					default:
						return nil, ErrUnsupported
					}
				}
				b.WriteByte(c)
				i++
			}
			if !closed {
				return nil, ErrInvalid
			}
			value = b.String()
		} else if escape {
			return nil, ErrInvalid
		} else if sql[i] == '$' && engine == "postgresql" {
			end := i + 1
			for end < len(sql) && (sql[end] == '_' || sql[end] >= 'a' && sql[end] <= 'z' || sql[end] >= 'A' && sql[end] <= 'Z' || end > i+1 && sql[end] >= '0' && sql[end] <= '9') {
				end++
			}
			if end < len(sql) && sql[end] == '$' {
				delimiter := sql[i : end+1]
				close := strings.Index(sql[end+1:], delimiter)
				if close < 0 {
					return nil, ErrInvalid
				}
				kind = 's'
				value = sql[end+1 : end+1+close]
				i = end + 1 + close + len(delimiter)
			} else {
				return nil, ErrUnsupported
			}
		} else if unicode.IsLetter(r) || r == '_' {
			kind = 'w'
			i += n
			for i < len(sql) {
				r, n = utf8.DecodeRuneInString(sql[i:])
				if !nameRune(r) {
					break
				}
				i += n
			}
			value = sql[start:i]
		} else if sql[i] >= '0' && sql[i] <= '9' {
			kind = 'n'
			i++
			for i < len(sql) && (sql[i] >= '0' && sql[i] <= '9' || sql[i] == '.' || sql[i] == 'e' || sql[i] == 'E' || (sql[i] == '+' || sql[i] == '-') && (sql[i-1] == 'e' || sql[i-1] == 'E')) {
				i++
			}
			value = sql[start:i]
		} else {
			i++
			value = sql[start:i]
			if i < len(sql) {
				pair := sql[start : i+1]
				if pair == "::" || pair == "<=" || pair == ">=" || pair == "<>" || pair == "!=" || pair == "||" {
					i++
					value = pair
				}
			}
		}
		out = append(out, token{value: value, raw: sql[start:i], kind: kind, start: start, end: i})
	}
	return out, nil
}
func statements(ts []token) ([][]token, error) {
	var out [][]token
	start, depth, block := 0, 0, 0
	trigger := false
	for i, t := range ts {
		if i == start {
			trigger = false
		}
		if t.is("TRIGGER") && i-start < 5 {
			trigger = true
		}
		if t.kind == 'p' && t.value == "(" {
			depth++
			if depth > 128 {
				return nil, ErrLimit
			}
		}
		if t.kind == 'p' && t.value == ")" {
			depth--
			if depth < 0 {
				return nil, ErrInvalid
			}
		}
		if trigger && depth == 0 {
			if t.is("BEGIN") || t.is("CASE") {
				block++
			}
			if t.is("END") {
				block--
				if block < 0 {
					return nil, ErrInvalid
				}
			}
		}
		if t.kind == 'p' && t.value == ";" && depth == 0 && block == 0 {
			if i > start {
				out = append(out, ts[start:i])
			}
			start = i + 1
		}
	}
	if depth != 0 || block != 0 {
		return nil, ErrInvalid
	}
	if start < len(ts) {
		out = append(out, ts[start:])
	}
	if len(out) > 10000 {
		return nil, ErrLimit
	}
	return out, nil
}

type cursor struct {
	ts     []token
	i      int
	engine string
}

func (c *cursor) take(s string) bool {
	if c.i < len(c.ts) && (c.ts[c.i].is(s) || c.ts[c.i].kind == 'p' && c.ts[c.i].value == s) {
		c.i++
		return true
	}
	return false
}
func (c *cursor) ident() (string, error) {
	if c.i >= len(c.ts) {
		return "", ErrUnsupported
	}
	s, ok := c.ts[c.i].identifier(c.engine)
	if !ok || s == "" || len(s) > 256 {
		return "", ErrUnsupported
	}
	c.i++
	return s, nil
}
func (c *cursor) qualified(defaultSchema string) (string, string, error) {
	a, e := c.ident()
	if e != nil {
		return "", "", e
	}
	if c.take(".") {
		b, e := c.ident()
		if e != nil {
			return "", "", e
		}
		return a, b, nil
	}
	return defaultSchema, a, nil
}
func (c *cursor) group() ([]token, error) {
	if !c.take("(") {
		return nil, ErrUnsupported
	}
	start := c.i
	depth := 1
	for c.i < len(c.ts) {
		t := c.ts[c.i]
		c.i++
		if t.kind == 'p' && t.value == "(" {
			depth++
		}
		if t.kind == 'p' && t.value == ")" {
			depth--
			if depth == 0 {
				return c.ts[start : c.i-1], nil
			}
		}
	}
	return nil, ErrInvalid
}
func commaTerms(ts []token) ([][]token, error) {
	if len(ts) == 0 {
		return nil, ErrUnsupported
	}
	out := [][]token{}
	start, depth := 0, 0
	for i, t := range ts {
		if t.kind == 'p' && t.value == "(" {
			depth++
		}
		if t.kind == 'p' && t.value == ")" {
			depth--
			if depth < 0 {
				return nil, ErrInvalid
			}
		}
		if t.kind == 'p' && t.value == "," && depth == 0 {
			if i == start {
				return nil, ErrUnsupported
			}
			out = append(out, ts[start:i])
			start = i + 1
		}
	}
	if depth != 0 {
		return nil, ErrInvalid
	}
	if start == len(ts) {
		return nil, ErrUnsupported
	}
	out = append(out, ts[start:])
	return out, nil
}
func tokensSame(a, b []token) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].kind != b[i].kind {
			return false
		}
		if a[i].kind == 'w' {
			if asciiUpper(a[i].value) != asciiUpper(b[i].value) {
				return false
			}
		} else if a[i].value != b[i].value {
			return false
		}
	}
	return true
}
func tokenText(ts []token) string {
	var b strings.Builder
	for i, t := range ts {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(t.raw)
	}
	return b.String()
}
