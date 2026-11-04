package sqlite

import (
	"errors"
	"sort"
	"strings"

	"dbeer/helper/internal/tableedit"
)

// ddlToken spans original bytes. Parenthesized expressions are opaque tokens;
// keywords inside quoted text, comments and expressions never become clauses.
type ddlToken struct {
	start, end int
	word       string
	quoted     bool
	group      bool
}
type ddlTerm struct {
	raw, name string
	tokens    []ddlToken
}
type ddlTable struct {
	terms                          []ddlTerm
	suffix                         string
	strict, without, autoincrement bool
}

func ddlFold(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'a' && c <= 'z' {
			b[i] = c - 32
		}
	}
	return string(b)
}
func ddlSpace(c byte) bool { return c == ' ' || c == '\n' || c == '\r' || c == '\t' || c == '\f' }
func ddlScan(s string) ([]ddlToken, error) {
	out := []ddlToken{}
	for i := 0; i < len(s); {
		if ddlSpace(s[i]) {
			i++
			continue
		}
		if strings.HasPrefix(s[i:], "--") {
			for i < len(s) && s[i] != '\n' {
				i++
			}
			continue
		}
		if strings.HasPrefix(s[i:], "/*") {
			n := strings.Index(s[i+2:], "*/")
			if n < 0 {
				return nil, tableedit.ErrUnsupported
			}
			i += n + 4
			continue
		}
		t := ddlToken{start: i}
		c := s[i]
		if c == '\'' || c == '"' || c == '`' || c == '[' {
			end := c
			if c == '[' {
				end = ']'
			}
			i++
			closed := false
			for i < len(s) {
				if s[i] == end {
					if end != ']' && i+1 < len(s) && s[i+1] == end {
						i += 2
						continue
					}
					i++
					closed = true
					break
				}
				i++
			}
			if !closed {
				return nil, tableedit.ErrUnsupported
			}
			t.quoted = true
		} else if c == '(' {
			depth := 1
			i++
			for i < len(s) && depth > 0 {
				if s[i] == '\'' || s[i] == '"' || s[i] == '`' || s[i] == '[' {
					q := s[i]
					end := q
					if q == '[' {
						end = ']'
					}
					i++
					closed := false
					for i < len(s) {
						if s[i] == end {
							if end != ']' && i+1 < len(s) && s[i+1] == end {
								i += 2
								continue
							}
							i++
							closed = true
							break
						}
						i++
					}
					if !closed {
						return nil, tableedit.ErrUnsupported
					}
					continue
				}
				if strings.HasPrefix(s[i:], "--") {
					for i < len(s) && s[i] != '\n' {
						i++
					}
					continue
				}
				if strings.HasPrefix(s[i:], "/*") {
					n := strings.Index(s[i+2:], "*/")
					if n < 0 {
						return nil, tableedit.ErrUnsupported
					}
					i += n + 4
					continue
				}
				if s[i] == '(' {
					depth++
					if depth > 128 {
						return nil, tableedit.ErrUnsupported
					}
				}
				if s[i] == ')' {
					depth--
				}
				i++
			}
			if depth != 0 {
				return nil, tableedit.ErrUnsupported
			}
			t.group = true
		} else if strings.ContainsRune(",.;+-", rune(c)) {
			i++
		} else {
			for i < len(s) && !ddlSpace(s[i]) && !strings.ContainsRune("()[],.;+'\"`", rune(s[i])) && !strings.HasPrefix(s[i:], "--") && !strings.HasPrefix(s[i:], "/*") {
				i++
			}
			if i == t.start {
				return nil, tableedit.ErrUnsupported
			}
			t.word = ddlFold(s[t.start:i])
		}
		t.end = i
		out = append(out, t)
	}
	return out, nil
}
func ddlName(raw string, t ddlToken) (string, bool) {
	if t.group {
		return "", false
	}
	x := raw[t.start:t.end]
	if t.quoted {
		end := x[len(x)-1]
		x = x[1 : len(x)-1]
		if end != ']' {
			x = strings.ReplaceAll(x, string([]byte{end, end}), string(end))
		}
		return x, true
	}
	return x, t.word != ""
}
func parseDDLTable(raw string) (ddlTable, error) {
	var out ddlTable
	ts, e := ddlScan(raw)
	if e != nil {
		return out, e
	}
	if len(ts) < 4 || ts[0].word != "CREATE" || ts[1].word != "TABLE" {
		return out, tableedit.ErrUnsupported
	}
	body := -1
	for i, t := range ts {
		if t.group {
			body = i
			break
		}
	}
	if body < 0 {
		return out, tableedit.ErrUnsupported
	}
	g := ts[body]
	inside := raw[g.start+1 : g.end-1]
	parts, e := ddlScan(inside)
	if e != nil {
		return out, e
	}
	start := 0
	add := func(end int) error {
		piece := inside[start:end]
		tokens, err := ddlScan(piece)
		if err != nil || len(tokens) == 0 {
			return tableedit.ErrUnsupported
		}
		term := ddlTerm{raw: piece, tokens: tokens}
		switch tokens[0].word {
		case "PRIMARY", "UNIQUE", "CHECK", "FOREIGN", "CONSTRAINT":
		default:
			var ok bool
			term.name, ok = ddlName(piece, tokens[0])
			if !ok {
				return tableedit.ErrUnsupported
			}
		}
		for _, t := range tokens {
			if t.word == "AUTOINCREMENT" {
				out.autoincrement = true
			}
		}
		out.terms = append(out.terms, term)
		return nil
	}
	for _, t := range parts {
		if inside[t.start:t.end] == "," && !t.group && !t.quoted {
			if e = add(t.start); e != nil {
				return out, e
			}
			start = t.end
		}
	}
	if e = add(len(inside)); e != nil {
		return out, e
	}
	suffix := ts[body+1:]
	words := []string{}
	for i, t := range suffix {
		text := raw[t.start:t.end]
		if text == ";" {
			if i != len(suffix)-1 {
				return out, tableedit.ErrUnsupported
			}
			continue
		}
		if text == "," {
			continue
		}
		if t.quoted || t.group {
			return out, tableedit.ErrUnsupported
		}
		words = append(words, t.word)
	}
	for i := 0; i < len(words); i++ {
		switch words[i] {
		case "STRICT":
			if out.strict {
				return out, tableedit.ErrUnsupported
			}
			out.strict = true
		case "WITHOUT":
			if out.without || i+1 >= len(words) || words[i+1] != "ROWID" {
				return out, tableedit.ErrUnsupported
			}
			out.without = true
			i++
		default:
			return out, tableedit.ErrUnsupported
		}
	}
	out.suffix = strings.TrimSuffix(strings.TrimSpace(raw[g.end:]), ";")
	return out, nil
}

