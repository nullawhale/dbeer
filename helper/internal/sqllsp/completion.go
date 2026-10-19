package sqllsp

import (
	"sort"
	"strings"
)

type textEdit struct {
	Range   textRange `json:"range"`
	NewText string    `json:"newText"`
}
type completionItem struct {
	Label      string   `json:"label"`
	InsertText string   `json:"insertText"`
	Kind       int      `json:"kind"`
	Detail     string   `json:"detail"`
	TextEdit   textEdit `json:"textEdit"`
}
type tableReference struct {
	name  token
	entry catalogEntry
}

var keywords = strings.Fields("SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER FULL CROSS ON AS AND OR NOT NULL IS IN EXISTS BETWEEN LIKE DISTINCT GROUP BY ORDER ASC DESC LIMIT OFFSET HAVING UNION ALL INSERT INTO VALUES UPDATE SET DELETE RETURNING WITH CREATE ALTER DROP TABLE VIEW CASE WHEN THEN ELSE END OVER PARTITION NULLS FIRST LAST TRUE FALSE")

func complete(text string, offset int, context configuration) []completionItem {
	tokens, _ := lex(text, context.Engine)
	start, end, prefix := offset, offset, ""
	for _, t := range tokens {
		if offset > t.start && offset < t.end || offset == t.end && t.openEnd && (t.kind == commentToken || t.kind == stringToken) {
			if t.kind == commentToken || t.kind == stringToken {
				return []completionItem{}
			}
		}
		if (t.kind == wordToken || t.kind == quotedToken) && offset >= t.start && offset <= t.end {
			start, end = t.start, t.end
			prefix = text[t.start:offset]
			if t.kind == quotedToken {
				quote := prefix[:min(len(prefix), 1)]
				prefix = strings.TrimPrefix(prefix, quote)
				prefix = strings.TrimSuffix(prefix, quote)
				prefix = strings.ReplaceAll(prefix, quote+quote, quote)
			}
			break
		}
	}
	if len(prefix) > 1024 {
		return []completionItem{}
	}
	// Only the current statement participates in alias and clause lookup.
	statementStart, statementEnd := 0, len(text)
	for _, t := range tokens {
		if t.kind == punctuationToken && t.value == ";" {
			if t.end <= start {
				statementStart = t.end
			} else {
				statementEnd = t.start
				break
			}
		}
	}
	statement, before := []token{}, []token{}
	for _, t := range tokens {
		if t.start < statementStart || t.end > statementEnd || t.kind == commentToken || t.kind == stringToken {
			continue
		}
		statement = append(statement, t)
		if t.end <= start {
			before = append(before, t)
		}
	}
	refs := references(statement, context.Catalog, context.Engine)
	items := []completionItem{}
	seen := map[string]bool{}
	rangeValue := textRange{Start: positionAt(text, start), End: positionAt(text, end)}
	add := func(label, insertion, detail string, kind int) {
		if label == "" || len(label) > 1024 || len(insertion) > 4096 {
			return
		}
		if !strings.HasPrefix(strings.ToLower(label), strings.ToLower(prefix)) || seen[insertion] {
			return
		}
		seen[insertion] = true
		items = append(items, completionItem{Label: label, InsertText: insertion, Kind: kind, Detail: detail, TextEdit: textEdit{Range: rangeValue, NewText: insertion}})
	}
	addColumn := func(name, detail string) { add(name, quoteIdentifier(name, context.Engine), detail, 5) }
	qualified := len(before) >= 2 && before[len(before)-1].value == "."
	if qualified {
		qualifier := before[len(before)-2]
		var schema *token
		if len(before) >= 4 && before[len(before)-3].value == "." {
			schema = &before[len(before)-4]
		}
		matchedReference := false
		for _, ref := range refs {
			if schema == nil && identifierTokenEqual(qualifier, ref.name, context.Engine) {
				matchedReference = true
				for _, column := range ref.entry.Columns {
					addColumn(column, ref.entry.Schema+"."+ref.entry.Name)
				}
			}
		}
		for _, entry := range context.Catalog {
			if !matchedReference && identifierEqual(qualifier, entry.Name, context.Engine) && (schema == nil || identifierEqual(*schema, entry.Schema, context.Engine)) {
				for _, column := range entry.Columns {
					addColumn(column, entry.Schema+"."+entry.Name)
				}
			}
			if !matchedReference && schema == nil && identifierEqual(qualifier, entry.Schema, context.Engine) {
				add(entry.Name, quoteIdentifier(entry.Name, context.Engine), entry.Kind, completionKind(entry.Kind))
			}
		}
	} else {
		last := ""
		if len(before) > 0 && before[len(before)-1].kind == wordToken {
			last = strings.ToUpper(before[len(before)-1].value)
		}
		tableContext := last == "FROM" || last == "JOIN" || last == "UPDATE" || last == "INTO"
		if !tableContext {
			for _, word := range contextKeywords(last) {
				add(word, word, "Keyword", 14)
			}
			functions := strings.Fields("COUNT SUM AVG MIN MAX COALESCE NULLIF LOWER UPPER LENGTH SUBSTRING ROUND ABS")
			if context.Engine == "mysql" {
				functions = append(functions, strings.Fields("IFNULL CONCAT NOW DATE_FORMAT JSON_EXTRACT GROUP_CONCAT")...)
			} else {
				functions = append(functions, strings.Fields("NOW CURRENT_DATE DATE_TRUNC STRING_AGG ARRAY_AGG JSONB_BUILD_OBJECT GENERATE_SERIES")...)
			}
			for _, name := range functions {
				add(name, name, "Function · "+context.Engine, 3)
			}
			for _, ref := range refs {
				insertion := ref.name.value
				if ref.name.kind == quotedToken {
					insertion = quoteIdentifier(insertion, context.Engine)
				}
				add(ref.name.value, insertion, "Alias · "+ref.entry.Name, 6)
				for _, column := range ref.entry.Columns {
					addColumn(column, ref.entry.Schema+"."+ref.entry.Name)
				}
			}
		}
		for _, entry := range context.Catalog {
			if tableContext && entry.Kind == "function" {
				continue
			}
			insertion := quoteIdentifier(entry.Name, context.Engine)
			if entry.Schema != "" {
				insertion = quoteIdentifier(entry.Schema, context.Engine) + "." + insertion
			}
			add(entry.Name, insertion, entry.Kind+" · "+entry.Schema, completionKind(entry.Kind))
			if entry.Schema != "" {
				add(entry.Schema, quoteIdentifier(entry.Schema, context.Engine), "Schema", 9)
			}
		}
	}
	sort.SliceStable(items, func(i, j int) bool { return strings.ToLower(items[i].Label) < strings.ToLower(items[j].Label) })
	if len(items) > 256 {
		items = items[:256]
	}
	return items
}

