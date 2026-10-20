package sqlcomplete

import (
	"fmt"
	"strings"
	"unicode"
)

func keyTarget(key ForeignKey, relation Relation) bool {
	return key.TargetSchema == relation.Schema && key.TargetTable == relation.Name
}

func joinPredicate(key ForeignKey, from, to string, engine string) string {
	return renderJoinPredicate(key, from, to, func(value string) string { return quoteIdentifier(value, engine) })
}

func renderJoinPredicate(key ForeignKey, from, to string, quote func(string) string) string {
	parts := []string{}
	if len(key.Columns) == 0 || len(key.Columns) > 32 {
		return ""
	}
	for _, pair := range key.Columns {
		if pair.Source == "" || pair.Target == "" {
			return ""
		}
		parts = append(parts, quote(from)+"."+quote(pair.Source)+" = "+quote(to)+"."+quote(pair.Target))
	}
	return strings.Join(parts, " AND ")
}

func aliasFor(name string, sources []source) string {
	var base strings.Builder
	beginning := true
	for _, r := range name {
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) {
			beginning = true
			continue
		}
		if beginning {
			base.WriteRune(unicode.ToLower(r))
			beginning = false
		}
	}
	stem := base.String()
	if stem == "" {
		stem = "t"
	}
	// Bound aliases independently of database identifier length limits.
	if len(stem) > 32 {
		stem = "t"
	}
	for n := 1; n < 1000; n++ {
		alias := stem
		if n > 1 {
			alias = fmt.Sprint(stem, n)
		}
		used := false
		for _, src := range sources {
			used = used || strings.EqualFold(src.name.value, alias)
		}
		if !used {
			return alias
		}
	}
	return "joined_table"
}

// joinEdges enumerates both referencing and referenced directions. Foreign-key
// names are descriptive only: they never enter executable SQL.
func joinEdges(left, right Relation, leftAlias, rightAlias, engine string, add func(string, string, string)) {
	for _, key := range left.ForeignKeys {
		if keyTarget(key, right) {
			if predicate := joinPredicate(key, leftAlias, rightAlias, engine); predicate != "" {
				add(predicate, renderJoinPredicate(key, leftAlias, rightAlias, func(value string) string { return value }), key.Name)
			}
		}
	}
	for _, key := range right.ForeignKeys {
		if keyTarget(key, left) {
			if predicate := joinPredicate(key, rightAlias, leftAlias, engine); predicate != "" {
				add(predicate, renderJoinPredicate(key, rightAlias, leftAlias, func(value string) string { return value }), key.Name)
			}
		}
	}
}

func (r *request) joinTables(schema *token) {
	joinIndex := -1
	for i := len(r.before) - 1; i >= 0; i-- {
		if word(r.before[i], "JOIN") {
			joinIndex = i
			break
		}
		if word(r.before[i], "FROM") || clauseBoundary(r.before[i]) {
			return
		}
	}
	if joinIndex < 0 {
		return
	}
	if joinIndex > 0 && (word(r.before[joinIndex-1], "CROSS") || word(r.before[joinIndex-1], "NATURAL")) {
		return
	}
	for i := max(0, joinIndex-3); i < joinIndex; i++ {
		if word(r.before[i], "NATURAL") {
			return
		}
	}
	// Do not duplicate a user-written alias, ON/USING, or an existing suffix.
	for _, t := range r.a.tokens {
		if t.start < r.end || t.start >= r.scope.end {
			continue
		}
		if word(t, "AS") || word(t, "ON") || word(t, "USING") || identifier(t) {
			return
		}
		break
	}
	sources := []source{}
	for _, src := range r.visible() {
		if src.end <= r.before[joinIndex].start {
			sources = append(sources, src)
		}
	}
	for _, entry := range r.context.Catalog {
		if entry.Kind == "function" || schema != nil && !identifierEqual(*schema, entry.Schema, r.context.Engine) {
			continue
		}
		alias := aliasFor(entry.Name, r.scope.visible(r.context.Engine))
		for _, src := range sources {
			for _, left := range src.entries {
				joinEdges(left, entry, identifierName(src.name, r.context.Engine), alias, r.context.Engine, func(predicate, label, key string) {
					name := qualifiedName(entry, r.context.Engine)
					if schema != nil {
						name = quoteIdentifier(entry.Name, r.context.Engine)
					}
					insertion := name + " AS " + quoteIdentifier(alias, r.context.Engine) + " ON " + predicate
					r.add(entry.Name, insertion, "JOIN · "+key+" · "+sourceDetail(src), 15, -1)
				})
			}
		}
	}
}

func (r *request) joinConditions() {
	if len(r.before) == 0 {
		return
	}
	last := r.before[len(r.before)-1]
	if !word(last, "ON") && !word(last, "AND") && !word(last, "OR") {
		return
	}
	sources := r.visible()
	if len(sources) < 2 {
		return
	}
	right := sources[len(sources)-1]
	for _, left := range sources[:len(sources)-1] {
		for _, a := range left.entries {
			for _, b := range right.entries {
				joinEdges(a, b, identifierName(left.name, r.context.Engine), identifierName(right.name, r.context.Engine), r.context.Engine, func(predicate, label, key string) {
					// The label is readable SQL; replacement remains fully quoted.
					r.add(label, predicate, "Foreign key · "+key, 15, -1)
				})
			}
		}
	}
}