type ddlEdit struct {
	start, end int
	text       string
}

func ddlConstraint(w string) bool {
	switch w {
	case "CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT", "COLLATE", "REFERENCES", "GENERATED", "AS":
		return true
	}
	return false
}
func patchDDLColumn(term ddlTerm, c tableedit.ObservedColumn, change tableedit.ColumnChange) (string, error) {
	if !c.CanModify {
		return "", tableedit.ErrUnsupported
	}
	ts := term.tokens
	// Referencing/generated columns retain their declaration only when untouched.
	for _, t := range ts[1:] {
		if t.word == "REFERENCES" || t.word == "GENERATED" || t.word == "AS" {
			return "", tableedit.ErrUnsupported
		}
	}
	first := len(ts)
	for i := 1; i < len(ts); i++ {
		if ddlConstraint(ts[i].word) {
			first = i
			break
		}
	}
	edits := []ddlEdit{}
	if change.Type != nil {
		typ := map[string]string{"integer": "INTEGER", "real": "REAL", "text": "TEXT", "blob": "BLOB", "any": "ANY", "sqliteNumeric": "NUMERIC", "bigint": "INTEGER", "boolean": "INTEGER"}[change.Type.Kind]
		if typ == "" || !change.Type.Valid() {
			return "", tableedit.ErrInvalid
		}
		if first == 1 {
			edits = append(edits, ddlEdit{ts[0].end, ts[0].end, " " + typ})
		} else {
			edits = append(edits, ddlEdit{ts[1].start, ts[first-1].end, typ})
		}
	}
	defaultStart, defaultEnd := -1, -1
	nullStart, nullEnd := -1, -1
	defaultPrefix, nullPrefix := "", ""
	for i := first; i < len(ts); {
		start := i
		if ts[i].word == "CONSTRAINT" {
			if i+2 >= len(ts) {
				return "", tableedit.ErrUnsupported
			}
			i += 2
		}
		end := i + 1
		switch ts[i].word {
		case "PRIMARY":
			if i+1 >= len(ts) || ts[i+1].word != "KEY" {
				return "", tableedit.ErrUnsupported
			}
			end = i + 2
			if end < len(ts) && (ts[end].word == "ASC" || ts[end].word == "DESC") {
				end++
			}
			if end+2 < len(ts) && ts[end].word == "ON" && ts[end+1].word == "CONFLICT" {
				end += 3
			}
			if end < len(ts) && ts[end].word == "AUTOINCREMENT" {
				end++
			}
		case "UNIQUE":
			if end+2 < len(ts) && ts[end].word == "ON" && ts[end+1].word == "CONFLICT" {
				end += 3
			}
		case "NOT":
			if end >= len(ts) || ts[end].word != "NULL" {
				return "", tableedit.ErrUnsupported
			}
			end++
			if end+2 < len(ts) && ts[end].word == "ON" && ts[end+1].word == "CONFLICT" {
				end += 3
			}
			if nullStart >= 0 {
				return "", tableedit.ErrUnsupported
			}
			nullStart, nullEnd = ts[start].start, ts[end-1].end
			nullPrefix = term.raw[ts[start].start:ts[i].start]
		case "NULL":
			if end+2 < len(ts) && ts[end].word == "ON" && ts[end+1].word == "CONFLICT" {
				end += 3
			}
			if nullStart >= 0 {
				return "", tableedit.ErrUnsupported
			}
			nullStart, nullEnd = ts[start].start, ts[end-1].end
			nullPrefix = term.raw[ts[start].start:ts[i].start]
		case "COLLATE":
			if end >= len(ts) {
				return "", tableedit.ErrUnsupported
			}
			end++
		case "CHECK":
			if end >= len(ts) || !ts[end].group {
				return "", tableedit.ErrUnsupported
			}
			end++
		case "DEFAULT":
			if end >= len(ts) {
				return "", tableedit.ErrUnsupported
			}
			end++
			for end < len(ts) && !ddlConstraint(ts[end].word) {
				end++
			}
			if defaultStart >= 0 {
				return "", tableedit.ErrUnsupported
			}
			defaultStart, defaultEnd = ts[start].start, ts[end-1].end
			defaultPrefix = term.raw[ts[start].start:ts[i].start]
		default:
			return "", tableedit.ErrUnsupported
		}
		i = end
	}
	additions := []string{}
	if change.Default != nil {
		v, e := structureColumn(tableedit.Column{Name: "value", Type: tableedit.DataType{Kind: "text"}, Nullable: true, Default: *change.Default})
		if e != nil {
			return "", e
		}
		replacement := strings.TrimSpace(strings.TrimPrefix(v, `"value" TEXT`))
		if defaultStart >= 0 {
			if replacement != "" {
				replacement = defaultPrefix + replacement
			}
			edits = append(edits, ddlEdit{defaultStart, defaultEnd, replacement})
		} else if replacement != "" {
			additions = append(additions, replacement)
		}
	}
	if change.Nullable != nil && *change.Nullable != c.Nullable {
		replacement := ""
		if !*change.Nullable {
			replacement = "NOT NULL"
		}
		if nullStart >= 0 {
			if replacement != "" {
				replacement = nullPrefix + replacement
			}
			edits = append(edits, ddlEdit{nullStart, nullEnd, replacement})
		} else if replacement != "" {
			additions = append(additions, replacement)
		}
	}
	sort.Slice(edits, func(i, j int) bool { return edits[i].start > edits[j].start })
	out := term.raw
	last := len(out)
	for _, e := range edits {
		if e.end > last {
			return "", errors.New("Overlapping SQLite column edits.")
		}
		out = out[:e.start] + e.text + out[e.end:]
		last = e.start
	}
	if len(additions) > 0 {
		out += "\n " + strings.Join(additions, " ") + "\n"
	}
	return out, nil
}
