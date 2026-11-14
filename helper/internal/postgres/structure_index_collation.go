package postgres

import (
	"strconv"
	"strings"
)

type indexExpressionCollation struct {
	oid        string
	known      bool
	functionID string
}

// Read only root scalar fields from PostgreSQL's catalog node list. Never
// evaluate/deparse a node or infer a value from a nested child. Unknown grammar
// and future node kinds retain unknown collation evidence.
func catalogIndexExpressionCollations(raw string) ([]indexExpressionCollation, bool) {
	if len(raw) > 2<<20 {
		return nil, false
	}
	raw = strings.TrimSpace(raw)
	if raw == "" || raw == "<>" {
		return nil, true
	}
	if len(raw) < 2 || raw[0] != '(' || raw[len(raw)-1] != ')' {
		return nil, false
	}
	var out []indexExpressionCollation
	for i := 1; i < len(raw)-1; {
		for i < len(raw)-1 && (raw[i] == ' ' || raw[i] == '\n' || raw[i] == '\t') {
			i++
		}
		if i == len(raw)-1 {
			break
		}
		if raw[i] != '{' || len(out) >= 32 {
			return nil, false
		}
		start, braces, parens, brackets := i, 0, 0, 0
		quoted := false
		fields := map[string]string{}
		classEnd := i + 1
		for classEnd < len(raw) && raw[classEnd] != ' ' && raw[classEnd] != '}' {
			classEnd++
		}
		kind := raw[i+1 : classEnd]
		closed := false
		for ; i < len(raw)-1; i++ {
			c := raw[i]
			if c == '\\' {
				i++
				if i >= len(raw)-1 {
					return nil, false
				}
				continue
			}
			if c == '"' {
				quoted = !quoted
				continue
			}
			if quoted {
				continue
			}
			switch c {
			case '{':
				braces++
			case '}':
				braces--
			case '(':
				parens++
			case ')':
				parens--
			case '[':
				brackets++
			case ']':
				brackets--
			}
			if braces < 0 || parens < 0 || brackets < 0 {
				return nil, false
			}
			if braces == 0 {
				if parens != 0 || brackets != 0 || i == start {
					return nil, false
				}
				closed = true
				i++
				break
			}
			if c == ':' && braces == 1 && parens == 0 && brackets == 0 {
				end := i + 1
				for end < len(raw) && (raw[end] >= 'a' && raw[end] <= 'z' || raw[end] >= 'A' && raw[end] <= 'Z' || raw[end] >= '0' && raw[end] <= '9' || raw[end] == '_') {
					end++
				}
				if end == i+1 || end >= len(raw) || raw[end] != ' ' {
					return nil, false
				}
				name := raw[i+1 : end]
				value := end + 1
				for value < len(raw) && raw[value] == ' ' {
					value++
				}
				end = value
				for end < len(raw) && raw[end] >= '0' && raw[end] <= '9' {
					end++
				}
				if end > value && (end == len(raw) || raw[end] == ' ' || raw[end] == '}') {
					if _, duplicate := fields[name]; duplicate {
						return nil, false
					}
					fields[name] = raw[value:end]
				}
			}
		}
		if !closed || quoted {
			return nil, false
		}
		names := map[string]string{"VAR": "varcollid", "CONST": "constcollid", "FUNCEXPR": "funccollid", "OPEXPR": "opcollid", "DISTINCTEXPR": "opcollid", "NULLIFEXPR": "opcollid", "FIELDSELECT": "resultcollid", "RELABELTYPE": "resultcollid", "COERCEVIAIO": "resultcollid", "ARRAYCOERCEEXPR": "resultcollid", "CONVERTROWTYPEEXPR": "resultcollid", "COERCETODOMAIN": "resultcollid", "COLLATEEXPR": "collOid", "CASEEXPR": "casecollid", "CASETESTEXPR": "collation", "COERCETODOMAINVALUE": "collation", "SETTODEFAULT": "collation", "ARRAYEXPR": "array_collid", "COALESCEEXPR": "coalescecollid", "MINMAXEXPR": "minmaxcollid", "SUBSCRIPTINGREF": "refcollid"}
		field, recognized := names[kind]
		oid, has := fields[field]
		n, err := strconv.ParseUint(oid, 10, 32)
		functionID := ""
		if kind == "FUNCEXPR" {
			functionID = fields["funcid"]
		}
		out = append(out, indexExpressionCollation{oid: strconv.FormatUint(n, 10), known: recognized && has && err == nil, functionID: functionID})
	}
	return out, true
}
