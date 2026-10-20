package sqlcomplete

import (
	"fmt"
	"sort"
	"strings"
	"unicode/utf8"
)

type callFrame struct {
	open         int
	name, schema token
	arguments    [][]token
	argument     []token
	delimiter    string
}

// Signatures finds the innermost function call at the caret. Tokens inside
// strings/comments, subqueries, array constructors, and nested calls cannot
// advance the outer call's argument index. No expression evaluation is needed.
func Signatures(text string, offset int, context Context) *SignatureHelp {
	if offset < 0 || offset > len(text) || len(text) > 2<<20 || !utf8.ValidString(text) || offset < len(text) && !utf8.RuneStart(text[offset]) {
		return nil
	}
	tokens, _ := lex(text, context.Engine)
	frames := []callFrame{}
	before := []token{}
	for _, t := range tokens {
		if t.start >= offset {
			break
		}
		if t.kind == commentToken {
			if offset < t.end || offset == t.end && t.openEnd {
				return nil
			}
			continue
		}
		if punct(t, ";") {
			frames = nil
			before = nil
			continue
		}
		if punct(t, "(") || punct(t, "[") {
			if len(frames) >= 512 {
				return nil
			}
			frame := callFrame{open: t.start, delimiter: t.value}
			if punct(t, "(") && len(before) > 0 {
				last := before[len(before)-1]
				if functionName(last) {
					frame.name = last
					if len(before) >= 3 && punct(before[len(before)-2], ".") && identifier(before[len(before)-3]) {
						frame.schema = before[len(before)-3]
						if len(frame.schema.value) > 1024 {
							return nil
						}
					}
				}
			}
			frames = append(frames, frame)
		} else if punct(t, ")") || punct(t, "]") {
			if len(frames) > 0 {
				last := frames[len(frames)-1]
				if last.delimiter == "(" && punct(t, ")") || last.delimiter == "[" && punct(t, "]") {
					frames = frames[:len(frames)-1]
				}
			}
		} else if len(frames) > 0 && (punct(t, ",") || substringSeparator(t, frames[len(frames)-1])) {
			i := len(frames) - 1
			if len(frames[i].arguments) >= 1024 {
				return nil
			}
			frames[i].arguments = append(frames[i].arguments, frames[i].argument)
			frames[i].argument = nil
		} else if len(frames) > 0 {
			i := len(frames) - 1
			frames[i].argument = append(frames[i].argument, t)
		}
		before = append(before, t)
	}
	for i := len(frames) - 1; i >= 0; i-- {
		call := frames[i]
		if call.name.value == "" {
			continue
		}
		candidates := functionSignatures(call.name, call.schema, context)
		if len(candidates) == 0 {
			return nil
		}
		args := append(call.arguments, call.argument)
		result := &SignatureHelp{CallStart: call.open, Signatures: []Signature{}}
		best := int(^uint(0) >> 1)
		seen := map[string]bool{}
		for _, candidate := range candidates {
			active, score := activeParameter(candidate, args, context.Engine)
			rendered := renderSignature(call.name, call.schema, candidate, context.Engine)
			if len(rendered.Label) > 8192 || seen[rendered.Label] {
				continue
			}
			seen[rendered.Label] = true
			rendered.ActiveParameter = active
			if score < best {
				best = score
				result.ActiveSignature = len(result.Signatures)
			}
			result.Signatures = append(result.Signatures, rendered)
			if len(result.Signatures) >= 32 {
				break
			}
		}
		if len(result.Signatures) > 0 {
			return result
		}
		return nil
	}
	return nil
}

func substringSeparator(t token, frame callFrame) bool {
	return frame.schema.value == "" && frame.name.kind == wordToken && strings.EqualFold(frame.name.value, "SUBSTRING") &&
		(word(t, "FROM") && len(frame.arguments) == 0 || word(t, "FOR") && len(frame.arguments) == 1)
}

func functionName(t token) bool {
	if len(t.value) > 1024 {
		return false
	}
	if t.kind == quotedToken {
		return true
	}
	if t.kind != wordToken || !identifier(t) || t.value == "" || t.value[0] >= '0' && t.value[0] <= '9' {
		return false
	}
	// SQL clauses followed by a grouping parenthesis are not function calls.
	for _, name := range []string{"SELECT", "FROM", "WHERE", "JOIN", "ON", "USING", "IN", "EXISTS", "AS", "WITH", "VALUES", "OVER", "PARTITION", "FILTER", "ORDER", "GROUP", "HAVING", "WHEN", "THEN", "ELSE", "CASE", "DISTINCT", "ALL", "ANY", "SOME", "ARRAY", "ROW"} {
		if word(t, name) {
			return false
		}
	}
	return true
}

