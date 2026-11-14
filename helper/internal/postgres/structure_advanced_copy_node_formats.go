package postgres

import (
	"errors"
	"strings"
)

// PostgreSQL's CoercionForm is display-only and equal() ignores it. This
// lexer changes only a valid direct FUNCEXPR.funcformat field; every binding,
// argument, other field, quoted token and escaped byte remains unchanged.
func pgAdvancedCopyIndexNodeFormats(value any) (any, error) {
	if value == nil {
		return nil, nil
	}
	s, ok := value.(string)
	if !ok || len(s) > 2<<20 {
		return nil, errors.New("The native index expression is outside the bounded representation proof.")
	}
	type frame struct {
		tag                     string
		formats, paren, bracket int
	}
	stack := []frame{}
	delimiters := []byte{}
	positions := []int{}
	paren, bracket := 0, 0
	quoted := false
	space := func(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }
	word := func(c byte) bool {
		return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_'
	}
	for i := 0; i < len(s); {
		c := s[i]
		if c == '\\' {
			if i+1 >= len(s) {
				return nil, errors.New("An escaped native index token is incomplete.")
			}
			i += 2
			continue
		}
		if c == '"' {
			quoted = !quoted
			i++
			continue
		}
		if quoted {
			i++
			continue
		}
		switch c {
		case '{':
			if len(delimiters) >= 512 {
				return nil, errors.New("The native index expression exceeds the bounded nesting depth.")
			}
			delimiters = append(delimiters, c)
			j := i + 1
			for j < len(s) && space(s[j]) {
				j++
			}
			start := j
			for j < len(s) && word(s[j]) {
				j++
			}
			if j == start || len(stack) >= 512 {
				return nil, errors.New("A native index node tag or nesting depth is unproven.")
			}
			stack = append(stack, frame{tag: s[start:j], paren: paren, bracket: bracket})
			i = j
			continue
		case '}':
			if len(stack) == 0 || len(delimiters) == 0 || delimiters[len(delimiters)-1] != '{' {
				return nil, errors.New("The native index node tree is unbalanced.")
			}
			f := stack[len(stack)-1]
			if paren != f.paren || bracket != f.bracket || f.tag == "FUNCEXPR" && f.formats != 1 {
				return nil, errors.New("A native function display field is absent, duplicated or outside its node.")
			}
			stack = stack[:len(stack)-1]
			delimiters = delimiters[:len(delimiters)-1]
		case '(', '[':
			if len(delimiters) >= 512 {
				return nil, errors.New("The native index expression exceeds the bounded nesting depth.")
			}
			delimiters = append(delimiters, c)
			if c == '(' {
				paren++
			} else {
				bracket++
			}
		case ')', ']':
			want := byte('(')
			if c == ']' {
				want = '['
			}
			if len(delimiters) == 0 || delimiters[len(delimiters)-1] != want {
				return nil, errors.New("The native index expression delimiters are unbalanced.")
			}
			delimiters = delimiters[:len(delimiters)-1]
			if c == ')' {
				paren--
			} else {
				bracket--
			}
		case ':':
			if len(stack) == 0 || i > 0 && !space(s[i-1]) && s[i-1] != '{' {
				break
			}
			f := &stack[len(stack)-1]
			if f.tag != "FUNCEXPR" || paren != f.paren || bracket != f.bracket {
				break
			}
			j := i + 1
			for j < len(s) && word(s[j]) {
				j++
			}
			if s[i+1:j] != "funcformat" {
				break
			}
			f.formats++
			if f.formats != 1 || j == len(s) || !space(s[j]) {
				return nil, errors.New("The native function display field is malformed or duplicated.")
			}
			for j < len(s) && space(s[j]) {
				j++
			}
			if j >= len(s) || s[j] < '0' || s[j] > '3' || j+1 < len(s) && !space(s[j+1]) && s[j+1] != '}' {
				return nil, errors.New("The native function display field is outside PostgreSQL's closed enum.")
			}
			positions = append(positions, j)
		}
		if paren < 0 || bracket < 0 {
			return nil, errors.New("The native index expression delimiters are unbalanced.")
		}
		i++
	}
	if quoted || len(stack) != 0 || paren != 0 || bracket != 0 {
		return nil, errors.New("The native index expression is incomplete.")
	}
	if len(positions) == 0 {
		return s, nil
	}
	var out strings.Builder
	start := 0
	for _, i := range positions {
		out.WriteString(s[start:i])
		out.WriteByte('0')
		start = i + 1
	}
	out.WriteString(s[start:])
	return out.String(), nil
}
