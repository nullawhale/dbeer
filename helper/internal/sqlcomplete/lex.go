package sqlcomplete

import (
	"dbeer/helper/internal/mongoscript"
	"strings"
	"unicode"
	"unicode/utf8"
)

type tokenKind uint8

const (
	wordToken tokenKind = iota
	quotedToken
	punctuationToken
	stringToken
	commentToken
)

type token struct {
	kind       tokenKind
	value      string
	start, end int
	openEnd    bool
}

func identifierRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' || r == '$'
}

func dialectIdentifierRune(r rune, engine string) bool {
	return identifierRune(r) && (engine != "cassandra" || r != '$')
}

// lex deliberately diagnoses only lexical constructs. It never treats unfamiliar
// dialect syntax as invalid SQL and never includes source text in diagnostics.
func lex(text, engine string) ([]token, []Diagnostic) {
	tokens := make([]token, 0, min(len(text)/4, 4096))
	diagnostics := []Diagnostic{}
	type delimiter struct {
		start int
		value rune
	}
	delimiters := []delimiter{}
	addDiagnostic := func(start, end int, message string) {
		if len(diagnostics) < 64 {
			diagnostics = append(diagnostics, Diagnostic{Start: start, End: end, Message: message})
		}
	}
	add := func(kind tokenKind, start, end int, value string, openEnd bool) {
		if len(tokens) < 200000 {
			tokens = append(tokens, token{kind: kind, start: start, end: end, value: value, openEnd: openEnd})
		}
	}
	for i := 0; i < len(text); {
		start := i
		r, size := utf8.DecodeRuneInString(text[i:])
		if unicode.IsSpace(r) {
			i += size
			continue
		}
		dashComment := strings.HasPrefix(text[i:], "--") && (engine != "mysql" || i+2 == len(text) || text[i+2] <= ' ')
		if dashComment || engine == "cassandra" && strings.HasPrefix(text[i:], "//") || engine == "mysql" && text[i] == '#' {
			if end := strings.IndexAny(text[i:], "\r\n"); end >= 0 {
				i += end
			} else {
				i = len(text)
			}
			add(commentToken, start, i, "", true)
			continue
		}
		if strings.HasPrefix(text[i:], "/*") {
			i += 2
			depth := 1
			for i < len(text) && depth > 0 {
				if strings.HasPrefix(text[i:], "/*") && engine != "mysql" && engine != "cassandra" {
					depth++
					i += 2
				} else if strings.HasPrefix(text[i:], "*/") {
					depth--
					i += 2
				} else {
					i++
				}
			}
			if depth > 0 {
				addDiagnostic(start, min(start+2, len(text)), "Unterminated comment.")
			}
			add(commentToken, start, i, "", depth > 0)
			continue
		}
		if (engine == "postgresql" || engine == "cassandra" && strings.HasPrefix(text[i:], "$$")) && text[i] == '$' {
			end := i + 1
			for end < len(text) {
				r, size := utf8.DecodeRuneInString(text[end:])
				if !(r == '_' || unicode.IsLetter(r) || end > i+1 && unicode.IsDigit(r)) {
					break
				}
				end += size
			}
			if end < len(text) && text[end] == '$' {
				delimiter := text[i : end+1]
				openEnd := false
				if close := strings.Index(text[end+1:], delimiter); close >= 0 {
					i = end + 1 + close + len(delimiter)
				} else {
					openEnd = true
					i = len(text)
					addDiagnostic(start, end+1, "Unterminated string.")
				}
				add(stringToken, start, i, "", openEnd)
				continue
			}
		}
		if text[i] == '\'' || text[i] == '"' || engine == "mysql" && text[i] == '`' {
			quote := text[i]
			backslashEscapes := engine == "mysql" || engine != "cassandra" && quote == '\'' && start > 0 && (text[start-1] == 'e' || text[start-1] == 'E') && (start < 2 || !identifierRune(rune(text[start-2])))
			i++
			terminated := false
			var value strings.Builder
			for i < len(text) {
				if text[i] == quote {
					if i+1 < len(text) && text[i+1] == quote {
						value.WriteByte(quote)
						i += 2
						continue
					}
					i++
					terminated = true
					break
				}
				if text[i] == '\\' && backslashEscapes && quote != '`' && i+1 < len(text) {
					i += 2
					continue
				}
				value.WriteByte(text[i])
				i++
			}
			kind := quotedToken
			if quote == '\'' || quote == '"' && engine == "mysql" {
				kind = stringToken
			}
			if !terminated {
				message := "Unterminated identifier."
				if kind == stringToken {
					message = "Unterminated string."
				}
				addDiagnostic(start, start+1, message)
			}
			add(kind, start, i, value.String(), !terminated)
			continue
		}
		if dialectIdentifierRune(r, engine) {
			i += size
			for i < len(text) {
				next, n := utf8.DecodeRuneInString(text[i:])
				if !dialectIdentifierRune(next, engine) {
					break
				}
				i += n
			}
			add(wordToken, start, i, text[start:i], false)
			continue
		}
		i += size
		if r == '(' || engine == "cassandra" && (r == '[' || r == '{') {
			delimiters = append(delimiters, delimiter{start, r})
		}
		if r == ')' || engine == "cassandra" && (r == ']' || r == '}') {
			opening, label := '(', "parenthesis"
			if r == ']' {
				opening, label = '[', "square bracket"
			} else if r == '}' {
				opening, label = '{', "brace"
			}
			if len(delimiters) == 0 || delimiters[len(delimiters)-1].value != opening {
				addDiagnostic(start, i, "Unexpected closing "+label+".")
			} else {
				delimiters = delimiters[:len(delimiters)-1]
			}
		}
		add(punctuationToken, start, i, text[start:i], false)
	}
	for _, delimiter := range delimiters {
		label := "parenthesis"
		if delimiter.value == '[' {
			label = "square bracket"
		} else if delimiter.value == '{' {
			label = "brace"
		}
		addDiagnostic(delimiter.start, delimiter.start+1, "Unclosed "+label+".")
	}
	return tokens, diagnostics
}

