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

// lex deliberately diagnoses only lexical constructs. It never treats unfamiliar
// dialect syntax as invalid SQL and never includes source text in diagnostics.
func lex(text, engine string) ([]token, []Diagnostic) {
	tokens := make([]token, 0, min(len(text)/4, 4096))
	diagnostics := []Diagnostic{}
	parentheses := []int{}
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
		if engine != "mysql" && text[i] == '$' {
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
		if text[i] == '\'' || text[i] == '"' || text[i] == '`' {
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
		if identifierRune(r) {
			i += size
			for i < len(text) {
				next, n := utf8.DecodeRuneInString(text[i:])
				if !identifierRune(next) {
					break
				}
				i += n
			}
			add(wordToken, start, i, text[start:i], false)
			continue
		}
		i += size
		if r == '(' {
			parentheses = append(parentheses, start)
		}
		if r == ')' {
			if len(parentheses) == 0 {
				addDiagnostic(start, i, "Unexpected closing parenthesis.")
			} else {
				parentheses = parentheses[:len(parentheses)-1]
			}
		}
		add(punctuationToken, start, i, text[start:i], false)
	}
	for _, start := range parentheses {
		addDiagnostic(start, start+1, "Unclosed parenthesis.")
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
	_, diagnostics := lex(text, engine)
	return diagnostics
}
