package tableedit

import (
	"errors"
	"strconv"
	"strings"
	"unicode/utf8"

	sc "dbeer/helper/internal/schemacompare"
)

type TypeReference struct {
	Schema string `json:"schema"`
	Name   string `json:"name"`
}

func (r TypeReference) Valid() bool { return Identifier(r.Schema) && Identifier(r.Name) }

type Generation struct {
	Storage    string `json:"storage"`
	Expression string `json:"expression,omitempty"`
}

func (g Generation) Valid() bool {
	return g.Storage == "none" && g.Expression == "" || (g.Storage == "stored" || g.Storage == "virtual") && authoredText(g.Expression)
}

type Identity struct {
	Kind      string  `json:"kind"`
	Start     *string `json:"start,omitempty"`
	Increment *string `json:"increment,omitempty"`
	Minimum   *string `json:"minimum,omitempty"`
	Maximum   *string `json:"maximum,omitempty"`
	Cache     *string `json:"cache,omitempty"`
	Cycle     *bool   `json:"cycle,omitempty"`
}

func (x Identity) Valid() bool {
	if x.Kind != "none" && x.Kind != "always" && x.Kind != "byDefault" && x.Kind != "autoIncrement" {
		return false
	}
	options := []*string{x.Start, x.Increment, x.Minimum, x.Maximum, x.Cache}
	for _, p := range options {
		if p == nil {
			continue
		}
		n, e := strconv.ParseInt(*p, 10, 64)
		if e != nil || strconv.FormatInt(n, 10) != *p || x.Kind == "none" {
			return false
		}
	}
	if x.Kind == "none" {
		return x.Cycle == nil
	}
	if x.Increment != nil && *x.Increment == "0" {
		return false
	}
	if x.Cache != nil {
		n, _ := strconv.ParseInt(*x.Cache, 10, 64)
		if n < 1 {
			return false
		}
	}
	if x.Minimum != nil && x.Maximum != nil {
		a, _ := strconv.ParseInt(*x.Minimum, 10, 64)
		b, _ := strconv.ParseInt(*x.Maximum, 10, 64)
		if a >= b {
			return false
		}
	}
	if x.Kind == "autoIncrement" {
		return x.Start == nil && x.Increment == nil && x.Minimum == nil && x.Maximum == nil && x.Cache == nil && x.Cycle == nil
	}
	return true
}

// Type guards are private catalog evidence, never portable authorizations.
type TypeGuard struct {
	RawExpressions      map[string]string
	Reference           TypeReference
	Identity            string
	Use                 sc.TypeUse
	Definitions         []sc.TypeDefinition
	Storage             string
	Collation           sc.Fact[sc.Ref]
	CollationProperties *sc.Collection[sc.Option]
	InheritedDefault    *sc.Default
}

func authoredText(s string) bool {
	return s != "" && len(s) <= 4096 && utf8.ValidString(s) && !strings.ContainsRune(s, 0)
}
func columnAuthoredValid(c Column) bool {
	if c.Generated != nil && !c.Generated.Valid() || c.Identity != nil && !c.Identity.Valid() {
		return false
	}
	g := c.Generated != nil && c.Generated.Storage != "none"
	i := c.Identity != nil && c.Identity.Kind != "none"
	if g && (c.Default.Kind != "none" || i) || i && (c.Default.Kind != "none" || c.Nullable || c.Type.Kind != "integer" && c.Type.Kind != "bigint") {
		return false
	}
	return true
}
func changeAuthoredValid(c ColumnChange) bool {
	if c.Nullable != nil && !*c.Nullable && c.Default != nil && c.Default.Kind == "null" {
		return false
	}
	if c.RenameTo != nil && (!Identifier(*c.RenameTo) || *c.RenameTo == c.Name) || c.Generated != nil && !c.Generated.Valid() || c.Identity != nil && !c.Identity.Valid() {
		return false
	}
	if c.Generated != nil && c.Generated.Storage != "none" && (c.Default != nil || c.Identity != nil && c.Identity.Kind != "none") {
		return false
	}
	return !(c.Identity != nil && c.Identity.Kind != "none" && c.Default != nil && c.Default.Kind != "none")
}

