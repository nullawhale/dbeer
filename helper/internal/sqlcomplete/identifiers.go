package sqlcomplete

import "strings"

func identifierName(t token, engine string) string {
	if engine != "mysql" && engine != "sqlite" && t.kind == wordToken {
		return strings.ToLower(t.value)
	}
	return t.value
}

func identifierEqual(token token, name, engine string) bool {
	if engine == "sqlite" {
		return sqliteIdentifierFold(token.value) == sqliteIdentifierFold(name)
	}
	if token.kind == quotedToken {
		return token.value == name
	}
	if engine == "mysql" {
		return strings.EqualFold(token.value, name)
	}
	return strings.ToLower(token.value) == name
}

func identifierTokenEqual(a, b token, engine string) bool {
	name := b.value
	if engine != "mysql" && engine != "sqlite" && b.kind == wordToken {
		name = strings.ToLower(name)
	}
	return identifierEqual(a, name, engine)
}

// SQLite folds ASCII identifier letters, including quoted identifiers; Unicode
// case folding would merge distinct non-ASCII names such as Kelvin sign and K.
func sqliteIdentifierFold(value string) string {
	b := []byte(value)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + ('a' - 'A')
		}
	}
	return string(b)
}
