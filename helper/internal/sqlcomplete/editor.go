package sqlcomplete

import (
	"errors"
	"sort"
	"strings"
	"unicode/utf8"
)

// Editor tools keep source coordinates in UTF-8 bytes. The LSP boundary converts
// them to UTF-16. They consume only the current document and a catalog snapshot.
type EditorSpan struct{ Start, End int }
type EditorSymbol struct {
	Name, Kind       string
	Range, Selection EditorSpan
}
type EditorDefinition struct {
	Range                      *EditorSpan
	Schema, Name, Kind, Detail string
}
type EditorAnalysis struct {
	Symbols     []EditorSymbol
	Folds       []EditorSpan
	References  []EditorSpan
	Definitions []EditorDefinition
}
type FormatOptions struct {
	InsertSpaces bool
	TabSize      int
	KeywordCase  string
}

func FormatEditor(text, engine string, options FormatOptions) (string, error) {
	if len(text) > 2<<20 || !utf8.ValidString(text) {
		return "", errors.New("Document exceeds the language tool limit.")
	}
	width := options.TabSize
	if width < 1 || width > 8 {
		width = 4
	}
	indent := "\t"
	if options.InsertSpaces {
		indent = strings.Repeat(" ", width)
	}
	if engine == "mongodb" {
		return formatJSONEditor(text, indent)
	}
	if engine != "postgresql" && engine != "mysql" && engine != "cassandra" {
		return "", errors.New("Unsupported editor language.")
	}
	tokens, diagnostics := lex(text, engine)
	if len(diagnostics) > 0 {
		return "", errors.New("Format requires closed strings, comments and balanced delimiters.")
	}
	if len(tokens) >= 200000 {
		return "", errors.New("Document exceeds the language token limit.")
	}
	if len(tokens) == 0 {
		return text, nil
	}
	// Stored routines and custom delimiter scripts are opaque: changing their
	// internal whitespace can change client syntax or procedural statement scope.
	// Preserve their bytes, including neighboring statements, rather than guess.
	for i, t := range tokens {
		if word(t, "DELIMITER") {
			return "", errors.New("Formatting custom DELIMITER scripts is not supported; the source was preserved.")
		}
		if word(t, "CREATE") {
			for j := i + 1; j < len(tokens) && j < i+8; j++ {
				if word(tokens[j], "FUNCTION") || word(tokens[j], "PROCEDURE") || word(tokens[j], "TRIGGER") {
					return "", errors.New("Formatting routine definitions is not supported; the source was preserved.")
				}
				if punct(tokens[j], ";") {
					break
				}
			}
		}
	}
	var out strings.Builder
	depth := 0
	for i, t := range tokens {
		if punct(t, ")") || punct(t, "]") || punct(t, "}") {
			depth = max(0, depth-1)
		}
		if i > 0 {
			p := tokens[i-1]
			gap := text[p.end:t.start]
			newline := false
			if p.kind == commentToken && (strings.HasPrefix(text[p.start:p.end], "--") || strings.HasPrefix(text[p.start:p.end], "//") || strings.HasPrefix(text[p.start:p.end], "#")) {
				newline = true
			}
			if punct(p, ";") || punct(p, ",") {
				newline = true
			}
			if t.kind == wordToken && (word(t, "FROM") || word(t, "WHERE") || word(t, "GROUP") || word(t, "ORDER") || word(t, "HAVING") || word(t, "LIMIT") || word(t, "RETURNING") || word(t, "VALUES") || word(t, "SET") || word(t, "UNION") || word(t, "JOIN")) {
				newline = true
			}
			if t.kind == commentToken && strings.ContainsAny(gap, "\r\n") {
				newline = true
			}
			if newline {
				out.WriteByte('\n')
				out.WriteString(strings.Repeat(indent, min(depth, 32)))
			} else if gap != "" {
				out.WriteByte(' ')
			}
		}
		raw := text[t.start:t.end]
		if editorFormattingKeyword(tokens, i) {
			if options.KeywordCase == "upper" {
				raw = strings.ToUpper(raw)
			}
			if options.KeywordCase == "lower" {
				raw = strings.ToLower(raw)
			}
		}
		out.WriteString(raw)
		if out.Len() > 2<<20 {
			return "", errors.New("Formatted document exceeds the language tool limit.")
		}
		if punct(t, "(") || punct(t, "[") || punct(t, "{") {
			depth++
		}
	}
	if strings.HasSuffix(text, "\n") {
		out.WriteByte('\n')
	}
	result := out.String()
	// An independent lex pass guards against accidental token merges, notably
	// PostgreSQL string concatenation and comments. Only case of keywords differs.
	next, ds := lex(result, engine)
	if len(ds) > 0 || len(next) != len(tokens) {
		return "", errors.New("This fragment cannot be formatted safely.")
	}
	for i, t := range tokens {
		a, b := text[t.start:t.end], result[next[i].start:next[i].end]
		if a != b && !(editorFormattingKeyword(tokens, i) && strings.EqualFold(a, b)) {
			return "", errors.New("This fragment cannot be formatted safely.")
		}
	}
	// PostgreSQL concatenates adjacent string literals only across a newline.
	for i := 1; i < len(tokens); i++ {
		if tokens[i-1].kind == stringToken && tokens[i].kind == stringToken && strings.ContainsAny(text[tokens[i-1].end:tokens[i].start], "\r\n") != strings.ContainsAny(result[next[i-1].end:next[i].start], "\r\n") {
			return "", errors.New("This fragment contains newline-sensitive adjacent strings.")
		}
	}
	return result, nil
}