func (d Draft) HasAuthoredExpressions() bool {
	for _, x := range d.Indexes {
		if x.Definition != nil {
			if x.Definition.Predicate != nil {
				return true
			}
			for _, term := range x.Definition.Terms {
				if term.Expression != nil {
					return true
				}
			}
		}
	}
	for _, c := range d.Columns {
		if c.Default.Kind == "expression" || c.Generated != nil && c.Generated.Storage != "none" {
			return true
		}
	}
	for _, c := range d.Changes {
		if c.UsingExpression != nil || c.Default != nil && c.Default.Kind == "expression" || c.Generated != nil && c.Generated.Storage != "none" {
			return true
		}
	}
	return false
}

func (d Draft) MayExecuteUserCode() bool {
	if d.NeedsAuthoringV3() {
		return true
	}
	if d.HasAuthoredExpressions() {
		return true
	}
	for _, c := range d.Columns {
		if c.Type.Reference != nil {
			return true
		}
	}
	return false
}

func (d Draft) RequiresEffectConfirmation() bool {
	if d.MayExecuteUserCode() {
		return true
	}
	for _, change := range d.Changes {
		if change.Identity != nil && change.Identity.Kind == "autoIncrement" {
			return true
		}
	}
	return false
}

func (d Draft) NeedsAuthoringV2() bool {
	if d.RenameTable != nil || d.HasAuthoredExpressions() {
		return true
	}
	for _, c := range d.Columns {
		if c.Type.Reference != nil || c.Generated != nil || c.Identity != nil {
			return true
		}
	}
	for _, c := range d.Changes {
		if c.RenameTo != nil || c.Generated != nil || c.Identity != nil || c.Type != nil && c.Type.Reference != nil {
			return true
		}
	}
	return false
}

// ExpressionSlot proves only one bounded expression slot, not SQL semantics.
// shortcut: comments and backslash escapes are unsupported; extend with dialect-aware escaping when needed.
func ExpressionSlot(engine, raw string) (string, error) {
	bad := func() (string, error) {
		return "", errors.New("The expression must occupy one balanced SQL expression slot; comments, parameters and backslash escapes are unsupported. Preview does not execute or semantically validate expressions.")
	}
	if !authoredText(raw) {
		return bad()
	}
	depth, brackets := 0, 0
	for i := 0; i < len(raw); {
		c := raw[i]
		if c == '\\' || c == ';' || c == '-' && i+1 < len(raw) && raw[i+1] == '-' || c == '/' && i+1 < len(raw) && raw[i+1] == '*' || c == '#' && engine == "mysql" {
			return bad()
		}
		if engine == "sqlite" && c == '[' {
			end := strings.IndexByte(raw[i+1:], ']')
			if end < 0 {
				return bad()
			}
			i += end + 2
			continue
		}
		if (engine == "mysql" || engine == "sqlite") && c == '?' || engine == "sqlite" && (c == ':' || c == '@' || c == '$') {
			return bad()
		}
		if c == '\'' || c == '"' || c == '`' {
			if c == '`' && engine == "postgresql" {
				return bad()
			}
			quote := c
			i++
			closed := false
			for i < len(raw) {
				if raw[i] == '\\' {
					return bad()
				}
				if raw[i] == quote {
					if i+1 < len(raw) && raw[i+1] == quote {
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
				return bad()
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
					return bad()
				}
				i = j + 1 + end + len(delimiter)
				continue
			}
			if i+1 < len(raw) && raw[i+1] >= '0' && raw[i+1] <= '9' {
				return bad()
			}
		}
		switch c {
		case '(':
			depth++
		case ')':
			depth--
			if depth < 0 {
				return bad()
			}
		case '[':
			brackets++
		case ']':
			brackets--
			if brackets < 0 {
				return bad()
			}
		case ',':
			if depth == 0 && brackets == 0 {
				return bad()
			}
		}
		i++
	}
	if depth != 0 || brackets != 0 {
		return bad()
	}
	return "(" + raw + ")", nil
}

func ResultTarget(original Target, d Draft) *Target {
	if d.RenameTable == nil {
		return nil
	}
	t := original
	t.Create = false
	t.Reconcile = false
	t.Table = *d.RenameTable
	return &t
}
func StepTarget(original Target, c Condition) Target {
	original.Create = false
	original.Reconcile = false
	if c.Operation.Kind == "renameTable" && c.Operation.Name != nil {
		original.Table = *c.Operation.Name
	}
	return original
}

func expressionIdentifierByte(c byte) bool {
	return c >= 128 || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '$'
}