func contextKeywords(last string) []string {
	switch last {
	case "ORDER", "GROUP", "PARTITION":
		return []string{"BY"}
	case "LEFT", "RIGHT", "INNER", "CROSS", "FULL":
		return []string{"JOIN", "OUTER"}
	case "INSERT":
		return []string{"INTO"}
	case "DELETE":
		return []string{"FROM"}
	case "IS":
		return []string{"NULL", "NOT", "TRUE", "FALSE"}
	case "UNION":
		return []string{"SELECT", "ALL"}
	default:
		return keywords
	}
}
func completionKind(kind string) int {
	if kind == "function" {
		return 3
	}
	return 7
}
func quoteIdentifier(name, engine string) string {
	quote := "\""
	if engine == "mysql" {
		quote = "`"
	}
	return quote + strings.ReplaceAll(name, quote, quote+quote) + quote
}
func references(tokens []token, catalog []catalogEntry, engine string) []tableReference {
	refs := []tableReference{}
	inFrom := false
	examined := 0
	for i := 0; i < len(tokens); i++ {
		word := strings.ToUpper(tokens[i].value)
		keyword := tokens[i].kind == wordToken
		trigger := keyword && (word == "FROM" || word == "JOIN" || word == "UPDATE" || word == "INTO") || inFrom && tokens[i].kind == punctuationToken && word == ","
		if keyword && (word == "WHERE" || word == "GROUP" || word == "ORDER" || word == "SET") || word == ";" {
			inFrom = false
		}
		if !trigger {
			continue
		}
		examined++
		if examined > 256 {
			break
		}
		inFrom = word == "FROM" || word == "JOIN" || inFrom
		j := i + 1
		if j >= len(tokens) || tokens[j].kind != wordToken && tokens[j].kind != quotedToken {
			continue
		}
		name := tokens[j]
		schema := token{}
		if j+2 < len(tokens) && tokens[j+1].value == "." && (tokens[j+2].kind == wordToken || tokens[j+2].kind == quotedToken) {
			schema = name
			name = tokens[j+2]
			j += 2
		}
		aliasIndex := j + 1
		if aliasIndex < len(tokens) && tokens[aliasIndex].kind == wordToken && strings.EqualFold(tokens[aliasIndex].value, "AS") {
			aliasIndex++
		}
		var alias *token
		if aliasIndex < len(tokens) && (tokens[aliasIndex].kind == quotedToken || tokens[aliasIndex].kind == wordToken && !isKeyword(tokens[aliasIndex].value)) {
			alias = &tokens[aliasIndex]
		}
		for _, entry := range catalog {
			if entry.Kind == "function" || !identifierEqual(name, entry.Name, engine) || schema.value != "" && !identifierEqual(schema, entry.Schema, engine) {
				continue
			}
			refs = append(refs, tableReference{name: name, entry: entry})
			if alias != nil {
				refs = append(refs, tableReference{name: *alias, entry: entry})
			}
			if len(refs) >= 256 {
				return refs
			}
		}
	}
	return refs
}
func isKeyword(word string) bool {
	for _, k := range keywords {
		if strings.EqualFold(k, word) {
			return true
		}
	}
	return false
}
