package tableedit

import (
	"encoding/json"
	"reflect"
	"strings"
)

// MySQL prints utf8mb4 introducers and mode-dependent escapes in catalog SQL.
// Decode catalog literals only; authored expressions still pass the strict slot lexer.
func SameCatalogExpression(engine, actual, authored string, facts *Facts) bool {
	if _, err := ExpressionSlot(engine, authored); err != nil {
		return false
	}
	if engine != "mysql" && engine != "mariadb" {
		return sameExpressionIdentifiers(engine, actual, authored, expressionIdentifiers(facts), false)
	}
	actualTokens, ok := mysqlCatalogExpressionTokens(actual, facts)
	if !ok {
		return false
	}
	_, ansi := mysqlExpressionModes(facts)
	normalized, ok := mysqlCatalogLiterals(authored, true)
	if !ok {
		return false
	}
	authoredTokens, ok := expressionTokens(engine, normalized, expressionIdentifiers(facts), ansi)
	return ok && reflect.DeepEqual(actualTokens, authoredTokens)
}

func mysqlExpressionModes(facts *Facts) (noBackslash, ansi bool) {
	if facts != nil {
		for _, option := range facts.EngineContext {
			if option.Name == "sqlMode" {
				for _, mode := range strings.Split(option.Value, ",") {
					noBackslash = noBackslash || mode == "NO_BACKSLASH_ESCAPES"
					ansi = ansi || mode == "ANSI_QUOTES"
				}
			}
		}
	}
	return
}

func mysqlCatalogExpressionTokens(raw string, facts *Facts) ([]string, bool) {
	noBackslash, ansi := mysqlExpressionModes(facts)
	normalized, ok := mysqlCatalogLiterals(raw, noBackslash)
	if ok {
		if tokens, valid := expressionTokens("mysql", normalized, expressionIdentifiers(facts), ansi); valid {
			return tokens, true
		}
	}
	decoded, envelope := mysqlCatalogEnvelope(raw)
	if !envelope {
		return nil, false
	}
	normalized, ok = mysqlCatalogLiterals(decoded, noBackslash)
	if !ok {
		return nil, false
	}
	return expressionTokens("mysql", normalized, expressionIdentifiers(facts), ansi)
}

// Prove absence of direct column identifiers only. Uncertain syntax/case stays
// unknown; this does not upgrade general dependencies or rewrite expression SQL.
func MySQLExpressionExcludesColumn(raw, column string, facts *Facts) bool {
	// The comparison lexer does not classify MySQL digit/$-leading or
	// Unicode identifiers; these names never receive an absence proof.
	if facts == nil || !facts.Table.Columns.Complete || !asciiIdentifier(column) || !(column[0] >= 'a' && column[0] <= 'z' || column[0] >= 'A' && column[0] <= 'Z' || column[0] == '_') {
		return false
	}
	tokens, ok := mysqlCatalogExpressionTokens(raw, facts)
	if !ok {
		return false
	}
	for _, token := range tokens {
		name := ""
		if strings.HasPrefix(token, "word:") {
			name = strings.TrimPrefix(token, "word:")
		} else if strings.HasPrefix(token, "identifier:") {
			if json.Unmarshal([]byte(strings.TrimPrefix(token, "identifier:")), &name) != nil {
				return false
			}
		} else {
			continue
		}
		if strings.EqualFold(name, column) || !asciiIdentifier(name) {
			return false
		}
	}
	return true
}

func mysqlCatalogLiterals(raw string, noBackslash bool) (string, bool) {
	var out strings.Builder
	for i := 0; i < len(raw); {
		if (i == 0 || !expressionIdentifierByte(raw[i-1])) && len(raw)-i >= 9 && strings.EqualFold(raw[i:i+8], "_utf8mb4") && raw[i+8] == '\'' {
			i += 8
		}
		if raw[i] == '`' || raw[i] == '"' {
			start, quote := i, raw[i]
			i++
			closed := false
			for i < len(raw) {
				c := raw[i]
				i++
				if c == quote {
					if i < len(raw) && raw[i] == quote {
						i++
						continue
					}
					closed = true
					break
				}
			}
			if !closed {
				return "", false
			}
			out.WriteString(raw[start:i])
			continue
		}
		if raw[i] != '\'' {
			out.WriteByte(raw[i])
			i++
			continue
		}
		out.WriteByte('\'')
		i++
		closed := false
		for i < len(raw) {
			c := raw[i]
			i++
			if c == '\'' {
				if i < len(raw) && raw[i] == '\'' {
					out.WriteString("''")
					i++
					continue
				}
				out.WriteByte('\'')
				closed = true
				break
			}
			if c == '\\' && !noBackslash {
				if i == len(raw) {
					return "", false
				}
				c = raw[i]
				i++
				switch c {
				case '\'', '"', '\\':
				case 'n':
					c = '\n'
				case 'r':
					c = '\r'
				case 't':
					c = '\t'
				case 'b':
					c = '\b'
				case '0':
					c = 0
				case 'Z':
					c = 26
				default:
					return "", false
				}
			}
			if c == '\'' {
				out.WriteString("''")
			} else {
				out.WriteByte(c)
			}
		}
		if !closed {
			return "", false
		}
	}
	return out.String(), true
}

// MySQL bug100607 wraps I_S expressions in a string-escape envelope.
// Recognize an exact reversible envelope only for comparison; never rewrite executable SQL.
func mysqlCatalogEnvelope(raw string) (string, bool) {
	var decoded strings.Builder
	for i := 0; i < len(raw); i++ {
		c := raw[i]
		if c == '\\' {
			i++
			if i == len(raw) {
				return "", false
			}
			switch raw[i] {
			case '\\', '\'', '"':
				c = raw[i]
			case '0':
				c = 0
			case 'n':
				c = '\n'
			case 'r':
				c = '\r'
			case 'Z':
				c = 26
			default:
				return "", false
			}
		}
		decoded.WriteByte(c)
	}
	var encoded strings.Builder
	for _, c := range []byte(decoded.String()) {
		switch c {
		case '\\', '\'', '"':
			encoded.WriteByte('\\')
			encoded.WriteByte(c)
		case 0:
			encoded.WriteString(`\0`)
		case '\n':
			encoded.WriteString(`\n`)
		case '\r':
			encoded.WriteString(`\r`)
		case 26:
			encoded.WriteString(`\Z`)
		default:
			encoded.WriteByte(c)
		}
	}
	return decoded.String(), encoded.String() == raw && decoded.String() != raw
}