// Diagnostics reports lexical errors without retaining source text.
func Diagnostics(text, engine string) []Diagnostic {
	if engine == "mongodb" {
		if strings.TrimSpace(text) == "" {
			return nil
		}
		if _, err := mongoscript.Parse(text); err != nil {
			return []Diagnostic{{Start: 0, End: len(text), Message: "Use a JSON request with collection and find or aggregate. JavaScript, unknown options, and duplicate keys are unsupported."}}
		}
		return nil
	}
	tokens, diagnostics := lex(text, engine)
	if engine == "cassandra" {
		first := []token{}
		check := func() {
			if len(first) == 0 || first[0].kind != wordToken || len(diagnostics) >= 64 {
				return
			}
			name := strings.ToUpper(first[0].value)
			end := first[0].end
			if name == "SERIAL" && len(first) > 1 && word(first[1], "CONSISTENCY") {
				name, end = "CONSISTENCY", first[1].end
			}
			message := "cqlsh client commands are not supported in CQL documents."
			switch name {
			case "CONSISTENCY":
				message = "Set Cassandra consistency in connection Options; cqlsh client commands are not supported."
			case "SOURCE", "COPY", "CAPTURE", "PAGING", "EXPAND", "TRACING", "SHOW", "HELP", "LOGIN", "EXIT", "QUIT":
			default:
				return
			}
			diagnostics = append(diagnostics, Diagnostic{Start: first[0].start, End: end, Message: message})
		}
		for _, token := range tokens {
			if punct(token, ";") {
				check()
				first = nil
			} else if token.kind != commentToken && len(first) < 2 {
				first = append(first, token)
			}
		}
		check()
	}
	return diagnostics
}
