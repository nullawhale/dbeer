package mysql

import (
	"dbeer/helper/internal/tableedit"
	"strings"
)

// Catalogs do not expose trigger/routine table edges. Inspect identifiers only;
// dynamic SQL remains an explicit limitation and no expression is rewritten.
func mysqlMayReferenceTable(body, contextSchema string, target tableedit.Target, sqlMode string) bool {
	noBackslash := false
	for _, mode := range strings.Split(sqlMode, ",") {
		noBackslash = noBackslash || mode == "NO_BACKSLASH_ESCAPES"
	}
	tokens := []string{}
	for i := 0; i < len(body); {
		c := body[i]
		if c == '\'' || c == '"' || c == '`' {
			quote := c
			i++
			var value strings.Builder
			closed := false
			for i < len(body) {
				c = body[i]
				i++
				if c == '\\' && quote == '`' {
					return true
				}
				if c == '\\' && !noBackslash {
					if i == len(body) {
						return true
					}
					value.WriteByte(body[i])
					i++
					continue
				}
				if c == quote {
					if i < len(body) && body[i] == quote {
						value.WriteByte(c)
						i++
						continue
					}
					closed = true
					break
				}
				value.WriteByte(c)
			}
			if !closed {
				return true
			}
			if quote != '\'' {
				tokens = append(tokens, value.String())
			}
			continue
		}
		if c == '.' {
			tokens = append(tokens, ".")
			i++
			continue
		}
		if c == '_' || c == '$' || c >= 128 || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' {
			start := i
			i++
			for i < len(body) {
				c = body[i]
				if !(c == '_' || c == '$' || c >= 128 || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
					break
				}
				i++
			}
			tokens = append(tokens, body[start:i])
			continue
		}
		i++
	}
	for i, name := range tokens {
		if !strings.EqualFold(name, target.Table) {
			continue
		}
		if contextSchema == target.Schema || i >= 2 && tokens[i-1] == "." && strings.EqualFold(tokens[i-2], target.Schema) {
			return true
		}
	}
	return false
}
