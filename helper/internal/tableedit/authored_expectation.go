package tableedit

import (
	"encoding/json"
	"reflect"
	"strconv"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
)

func ExpectedColumnType(engine string, c Column) sc.TypeUse {
	if c.Type.Kind == "reference" && c.Type.Reference != nil && c.Resolved != nil && c.Resolved.Reference == *c.Type.Reference {
		return c.Resolved.Use
	}
	return ExpectedNewType(engine, c.Type)
}

func SameDataType(a, b DataType) bool { return reflect.DeepEqual(a, b) }

// Expression comparison is deliberately conservative; it never evaluates SQL.
func SameExpression(engine, a, b string) bool {
	return sameExpressionIdentifiers(engine, a, b, nil, false)
}
func sameExpressionIdentifiers(engine, a, b string, identifiers map[string]bool, ansiQuotes bool) bool {
	x, ok := expressionTokens(engine, a, identifiers, ansiQuotes)
	y, other := expressionTokens(engine, b, identifiers, ansiQuotes)
	return ok && other && reflect.DeepEqual(x, y)
}

func expressionTokens(engine, raw string, identifiers map[string]bool, ansiQuotes bool) ([]string, bool) {
	if _, e := ExpressionSlot(engine, raw); e != nil {
		return nil, false
	}
	tokens := []string{}
	for i := 0; i < len(raw); {
		c := raw[i]
		if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
			i++
			continue
		}
		if engine == "postgresql" && c == '$' && (i == 0 || !expressionIdentifierByte(raw[i-1])) {
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
				value, _ := json.Marshal(raw[j+1 : j+1+end])
				tokens = append(tokens, "string:"+string(value))
				i = j + 1 + end + len(delimiter)
				continue
			}
		}
		if c == '\'' || c == '"' || c == '`' {
			quote, value := c, strings.Builder{}
			i++
			for i < len(raw) {
				if raw[i] == quote {
					if i+1 < len(raw) && raw[i+1] == quote {
						value.WriteByte(quote)
						i += 2
						continue
					}
					i++
					break
				}
				value.WriteByte(raw[i])
				i++
			}
			kind := "string:"
			if quote == '`' || quote == '"' && (engine == "postgresql" || (engine == "mysql" || engine == "mariadb") && ansiQuotes) {
				kind = "identifier:"
			}
			v := value.String()
			if kind == "identifier:" && identifiers[v] && asciiIdentifier(v) && v == strings.ToLower(v) {
				tokens = append(tokens, "word:"+v)
			} else {
				encoded, _ := json.Marshal(v)
				tokens = append(tokens, kind+string(encoded))
			}
			continue
		}
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || c >= 128 {
			start := i
			i++
			for i < len(raw) && (raw[i] >= 'a' && raw[i] <= 'z' || raw[i] >= 'A' && raw[i] <= 'Z' || raw[i] >= '0' && raw[i] <= '9' || raw[i] == '_' || raw[i] == '$' || raw[i] >= 128) {
				i++
			}
			value := raw[start:i]
			if asciiIdentifier(value) {
				value = strings.ToLower(value)
			}
			tokens = append(tokens, "word:"+value)
			continue
		}
		if c >= '0' && c <= '9' {
			start := i
			for i < len(raw) && (raw[i] >= '0' && raw[i] <= '9' || raw[i] == '.') {
				i++
			}
			tokens = append(tokens, "number:"+raw[start:i])
			continue
		}
		if strings.ContainsRune("+-*/<>=~!@#%^&|", rune(c)) {
			start := i
			for i < len(raw) && strings.ContainsRune("+-*/<>=~!@#%^&|", rune(raw[i])) {
				i++
			}
			tokens = append(tokens, "operator:"+raw[start:i])
			continue
		}
		tokens = append(tokens, string(c))
		i++
	}
	for len(tokens) >= 2 && tokens[0] == "(" && tokens[len(tokens)-1] == ")" {
		depth, outer := 0, true
		for i, t := range tokens {
			if t == "(" {
				depth++
			}
			if t == ")" {
				depth--
			}
			if depth == 0 && i != len(tokens)-1 {
				outer = false
				break
			}
		}
		if !outer {
			break
		}
		tokens = tokens[1 : len(tokens)-1]
	}
	return tokens, len(tokens) > 0
}

