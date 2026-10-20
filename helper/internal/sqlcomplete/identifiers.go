package sqlcomplete

import "strings"

func identifierName(t token, engine string) string {
	if engine != "mysql" && t.kind == wordToken {
		return strings.ToLower(t.value)
	}
	return t.value
}

func identifierEqual(token token, name, engine string) bool {
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
	if engine != "mysql" && b.kind == wordToken {
		name = strings.ToLower(name)
	}
	return identifierEqual(a, name, engine)
}