// Completion's keyword list includes contextual words that are valid object
// names. Preserve their spelling, qualified names, call names and declaration
// positions rather than applying case preferences to identifiers. Ambiguous
// join/window modifiers remain as typed until the formatter has a full grammar.
func editorFormattingKeyword(tokens []token, index int) bool {
	t := tokens[index]
	if t.kind != wordToken || !isKeyword(t.value) || identifier(t) {
		return false
	}
	for _, ambiguous := range strings.Fields("LEFT RIGHT INNER OUTER FULL CROSS NATURAL OVER PARTITION LATERAL WINDOW FETCH OFFSET VIEW RETURNING EXCEPT INTERSECT") {
		if word(t, ambiguous) {
			return false
		}
	}
	if index > 0 {
		previous := tokens[index-1]
		if punct(previous, ".") {
			return false
		}
		for _, declaration := range strings.Fields("FROM JOIN UPDATE INTO TABLE VIEW AS") {
			if word(previous, declaration) {
				return false
			}
		}
	}
	if index+1 < len(tokens) && (punct(tokens[index+1], ".") || punct(tokens[index+1], "(")) {
		return false
	}
	return true
}

func AnalyzeEditor(text string, offset int, context Context) EditorAnalysis {
	result := EditorAnalysis{Symbols: []EditorSymbol{}, Folds: []EditorSpan{}, References: []EditorSpan{}, Definitions: []EditorDefinition{}}
	if len(text) > 2<<20 || !utf8.ValidString(text) {
		return result
	}
	if context.Engine == "mongodb" {
		return analyzeJSONEditor(text, offset, context, result)
	}
	all, _ := lex(text, context.Engine)
	opaque := false
	for i, t := range all {
		if context.Engine == "mysql" && word(t, "DELIMITER") {
			opaque = true
		}
		if context.Engine == "postgresql" && word(t, "BEGIN") && i+1 < len(all) && word(all[i+1], "ATOMIC") {
			opaque = true
		}
	}
	tokens := make([]token, 0, len(all))
	start := 0
	addStatement := func(end int) {
		if start >= end || len(result.Symbols) >= 2048 {
			return
		}
		first := all[start]
		last := all[end-1]
		name := strings.Join(strings.Fields(text[first.start:last.end]), " ")
		if utf8.RuneCountInString(name) > 100 {
			name = string([]rune(name)[:100]) + "…"
		}
		span := EditorSpan{first.start, last.end}
		result.Symbols = append(result.Symbols, EditorSymbol{Name: name, Kind: "statement", Range: span, Selection: EditorSpan{first.start, first.end}})
		if strings.ContainsAny(text[span.Start:span.End], "\r\n") {
			if len(result.Folds) < 8192 {
				result.Folds = append(result.Folds, span)
			}
		}
	}
	stack := []token{}
	batch := false
	for i, t := range all {
		if context.Engine == "cassandra" && word(t, "BEGIN") {
			for j := i + 1; j < len(all) && j < i+4; j++ {
				if word(all[j], "BATCH") {
					batch = true
					break
				}
			}
		}
		if batch && word(t, "BATCH") && i > 0 && word(all[i-1], "APPLY") {
			batch = false
		}
		if t.kind == stringToken && strings.HasPrefix(text[t.start:t.end], "$") && strings.ContainsAny(text[t.start:t.end], "\r\n") && len(result.Folds) < 8192 {
			result.Folds = append(result.Folds, EditorSpan{t.start, t.end})
		}
		if t.kind == commentToken {
			if strings.ContainsAny(text[t.start:t.end], "\r\n") {
				if len(result.Folds) < 8192 {
					result.Folds = append(result.Folds, EditorSpan{t.start, t.end})
				}
			}
			continue
		}
		tokens = append(tokens, t)
		if punct(t, "(") || punct(t, "[") || punct(t, "{") {
			stack = append(stack, t)
		}
		if punct(t, ")") || punct(t, "]") || punct(t, "}") {
			if len(stack) > 0 {
				open := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				if strings.ContainsAny(text[open.end:t.start], "\r\n") {
					if len(result.Folds) < 8192 {
						result.Folds = append(result.Folds, EditorSpan{open.start, t.end})
					}
				}
			}
		}
		if punct(t, ";") && len(stack) == 0 && !batch && !opaque {
			addStatement(i + 1)
			start = i + 1
		}
	}
	addStatement(len(all))
	sort.Slice(result.Folds, func(i, j int) bool {
		if result.Folds[i].Start == result.Folds[j].Start {
			return result.Folds[i].End > result.Folds[j].End
		}
		return result.Folds[i].Start < result.Folds[j].Start
	})
	if opaque {
		return result
	}
	// Use the same statement boundaries for outline and scope resolution,
	// including CQL batches whose internal semicolons are not separators.
	lo, hi := 0, len(tokens)
	for _, symbol := range result.Symbols {
		if offset >= symbol.Range.Start && offset <= symbol.Range.End {
			for lo < len(tokens) && tokens[lo].start < symbol.Range.Start {
				lo++
			}
			hi = lo
			for hi < len(tokens) && tokens[hi].end <= symbol.Range.End {
				hi++
			}
			break
		}
	}
	if lo >= hi {
		return result
	}
	local := tokens[lo:hi]
	selected := -1
	for i, t := range local {
		if (identifier(t) || t.kind == wordToken && i+1 < len(local) && punct(local[i+1], "(")) && offset >= t.start && offset <= t.end {
			selected = i
			break
		}
	}
	if selected < 0 {
		return result
	}
	target := local[selected]
	_, root := analyze(local, context, local[0].start, local[len(local)-1].end)
	selectedScope := root.at(target.start)
	if context.Engine == "cassandra" {
		if len(root.sources) == 1 && root.sources[0].schema.value != "" {
			context.Keyspace = identifierName(root.sources[0].schema, "cassandra")
		} else {
			context.Keyspace = cqlDeclarationKeyspace(local, context.Keyspace)
		}
	}
	type identity struct {
		location int
		name     string
		kind     string
		entries  []Relation
		schema   string
	}
	declarationIndexes := make(map[int]int, len(local))
	for index, t := range local {
		declarationIndexes[t.start] = index
	}
	resolve := func(s *scope, t token, index int) identity {
		for _, src := range s.visible(context.Engine) {
			if identifierTokenEqual(t, src.name, context.Engine) {
				if src.name.start == src.start && len(src.entries) == 0 {
					for i := len(s.ctes) - 1; i >= 0; i-- {
						if identifierTokenEqual(t, s.ctes[i].name, context.Engine) {
							return identity{s.ctes[i].name.start, t.value, "cte", nil, ""}
						}
					}
				}
				kind := "alias"
				declaration := declarationIndexes[src.name.start]
				qualifiedRelation := declaration >= 2 && punct(local[declaration-1], ".") && local[declaration-2].start == src.start
				if src.name.start == src.start || qualifiedRelation {
					kind = "relation"
				}
				return identity{src.name.start, src.name.value, kind, src.entries, src.schema.value}
			}
		}
		for i := len(s.ctes) - 1; i >= 0; i-- {
			if identifierTokenEqual(t, s.ctes[i].name, context.Engine) {
				return identity{s.ctes[i].name.start, t.value, "cte", nil, ""}
			}
		}
		return identity{location: -1}
	}
	id := resolve(selectedScope, target, selected)
	if id.location >= 0 {
		span := EditorSpan{id.location, id.location}
		for _, t := range local {
			if t.start == id.location {
				span.End = t.end
				break
			}
		}
		if id.kind != "relation" || len(id.entries) == 0 {
			details := []string{}
			for _, entry := range id.entries {
				details = append(details, entry.Schema+"."+entry.Name+" ("+strings.Join(entry.Columns, ", ")+")")
			}
			result.Definitions = append(result.Definitions, EditorDefinition{Range: &span, Name: id.name, Kind: id.kind, Detail: strings.Join(details, "; ")})
		}
		for i, t := range local {
			if !identifier(t) || !identifierTokenEqual(t, target, context.Engine) {
				continue
			}
			other := resolve(root.at(t.start), t, i)
			if other.location == id.location && len(result.References) < 8192 {
				result.References = append(result.References, EditorSpan{t.start, t.end})
			}
		}
		if id.kind == "relation" {
			for _, entry := range id.entries {
				result.Definitions = append(result.Definitions, EditorDefinition{Schema: entry.Schema, Name: entry.Name, Kind: entry.Kind, Detail: strings.Join(entry.Columns, ", ")})
			}
		}
	} else {
		// Column navigation targets its owning relation. Types are deliberately
		// not guessed: completion metadata currently carries names only.
		qualifier := token{}
		if selected >= 2 && punct(local[selected-1], ".") {
			qualifier = local[selected-2]
		}
		isCall := selected+1 < len(local) && punct(local[selected+1], "(")
		if !isCall {
			for _, src := range selectedScope.visible(context.Engine) {
				if qualifier.value != "" && !identifierTokenEqual(qualifier, src.name, context.Engine) {
					continue
				}
				hasColumn := false
				columnName := identifierName(target, context.Engine)
				for _, column := range src.columns {
					if identifierEqual(target, column, context.Engine) {
						hasColumn = true
						columnName = column
						break
					}
				}
				if !hasColumn {
					continue
				}
				for _, entry := range src.entries {
					detail := "Type unavailable in loaded metadata"
					if value := entry.ColumnTypes[columnName]; value != "" {
						detail = value
					}
					result.Definitions = append(result.Definitions, EditorDefinition{Schema: entry.Schema, Name: entry.Name, Kind: entry.Kind, Detail: "Column " + columnName + " · " + detail})
				}
			}
		}
		// Catalog object references are exact under the dialect's identifier rules.
		// A function name can legitimately be a keyword (e.g. LEFT); the
		// editor selects those before this point as callable identifiers.
		schema := token{}
		if selected >= 2 && punct(local[selected-1], ".") {
			schema = local[selected-2]
		}
		for _, entry := range context.Catalog {
			if context.Engine == "cassandra" && schema.value == "" && context.Keyspace != "" && entry.Schema != context.Keyspace {
				continue
			}
			if identifierEqual(target, entry.Name, context.Engine) && (schema.value == "" || identifierEqual(schema, entry.Schema, context.Engine)) && (!isCall || entry.Kind == "function") {
				detail := strings.Join(entry.Columns, ", ")
				if entry.Kind == "function" {
					signatures := []string{}
					for _, signature := range entry.Signatures {
						values := []string{}
						for _, parameter := range signature.Parameters {
							values = append(values, strings.TrimSpace(parameter.Name+" "+parameter.Type))
						}
						signatures = append(signatures, entry.Name+"("+strings.Join(values, ", ")+") → "+signature.ReturnType)
					}
					detail = strings.Join(signatures, "\n")
				}
				result.Definitions = append(result.Definitions, EditorDefinition{Schema: entry.Schema, Name: entry.Name, Kind: entry.Kind, Detail: detail})
			}
		}
	}
	if len(result.Symbols) > 2048 {
		result.Symbols = result.Symbols[:2048]
	}
	if len(result.Folds) > 8192 {
		result.Folds = result.Folds[:8192]
	}
	return result
}

// SafeEditorRange rejects selections beginning/ending inside literals or
// comments. A partial selection must never reformat the contents of a value.
func SafeEditorRange(text, engine string, start, end int) bool {
	if start < 0 || end < start || end > len(text) {
		return false
	}
	if engine == "mongodb" {
		for i := 0; i < len(text); {
			if text[i] != '"' {
				i++
				continue
			}
			a := i
			i++
			for i < len(text) {
				if text[i] == '\\' {
					i += 2
					continue
				}
				if text[i] == '"' {
					i++
					break
				}
				i++
			}
			if start > a && start < i || end > a && end < i {
				return false
			}
		}
		return true
	}
	tokens, _ := lex(text, engine)
	for _, t := range tokens {
		if start > t.start && start < t.end || end > t.start && end < t.end {
			return false
		}
	}
	return true
}