func asciiIdentifier(s string) bool {
	for _, c := range []byte(s) {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '$') {
			return false
		}
	}
	return s != ""
}

func generatedMatches(engine string, facts *Facts, c sc.Column, want *Generation) bool {
	if c.Generated.Value == nil {
		return false
	}
	kind := "none"
	if want != nil {
		kind = want.Storage
	}
	return c.Generated.Value.Kind == kind && (kind == "none" || c.Generated.Value.Expression != nil && SameCatalogExpression(engine, c.Generated.Value.Expression.Text, want.Expression, facts))
}

func sequenceFor(f *Facts, owner sc.Ref) *sc.Sequence {
	if f == nil {
		return nil
	}
	for i := range f.Sequences {
		s := &f.Sequences[i]
		if s.Owner.Value != nil && *s.Owner.Value == owner {
			return s
		}
	}
	return nil
}

func identityMatches(engine string, f *Facts, c sc.Column, want *Identity, prior *sc.Sequence) bool {
	if c.Identity.Value == nil {
		return false
	}
	kind := "none"
	if want != nil {
		kind = want.Kind
	}
	if c.Identity.Value.Kind != kind {
		return false
	}
	if kind == "none" || kind == "autoIncrement" {
		return c.Identity.Value.Sequence == nil && sequenceFor(f, c.Ref) == nil
	}
	s := sequenceFor(f, c.Ref)
	if s == nil || c.Identity.Value.Sequence == nil || *c.Identity.Value.Sequence != s.Ref || s.Type.Value == nil || c.Type.Value == nil || !reflect.DeepEqual(*s.Type.Value, *c.Type.Value) {
		return false
	}
	if prior != nil && prior.Ref != s.Ref {
		return false
	}
	defaults := []string{"1", "1", "1", "2147483647", "1"}
	if c.Type.Value.Ref.Name == "int8" {
		defaults[3] = "9223372036854775807"
	}
	negative := want.Increment != nil && strings.HasPrefix(*want.Increment, "-")
	if negative {
		defaults[0] = "-1"
		defaults[2] = "-2147483648"
		defaults[3] = "-1"
		if c.Type.Value.Ref.Name == "int8" {
			defaults[2] = "-9223372036854775808"
		}
	}
	if prior == nil {
		if want.Minimum != nil {
			defaults[2] = *want.Minimum
		}
		if want.Maximum != nil {
			defaults[3] = *want.Maximum
		}
		if negative {
			defaults[0] = defaults[3]
		} else {
			defaults[0] = defaults[2]
		}
	}
	actual := []*string{s.Start.Value, s.Increment.Value, s.Min.Value, s.Max.Value, s.Cache.Value}
	options := []*string{want.Start, want.Increment, want.Minimum, want.Maximum, want.Cache}
	var previous []*string
	if prior != nil {
		previous = []*string{prior.Start.Value, prior.Increment.Value, prior.Min.Value, prior.Max.Value, prior.Cache.Value}
	}
	for i, value := range actual {
		if value == nil {
			return false
		}
		expected := defaults[i]
		if previous != nil && previous[i] != nil {
			expected = *previous[i]
		}
		if options[i] != nil {
			expected = *options[i]
		}
		if *value != expected {
			return false
		}
	}
	cycle := false
	if prior != nil && prior.Cycle.Value != nil {
		cycle = *prior.Cycle.Value
	}
	if want.Cycle != nil {
		cycle = *want.Cycle
	}
	return s.Cycle.Value != nil && *s.Cycle.Value == cycle
}

func IdentitySQL(x Identity) string {
	parts := []string{}
	for _, pair := range []struct {
		key   string
		value *string
	}{{"START WITH", x.Start}, {"INCREMENT BY", x.Increment}, {"MINVALUE", x.Minimum}, {"MAXVALUE", x.Maximum}, {"CACHE", x.Cache}} {
		if pair.value != nil {
			parts = append(parts, pair.key+" "+*pair.value)
		}
	}
	if x.Cycle != nil {
		if *x.Cycle {
			parts = append(parts, "CYCLE")
		} else {
			parts = append(parts, "NO CYCLE")
		}
	}
	return strings.Join(parts, " ")
}

