// Package queryparams rewrites only named placeholders, never parameter values.
package queryparams

import (
	"errors"
	"strconv"
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
)

var ErrInvalid = errors.New("Invalid query parameters or ambiguous parameter syntax.")
var ErrUnsupported = errors.New("Query parameters are available only for PostgreSQL, MySQL and SQLite.")

type Bound struct {
	SQL string
	// AssessmentSQL replaces each placeholder with an opaque numeric token of
	// identical byte length. Parameter names cannot become policy keywords,
	// and assessment ranges remain offsets into the original source.
	AssessmentSQL string
	Parameters    []protocol.QueryParameter
}

func Bind(engine, sql string, parameters []protocol.QueryParameter) (Bound, error) {
	if !protocol.QueryParametersValid(parameters) {
		return Bound{}, ErrInvalid
	}
	if engine == "" {
		engine = "postgresql"
	}
	if engine != "postgresql" && engine != "mysql" && engine != "sqlite" {
		if parameters != nil {
			return Bound{}, ErrUnsupported
		}
		return Bound{SQL: sql, AssessmentSQL: sql}, nil
	}
	// Existing unparameterized SQL may contain colons, including PostgreSQL
	// array slice bounds. Only opt in to placeholder syntax with definitions.
	if len(parameters) == 0 {
		return Bound{SQL: sql, AssessmentSQL: sql}, nil
	}
	if engine == "mysql" {
		for _, p := range parameters {
			if p.Type == "decimal" && p.Value != nil {
				integer, fraction, _ := strings.Cut(strings.TrimLeft(*p.Value, "+-"), ".")
				if len(integer)+len(fraction) > 65 || len(fraction) > 30 {
					return Bound{}, ErrInvalid
				}
			}
		}
	}
	bound, err := scan(engine, sql, parameters, false)
	if err != nil {
		return Bound{}, err
	}
	// Session SQL modes may alter backslash quoting. Accept only when both
	// interpretations locate identical placeholders; explicit PG E strings
	// always retain their defined escape rules.
	if engine != "sqlite" && len(parameters) > 0 && strings.Contains(sql, "\\") {
		alternate, err := scan(engine, sql, parameters, true)
		if err != nil || alternate.SQL != bound.SQL {
			return Bound{}, ErrInvalid
		}
	}
	return bound, nil
}