func functionSignatures(name, schema token, context Context) []FunctionSignature {
	values := []FunctionSignature{}
	catalogMatch := false
	for _, entry := range context.Catalog {
		if entry.Kind != "function" || !identifierEqual(name, entry.Name, context.Engine) || schema.value != "" && !identifierEqual(schema, entry.Schema, context.Engine) {
			continue
		}
		catalogMatch = true
		for _, signature := range entry.Signatures {
			if signature.ReturnType == "" || len(signature.ReturnType) > 4096 || len(signature.Parameters) > 256 {
				continue
			}
			valid := true
			for _, parameter := range signature.Parameters {
				valid = valid && len(parameter.Name) <= 1024 && parameter.Type != "" && len(parameter.Type) <= 1024 && parameter.Position >= 0 && parameter.Position <= 256
			}
			if !valid {
				continue
			}
			copy := signature
			copy.Parameters = append([]FunctionParameter{}, signature.Parameters...)
			sort.SliceStable(copy.Parameters, func(i, j int) bool { return copy.Parameters[i].Position < copy.Parameters[j].Position })
			values = append(values, copy)
			if len(values) >= 32 {
				return values
			}
		}
	}
	// An explicitly qualified user function must never acquire a built-in's
	// signature just because its name has the same spelling.
	builtinSchema := context.Engine == "cassandra" && identifierEqual(schema, "system", context.Engine) || context.Engine != "mysql" && context.Engine != "cassandra" && identifierEqual(schema, "pg_catalog", context.Engine)
	if schema.value == "" && !catalogMatch || builtinSchema {
		if name.kind == wordToken || context.Engine == "mysql" || name.value == strings.ToLower(name.value) {
			values = append(values, builtinSignatures(strings.ToUpper(name.value), context.Engine)...)
		}
	}
	return values
}

func argumentName(tokens []token, engine string) (token, bool) {
	if engine == "mysql" {
		return token{}, false
	}
	if len(tokens) >= 3 && len(tokens[0].value) <= 1024 && identifier(tokens[0]) && (punct(tokens[1], "=") && punct(tokens[2], ">") || punct(tokens[1], ":") && punct(tokens[2], "=")) {
		return tokens[0], true
	}
	return token{}, false
}

func activeParameter(signature FunctionSignature, arguments [][]token, engine string) (int, int) {
	count := len(signature.Parameters)
	index := len(arguments) - 1
	supplied := len(arguments)
	if supplied == 1 && len(arguments[0]) == 0 {
		supplied = 0
	}
	score := 0
	for _, argument := range arguments {
		if name, named := argumentName(argument, engine); named {
			found := false
			for _, parameter := range signature.Parameters {
				found = found || identifierEqual(name, parameter.Name, engine)
			}
			if !found {
				score += 1000
			}
		}
	}
	if name, named := argumentName(arguments[len(arguments)-1], engine); named {
		index = -1
		for i, parameter := range signature.Parameters {
			if identifierEqual(name, parameter.Name, engine) {
				index = i
				break
			}
		}
	}
	variadic := count > 0 && signature.Parameters[count-1].Variadic
	if index >= count {
		if variadic {
			index = count - 1
		} else {
			index = -1
			score += 100
		}
	}
	if count == 0 {
		index = -1
		if supplied == 0 {
			return index, score - 100
		}
	}
	required := 0
	for _, parameter := range signature.Parameters {
		if !parameter.Optional && !parameter.Variadic {
			required++
		}
	}
	if supplied > count && !variadic {
		score += 1000 + (supplied-count)*10
	}
	if supplied < required {
		score += (required - supplied) * 10
	}
	if count > supplied {
		score += count - supplied
	}
	return index, score
}

func renderSignature(name, schema token, signature FunctionSignature, engine string) Signature {
	label := identifierName(name, engine)
	if name.kind == wordToken && schema.value == "" {
		label = strings.ToUpper(name.value)
	}
	if name.kind == quotedToken {
		label = quoteIdentifier(name.value, engine)
	}
	if schema.value != "" {
		label = quoteIdentifier(identifierName(schema, engine), engine) + "." + label
	}
	var text strings.Builder
	text.WriteString(label + "(")
	result := Signature{ActiveParameter: -1}
	for i, parameter := range signature.Parameters {
		if i > 0 {
			text.WriteString(", ")
		}
		start := text.Len()
		if parameter.Variadic {
			text.WriteString("VARIADIC ")
		}
		name := parameter.Name
		if name == "" {
			name = fmt.Sprint("arg", i+1)
		}
		text.WriteString(name + ": " + parameter.Type)
		if parameter.Optional {
			text.WriteString(" = DEFAULT")
		}
		result.Parameters = append(result.Parameters, ParameterSpan{Start: start, End: text.Len()})
	}
	text.WriteString(") → " + signature.ReturnType)
	result.Label = text.String()
	return result
}
