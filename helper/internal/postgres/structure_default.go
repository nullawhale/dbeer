package postgres

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"math/big"
	"regexp"
	"strconv"
	"strings"
)

var structureCasts = regexp.MustCompile(`^(?:::(?:pg_catalog\.)?(?:integer|bigint|numeric|text|boolean|character varying|varchar|int4|int8|bool)(?:\([0-9, ]+\))?)*$`)

func structureDefaultMatches(c sc.Column, want tableedit.Default) bool {
	if c.Default.Value == nil {
		return false
	}
	d := c.Default.Value
	if want.Kind == "none" {
		return d.Kind == "none"
	}
	if d.Kind != "expression" || d.Expression == nil {
		return false
	}
	expr := strings.TrimSpace(d.Expression.Text)
	for strings.HasPrefix(expr, "(") && strings.HasSuffix(expr, ")") {
		expr = strings.TrimSpace(expr[1 : len(expr)-1])
	}
	value, tail, quoted, ok := structureScalar(expr)
	if !ok || !structureCasts.MatchString(strings.TrimSpace(tail)) {
		return false
	}
	switch want.Kind {
	case "null":
		return !quoted && strings.EqualFold(value, "NULL")
	case "text":
		return quoted && want.Value != nil && value == *want.Value
	case "numeric":
		if want.Value == nil {
			return false
		}
		a, ok := new(big.Rat).SetString(value)
		b, other := new(big.Rat).SetString(*want.Value)
		return ok && other && a.Cmp(b) == 0
	case "boolean":
		return !quoted && want.Value != nil && value == *want.Value
	}
	return false
}
func structureScalar(s string) (string, string, bool, bool) {
	escaped := false
	if strings.HasPrefix(s, "E'") || strings.HasPrefix(s, "e'") {
		escaped = true
		s = s[1:]
	}
	if strings.HasPrefix(s, "'") {
		var value strings.Builder
		s = s[1:]
		for len(s) > 0 {
			if s[0] == '\'' {
				if len(s) > 1 && s[1] == '\'' {
					value.WriteByte('\'')
					s = s[2:]
					continue
				}
				return value.String(), s[1:], true, true
			}
			if escaped && s[0] == '\\' {
				r, _, tail, e := strconv.UnquoteChar(s, '\'')
				if e != nil {
					return "", "", false, false
				}
				value.WriteRune(r)
				s = tail
				continue
			}
			value.WriteByte(s[0])
			s = s[1:]
		}
		return "", "", false, false
	}
	value, tail, found := strings.Cut(s, "::")
	if found {
		tail = "::" + tail
	}
	return strings.TrimSpace(value), tail, false, value != ""
}