func scan(engine, sql string, parameters []protocol.QueryParameter, escapes bool) (Bound, error) {
	definitions := map[string]protocol.QueryParameter{}
	for _, p := range parameters {
		definitions[p.Name] = p
	}
	bound, used := Bound{}, map[string]int{}
	var output strings.Builder
	var assessment strings.Builder
	last, boundBytes := 0, 0
	for i := 0; i < len(sql); {
		c := sql[i]
		if c == '[' && engine == "sqlite" {
			end := strings.IndexByte(sql[i+1:], ']')
			if end < 0 {
				return Bound{}, ErrInvalid
			}
			i += end + 2
			continue
		}
		if c == '\'' || c == '"' || c == '`' && (engine == "mysql" || engine == "sqlite") {
			quote, escape := c, escapes && c != '`'
			if engine == "postgresql" && c == '\'' && i > 0 && (sql[i-1] == 'e' || sql[i-1] == 'E') && (i == 1 || !identifier(sql[i-2])) {
				escape = true
			}
			i++
			closed := false
			for i < len(sql) {
				if sql[i] == '\\' && escape {
					i += 2
					continue
				}
				if sql[i] == quote {
					i++
					if i < len(sql) && sql[i] == quote {
						i++
						continue
					}
					closed = true
					break
				}
				i++
			}
			if !closed && len(parameters) > 0 {
				return Bound{}, ErrInvalid
			}
			continue
		}
		if strings.HasPrefix(sql[i:], "--") && (engine == "postgresql" || engine == "sqlite" || i+2 == len(sql) || sql[i+2] <= ' ') || c == '#' && engine == "mysql" {
			for i < len(sql) && sql[i] != '\n' && sql[i] != '\r' {
				i++
			}
			continue
		}
		if strings.HasPrefix(sql[i:], "/*") {
			if engine == "mysql" && len(parameters) > 0 && (strings.HasPrefix(sql[i:], "/*!") || strings.HasPrefix(sql[i:], "/*M!")) {
				return Bound{}, ErrInvalid
			}
			depth := 1
			i += 2
			for i < len(sql) && depth > 0 {
				if engine == "postgresql" && strings.HasPrefix(sql[i:], "/*") {
					depth++
					i += 2
				} else if strings.HasPrefix(sql[i:], "*/") {
					depth--
					i += 2
				} else {
					i++
				}
			}
			if depth != 0 && len(parameters) > 0 {
				return Bound{}, ErrInvalid
			}
			continue
		}
		if c == '$' && engine == "postgresql" && (i == 0 || !identifier(sql[i-1])) {
			j := i + 1
			if j < len(sql) && sql[j] >= '0' && sql[j] <= '9' && len(parameters) > 0 {
				return Bound{}, ErrInvalid
			}
			for j < len(sql) && (asciiStart(sql[j]) || j > i+1 && sql[j] >= '0' && sql[j] <= '9' || sql[j] >= 128) {
				j++
			}
			if j < len(sql) && sql[j] == '$' {
				delimiter := sql[i : j+1]
				end := strings.Index(sql[j+1:], delimiter)
				if end < 0 {
					if len(parameters) > 0 {
						return Bound{}, ErrInvalid
					}
					i = len(sql)
					continue
				}
				i = j + 1 + end + len(delimiter)
				continue
			}
		}
		if c == '?' && (engine == "mysql" || engine == "sqlite") && len(parameters) > 0 {
			return Bound{}, ErrInvalid
		}
		// SQLite also accepts $name and @name variables. They must not be
		// mixed with the explicitly declared :name contract. A dollar within
		// a bare identifier (for example foo$bar) remains an identifier.
		if engine == "sqlite" && (c == '@' || c == '$' && (i == 0 || !identifier(sql[i-1]))) {
			if i+1 < len(sql) && identifier(sql[i+1]) {
				return Bound{}, ErrInvalid
			}
		}
		if c == ':' {
			if i+1 < len(sql) && (sql[i+1] == ':' || sql[i+1] == '=') {
				i += 2
				continue
			}
			if i+1 < len(sql) && asciiStart(sql[i+1]) {
				j := i + 2
				for j < len(sql) && (asciiStart(sql[j]) || sql[j] >= '0' && sql[j] <= '9') {
					j++
				}
				name := sql[i+1 : j]
				p, ok := definitions[name]
				if !ok || j < len(sql) && (sql[j] >= 128 || sql[j] == '$') {
					return Bound{}, ErrInvalid
				}
				output.WriteString(sql[last:i])
				assessment.WriteString(sql[last:i])
				assessment.WriteString(strings.Repeat("0", j-i))
				if engine == "postgresql" {
					index := used[name]
					if index == 0 {
						bound.Parameters = append(bound.Parameters, p)
						index = len(bound.Parameters)
						used[name] = index
					}
					output.WriteByte('$')
					output.WriteString(strconv.Itoa(index))
				} else {
					bound.Parameters = append(bound.Parameters, p)
					if p.Value != nil {
						boundBytes += len(*p.Value)
					}
					// Repeated positional placeholders duplicate values on the wire.
					// Bound that amplification before the driver allocates packets.
					if boundBytes > 8*1024*1024 {
						return Bound{}, ErrInvalid
					}
					if len(bound.Parameters) > 65535 {
						return Bound{}, ErrInvalid
					}
					if engine == "sqlite" {
						output.WriteByte('?')
					} else {
						switch p.Type {
						case "decimal":
							precision, scale := 65, 30
							if p.Value != nil {
								integer, fraction, _ := strings.Cut(strings.TrimLeft(*p.Value, "+-"), ".")
								precision, scale = len(integer)+len(fraction), len(fraction)
							}
							output.WriteString("CAST(? AS DECIMAL(" + strconv.Itoa(precision) + "," + strconv.Itoa(scale) + "))")
						case "date":
							output.WriteString("CAST(? AS DATE)")
						case "timestamp":
							output.WriteString("CAST(? AS DATETIME(6))")
						default:
							output.WriteByte('?')
						}
					}
				}
				i, last = j, j
				continue
			}
		}
		_, size := utf8.DecodeRuneInString(sql[i:])
		i += size
	}
	output.WriteString(sql[last:])
	assessment.WriteString(sql[last:])
	bound.SQL = output.String()
	bound.AssessmentSQL = assessment.String()
	return bound, nil
}

func asciiStart(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' }
func identifier(c byte) bool { return asciiStart(c) || c >= '0' && c <= '9' || c == '$' || c >= 128 }
