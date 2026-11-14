package tableedit

import (
	"strings"
	"unicode/utf8"
)

// Index definitions retain term order and distinguish omitted server defaults.
type IndexDefinition struct {
	Method        string        `json:"method"`
	Terms         []IndexTerm   `json:"terms"`
	Includes      []string      `json:"includes,omitempty"`
	Predicate     *string       `json:"predicate,omitempty"`
	NullsDistinct *bool         `json:"nullsDistinct,omitempty"`
	Visible       *bool         `json:"visible,omitempty"`
	Options       []IndexOption `json:"options,omitempty"`
}
type IndexTerm struct {
	Column       *string        `json:"column,omitempty"`
	Expression   *string        `json:"expression,omitempty"`
	Descending   *bool          `json:"descending,omitempty"`
	NullsFirst   *bool          `json:"nullsFirst,omitempty"`
	PrefixLength *int64         `json:"prefixLength,omitempty"`
	Collation    *TypeReference `json:"collation,omitempty"`
	Opclass      *TypeReference `json:"opclass,omitempty"`
	Options      []IndexOption  `json:"options,omitempty"`
}
type IndexOption struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

func indexOptionsValid(options []IndexOption) bool {
	if len(options) > 32 {
		return false
	}
	seen := map[string]bool{}
	for _, option := range options {
		if !Identifier(option.Name) || len(option.Value) > 1024 || !utf8.ValidString(option.Value) || strings.ContainsRune(option.Value, 0) || seen[option.Name] {
			return false
		}
		seen[option.Name] = true
	}
	return true
}
func (x IndexDefinition) Valid() bool {
	if !Identifier(x.Method) || len(x.Terms) < 1 || len(x.Terms) > 32 || len(x.Includes) > 32 || !indexOptionsValid(x.Options) || x.Predicate != nil && !authoredText(*x.Predicate) {
		return false
	}
	if len(x.Includes) > 0 && !columnsValid(x.Includes) {
		return false
	}
	for _, term := range x.Terms {
		if (term.Column == nil) == (term.Expression == nil) || term.Column != nil && !Identifier(*term.Column) || term.Expression != nil && !authoredText(*term.Expression) || term.PrefixLength != nil && (*term.PrefixLength < 1 || *term.PrefixLength > 65535) || term.Collation != nil && !term.Collation.Valid() || term.Opclass != nil && !term.Opclass.Valid() || !indexOptionsValid(term.Options) {
			return false
		}
	}
	return true
}
func (d Draft) NeedsAuthoringV3() bool {
	for _, x := range d.Indexes {
		if x.Definition != nil {
			return true
		}
	}
	return false
}

// Catalog expression lists are split at syntactic boundaries only. Each result
// must still pass the same non-executing slot admission used for authored SQL.
func SplitExpressionList(engine, raw string) ([]string, bool) {
	if len(raw) > 32*4096 {
		return nil, false
	}
	var out []string
	start, depth, brackets := 0, 0, 0
	for i := 0; i < len(raw); i++ {
		c := raw[i]
		if c == '\'' || c == '"' || c == '`' {
			quote := c
			closed := false
			for i++; i < len(raw); i++ {
				if raw[i] == quote {
					if i+1 < len(raw) && raw[i+1] == quote {
						i++
						continue
					}
					closed = true
					break
				}
			}
			if !closed {
				return nil, false
			}
			continue
		}
		if c == '$' && engine == "postgresql" && (i == 0 || !expressionIdentifierByte(raw[i-1])) {
			j := i + 1
			for j < len(raw) && (raw[j] >= 'a' && raw[j] <= 'z' || raw[j] >= 'A' && raw[j] <= 'Z' || raw[j] == '_' || j > i+1 && raw[j] >= '0' && raw[j] <= '9') {
				j++
			}
			if j < len(raw) && raw[j] == '$' {
				delimiter := raw[i : j+1]
				end := strings.Index(raw[j+1:], delimiter)
				if end < 0 {
					return nil, false
				}
				i = j + end + len(delimiter)
				continue
			}
		}
		switch c {
		case '(':
			depth++
		case ')':
			depth--
		case '[':
			brackets++
		case ']':
			brackets--
		case ',':
			if depth == 0 && brackets == 0 {
				out = append(out, strings.TrimSpace(raw[start:i]))
				start = i + 1
			}
		}
		if depth < 0 || brackets < 0 || len(out) > 31 {
			return nil, false
		}
	}
	if depth != 0 || brackets != 0 {
		return nil, false
	}
	out = append(out, strings.TrimSpace(raw[start:]))
	for _, part := range out {
		if _, err := ExpressionSlot(engine, part); err != nil {
			return nil, false
		}
	}
	return out, true
}

// Rich editing never makes an expression/prefix/partial index eligible as a
// supporting key. Keep the existing conservative support contract explicit.
func SupportingIndex(x Index, columns []string) bool {
	if !x.Supported {
		return false
	}
	if x.Definition == nil {
		return prefix(x.Columns, columns)
	}
	d := x.Definition
	if !strings.EqualFold(d.Method, "btree") || d.Predicate != nil || d.Visible != nil && !*d.Visible || len(d.Terms) < len(columns) {
		return false
	}
	for i, name := range columns {
		t := d.Terms[i]
		if t.Column == nil || *t.Column != name || t.Expression != nil || t.PrefixLength != nil || t.Descending != nil && *t.Descending {
			return false
		}
	}
	return true
}
func IndexEditSupports(x IndexEdit, columns []string) bool {
	return x.Action != "drop" && SupportingIndex(Index{Definition: x.Definition, Columns: x.Columns, Supported: true}, columns)
}

// Catalog guards are private, newly captured Preview evidence, never portable intent.
type IndexGuard struct {
	Kind       string
	Reference  TypeReference
	Method     string
	Identity   string
	Definition string
}
