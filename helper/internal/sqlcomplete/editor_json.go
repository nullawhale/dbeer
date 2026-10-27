package sqlcomplete

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
)

type editorJSONField struct {
	path string
	name string
	span EditorSpan
}
type editorJSONValue struct {
	path, value string
	span        EditorSpan
}
type editorJSONScanner struct {
	text     string
	i, depth int
	result   EditorAnalysis
	fields   []editorJSONField
	values   []editorJSONValue
}

func analyzeJSONEditor(text string, offset int, context Context, result EditorAnalysis) EditorAnalysis {
	if !json.Valid([]byte(text)) || !boundedEditorJSON(text) {
		return result
	}
	s := editorJSONScanner{text: text, result: result}
	s.value("$", nil)
	path, field := "", ""
	for _, f := range s.fields {
		if offset >= f.span.Start && offset <= f.span.End {
			path, field = f.path, f.name
			break
		}
	}
	if path != "" {
		identity := editorJSONFieldIdentity(path)
		for _, f := range s.fields {
			if editorJSONFieldIdentity(f.path) == identity {
				s.result.References = append(s.result.References, f.span)
			}
		}
	}
	// The top-level request identifies one collection; ambiguous duplicate
	// routing keys intentionally receive no catalog navigation.
	collection, database := "", ""
	collectionCount, databaseCount := 0, 0
	selectedValue := ""
	for _, v := range s.values {
		if v.path == "$.collection" {
			collection = v.value
			collectionCount++
		}
		if v.path == "$.database" {
			database = v.value
			databaseCount++
		}
		if offset >= v.span.Start && offset <= v.span.End {
			selectedValue = v.value
		}
	}
	if collectionCount == 1 && databaseCount <= 1 {
		for _, relation := range context.Catalog {
			if relation.Name != collection || database != "" && relation.Schema != database {
				continue
			}
			detail := ""
			if selectedValue == collection {
				detail = "MongoDB collection"
			} else {
				candidate := field
				for _, prefix := range []string{"$.find.", "$.projection.", "$.sort."} {
					if strings.HasPrefix(path, prefix) {
						candidate = strings.TrimPrefix(path, prefix)
						break
					}
				}
				if strings.HasPrefix(selectedValue, "$") {
					candidate = strings.TrimPrefix(selectedValue, "$")
				}
				for _, column := range relation.Columns {
					if column == candidate {
						columnType := "Type unavailable"
						if value := relation.ColumnTypes[column]; value != "" {
							columnType = value
						}
						detail = "Sampled field " + column + " · " + columnType + " · Samples are not a schema"
						break
					}
				}
			}
			if detail != "" {
				s.result.Definitions = append(s.result.Definitions, EditorDefinition{Schema: relation.Schema, Name: relation.Name, Kind: relation.Kind, Detail: detail})
			}
		}
	}
	sort.SliceStable(s.result.Symbols, func(i, j int) bool {
		a, b := s.result.Symbols[i].Range, s.result.Symbols[j].Range
		if a.Start == b.Start {
			return a.End > b.End
		}
		return a.Start < b.Start
	})
	return s.result
}