func IdentityOptions(x Identity) []string {
	parts := []string{}
	for _, pair := range []struct {
		key   string
		value *string
	}{{"START WITH", x.Start}, {"INCREMENT BY", x.Increment}, {"MINVALUE", x.Minimum}, {"MAXVALUE", x.Maximum}, {"CACHE", x.Cache}} {
		if pair.value != nil {
			parts = append(parts, "SET "+pair.key+" "+*pair.value)
		}
	}
	if x.Cycle != nil {
		if *x.Cycle {
			parts = append(parts, "SET CYCLE")
		} else {
			parts = append(parts, "SET NO CYCLE")
		}
	}
	return parts
}

func ExpectedGeneratedAttribute(g *Generation) string {
	if g == nil {
		return ""
	}
	return map[string]string{"stored": "s", "virtual": "v"}[g.Storage]
}

func expectedIdentityAttribute(i *Identity) string {
	if i == nil {
		return ""
	}
	return map[string]string{"always": "a", "byDefault": "d"}[i.Kind]
}

func TypeIdentityKey(t TypeReference) string {
	return strconv.Itoa(len(t.Schema)) + ":" + t.Schema + t.Name
}

func authoredDefaultMatches(engine string, c sc.Column, want Column, match func(sc.Column, Default) bool) bool {
	if want.Default.Kind == "none" && want.Resolved != nil && want.Resolved.InheritedDefault != nil && want.Resolved.InheritedDefault.Kind != "none" {
		x := want.Resolved.InheritedDefault
		return match(c, want.Default) || c.Default.Value != nil && c.Default.Value.Kind == x.Kind && x.Expression != nil && c.Default.Value.Expression != nil && SameExpression(engine, c.Default.Value.Expression.Text, x.Expression.Text)
	}
	return match(c, want.Default)
}

func stripResolvedTypes(before, after *Facts, c Column) bool {
	if c.Resolved == nil {
		return true
	}
	for _, expected := range c.Resolved.Definitions {
		found := false
		for _, actual := range after.Types {
			if actual.Ref == expected.Ref {
				if !reflect.DeepEqual(actual, expected) {
					return false
				}
				found = true
			}
		}
		if !found {
			return false
		}
		for _, f := range []*Facts{before, after} {
			out := []sc.TypeDefinition{}
			for _, actual := range f.Types {
				if actual.Ref == expected.Ref {
					if !reflect.DeepEqual(actual, expected) {
						return false
					}
					continue
				}
				out = append(out, actual)
			}
			f.Types = out
		}
	}
	return true
}

func stripOwnedSequences(before, after *Facts, owner sc.Ref) {
	for _, f := range []*Facts{before, after} {
		out := []sc.Sequence{}
		for _, s := range f.Sequences {
			if s.Owner.Value == nil || *s.Owner.Value != owner {
				out = append(out, s)
			}
		}
		f.Sequences = out
	}
}

func expressionIdentifiers(f *Facts) map[string]bool {
	known := map[string]bool{}
	if f == nil || f.ExpressionKeywords == nil {
		return known
	}
	blocked := map[string]bool{}
	for _, keyword := range f.ExpressionKeywords {
		blocked[strings.ToLower(keyword)] = true
	}
	for _, keyword := range strings.Fields("NULL TRUE FALSE CURRENT_USER CURRENT_ROLE SESSION_USER SYSTEM_USER CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP CURRENT_CATALOG CURRENT_SCHEMA LOCALTIME LOCALTIMESTAMP UTC_DATE UTC_TIME UTC_TIMESTAMP") {
		blocked[strings.ToLower(keyword)] = true
	}
	add := func(name string) {
		if asciiIdentifier(name) && name == strings.ToLower(name) && !blocked[name] {
			known[name] = true
		}
	}
	add(f.Table.Ref.Schema)
	add(f.Table.Ref.Name)
	for _, c := range f.Table.Columns.Items {
		add(c.Ref.Name)
	}
	for _, t := range f.Types {
		add(t.Ref.Schema)
		add(t.Ref.Name)
	}
	return known
}