// These request sections name fields of the same collection. Keep nested field
// paths distinct; operator/array contexts retain their literal JSON identity
// instead of inferring an aggregation expression or document schema.
func editorJSONFieldIdentity(path string) string {
	for _, prefix := range []string{"$.find.", "$.projection.", "$.sort."} {
		if strings.HasPrefix(path, prefix) {
			field := strings.TrimPrefix(path, prefix)
			for _, segment := range strings.Split(field, ".") {
				if strings.HasPrefix(segment, "$") || strings.ContainsAny(segment, "[]") {
					return "json:" + path
				}
			}
			return "field:" + field
		}
	}
	return "json:" + path
}
func (s *editorJSONScanner) space() {
	for s.i < len(s.text) && strings.ContainsRune(" \r\n\t", rune(s.text[s.i])) {
		s.i++
	}
}
func (s *editorJSONScanner) stringValue() (string, EditorSpan) {
	start := s.i
	s.i++
	for s.i < len(s.text) {
		if s.text[s.i] == '\\' {
			s.i += 2
			continue
		}
		if s.text[s.i] == '"' {
			s.i++
			break
		}
		s.i++
	}
	var value string
	_ = json.Unmarshal([]byte(s.text[start:s.i]), &value)
	return value, EditorSpan{start, s.i}
}
func (s *editorJSONScanner) value(path string, key *EditorSpan) {
	s.space()
	if len(path) > 1024 {
		path = path[:1024]
	}
	if s.i >= len(s.text) || s.depth >= 256 {
		return
	}
	start := s.i
	c := s.text[s.i]
	if c == '{' || c == '[' {
		s.depth++
		s.i++
		s.space()
		index := 0
		for s.i < len(s.text) && s.text[s.i] != '}' && s.text[s.i] != ']' {
			if c == '{' {
				name, span := s.stringValue()
				if len(s.fields) < 8192 && len(path)+len(name) < 1024 {
					s.fields = append(s.fields, editorJSONField{path + "." + name, name, span})
				}
				s.space()
				s.i++
				s.value(path+"."+name, &span)
			} else {
				s.value(fmt.Sprintf("%s[%d]", path, index), nil)
				index++
			}
			s.space()
			if s.i < len(s.text) && s.text[s.i] == ',' {
				s.i++
				s.space()
			} else {
				break
			}
		}
		if s.i < len(s.text) {
			s.i++
		}
		s.depth--
		span := EditorSpan{start, s.i}
		selection := span
		if key != nil {
			selection = *key
		}
		kind := "object"
		if c == '[' {
			kind = "array"
		}
		if len(s.result.Symbols) < 2048 {
			name := path
			if len([]rune(name)) > 100 {
				name = string([]rune(name)[:100]) + "…"
			}
			s.result.Symbols = append(s.result.Symbols, EditorSymbol{Name: name, Kind: kind, Range: span, Selection: selection})
		}
		if strings.ContainsAny(s.text[start:s.i], "\r\n") && len(s.result.Folds) < 8192 {
			s.result.Folds = append(s.result.Folds, span)
		}
	} else if c == '"' {
		value, span := s.stringValue()
		if len(s.values) < 8192 {
			s.values = append(s.values, editorJSONValue{path, value, span})
		}
	} else {
		for s.i < len(s.text) && !strings.ContainsRune(",]} \r\n\t", rune(s.text[s.i])) {
			s.i++
		}
	}
}

// Refuse deeply nested input before the recursive outline parser. The token
// scan is bounded independently of JSON validity and never decodes numbers.
func boundedEditorJSON(text string) bool {
	depth := 0
	for i := 0; i < len(text); i++ {
		if text[i] == '"' {
			i++
			for i < len(text) {
				if text[i] == '\\' {
					i += 2
					continue
				}
				if text[i] == '"' {
					break
				}
				i++
			}
			continue
		}
		if text[i] == '{' || text[i] == '[' {
			depth++
			if depth > 256 {
				return false
			}
		}
		if text[i] == '}' || text[i] == ']' {
			depth--
		}
	}
	return true
}

func formatJSONEditor(text, indent string) (string, error) {
	if !json.Valid([]byte(text)) {
		return "", errors.New("Format requires a complete JSON value.")
	}
	if !boundedEditorJSON(text) {
		return "", errors.New("JSON nesting exceeds the language tool limit.")
	}
	tokens := mongoTokens(text)
	if len(tokens) == 0 {
		return "", errors.New("JSON exceeds the language token limit.")
	}
	var out strings.Builder
	depth := 0
	newline := func() { out.WriteByte('\n'); out.WriteString(strings.Repeat(indent, depth)) }
	for i, t := range tokens {
		if !t.quoted && (t.value == "}" || t.value == "]") {
			depth--
			if i > 0 && (tokens[i-1].quoted || tokens[i-1].value != "{" && tokens[i-1].value != "[") {
				newline()
			}
		}
		out.WriteString(text[t.start:t.end])
		if !t.quoted {
			switch t.value {
			case "{", "[":
				depth++
				if i+1 < len(tokens) && (tokens[i+1].quoted || tokens[i+1].value != "}" && tokens[i+1].value != "]") {
					newline()
				}
			case ",":
				newline()
			case ":":
				out.WriteByte(' ')
			}
		}
		if out.Len() > 2<<20 {
			return "", errors.New("Formatted JSON exceeds the language tool limit.")
		}
	}
	if strings.HasSuffix(text, "\n") {
		out.WriteByte('\n')
	}
	return out.String(), nil
}
