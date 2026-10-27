package sqlcomplete

import (
	"sort"
	"strings"
	"unicode/utf8"
)

type clause uint8

const (
	generalClause clause = iota
	selectClause
	fromClause
	predicateClause
	onClause
	usingClause
	groupClause
	orderClause
	havingClause
	setClause
	returningClause
	limitClause
)

type request struct {
	text       string
	start, end int
	prefix     string
	matcher    nameMatcher
	context    Context
	a          *analysis
	scope      *scope
	before     []token
	clause     clause
	table      bool
	qualified  bool
	items      []Item
	seen       map[string]bool
}

// Complete tolerates unfinished SQL. It never executes SQL or assumes that a
// lexical diagnostic is a server-side syntax error.
func Complete(text string, offset int, context Context) []Item {
	if context.Engine == "mongodb" {
		return mongoComplete(text, offset, context)
	}
	if offset < 0 || offset > len(text) || !utf8.ValidString(text) || offset < len(text) && !utf8.RuneStart(text[offset]) || len(text) > 2<<20 {
		return []Item{}
	}
	tokens, _ := lex(text, context.Engine)
	r := &request{text: text, start: offset, end: offset, context: context, seen: map[string]bool{}, items: []Item{}}
	for _, t := range tokens {
		if (offset > t.start && offset < t.end || offset == t.end && t.openEnd) && (t.kind == commentToken || t.kind == stringToken) {
			return r.items
		}
		if (t.kind == wordToken || t.kind == quotedToken) && offset > t.start && offset <= t.end {
			r.start, r.end = t.start, t.end
			r.prefix = text[t.start:offset]
			if t.kind == quotedToken {
				quote := r.prefix[:min(len(r.prefix), 1)]
				r.prefix = strings.TrimSuffix(strings.TrimPrefix(r.prefix, quote), quote)
				r.prefix = strings.ReplaceAll(r.prefix, quote+quote, quote)
			}
			break
		}
	}
	if len(r.prefix) > 1024 {
		return r.items
	}
	r.matcher = newNameMatcher(r.prefix)
	lo, hi := 0, len(text)
	for _, t := range tokens {
		if t.kind == punctuationToken && t.value == ";" {
			if t.end <= r.start {
				lo = t.end
			} else {
				hi = t.start
				break
			}
		}
	}
	statement := []token{}
	for _, t := range tokens {
		if t.start >= lo && t.end <= hi && t.kind != commentToken {
			statement = append(statement, t)
		}
	}
	r.a, r.scope = analyze(statement, context, lo, hi)
	r.scope = r.scope.at(r.start)
	for i := r.scope.body; i < r.scope.hi; i++ {
		t := statement[i]
		if t.end <= r.start {
			r.before = append(r.before, t)
		}
	}
	r.clause, r.table = r.position()
	r.qualified = len(r.before) >= 2 && punct(r.before[len(r.before)-1], ".")
	if context.Engine == "cassandra" {
		r.cql()
	} else if r.qualified {
		r.members()
	} else {
		r.unqualified()
	}
	sort.SliceStable(r.items, func(i, j int) bool {
		return lessCompletion(r.items[i], r.items[j])
	})
	if len(r.items) > 256 {
		r.items = r.items[:256]
	}
	// Trace only visible candidates, rather than every match in a large catalog.
	for i := range r.items {
		r.items[i].Matches = r.matcher.spans(r.items[i].Label)
	}
	return r.items
}

func (r *request) add(label, insertion, detail string, kind, priority int) {
	if label == "" || len(label) > 1024 || len(insertion) > 4096 || r.seen[insertion] {
		return
	}
	match, ok := r.matcher.match(label)
	if !ok {
		return
	}
	r.seen[insertion] = true
	r.items = append(r.items, Item{Label: label, InsertText: insertion, Detail: detail, Kind: kind, Start: r.start, End: r.end,
		priority: priority, match: match, sortLabel: strings.ToLower(label)})
}

func (r *request) position() (clause, bool) {
	current := generalClause
	depth := 0
	for _, t := range r.before {
		if t.kind == punctuationToken && punct(t, "(") {
			depth++
			continue
		}
		if t.kind == punctuationToken && punct(t, ")") {
			depth--
			continue
		}
		if depth > 0 {
			continue
		}
		switch {
		case word(t, "SELECT"):
			current = selectClause
		case word(t, "FROM"), word(t, "JOIN"), word(t, "UPDATE"), word(t, "INTO"):
			current = fromClause
		case word(t, "WHERE"):
			current = predicateClause
		case word(t, "ON"):
			current = onClause
		case word(t, "USING"):
			current = usingClause
		case word(t, "GROUP"):
			current = groupClause
		case word(t, "ORDER"):
			current = orderClause
		case word(t, "HAVING"):
			current = havingClause
		case word(t, "SET"):
			current = setClause
		case word(t, "RETURNING"):
			current = returningClause
		case word(t, "LIMIT"), word(t, "OFFSET"):
			current = limitClause
		}
	}
	table := false
	if len(r.before) > 0 {
		last := r.before[len(r.before)-1]
		table = word(last, "FROM") || word(last, "JOIN") || word(last, "UPDATE") || word(last, "INTO") || current == fromClause && punct(last, ",")
		if punct(last, ".") {
			table = current == fromClause
		}
	}
	return current, table
}

func (r *request) visible() []source {
	sources := r.scope.visible(r.context.Engine)
	if r.clause == onClause || r.clause == usingClause || r.table {
		result := []source{}
		for _, src := range sources {
			if src.start < r.start {
				result = append(result, src)
			}
		}
		return result
	}
	return sources
}

func (r *request) members() {
	qualifier := r.before[len(r.before)-2]
	var schema *token
	if len(r.before) >= 4 && punct(r.before[len(r.before)-3], ".") {
		schema = &r.before[len(r.before)-4]
	}
	if !r.table {
		matched := false
		for _, src := range r.visible() {
			if identifierTokenEqual(qualifier, src.name, r.context.Engine) && (schema == nil || src.schema.value != "" && identifierTokenEqual(*schema, src.schema, r.context.Engine)) {
				matched = true
				for _, column := range src.columns {
					r.add(column, quoteIdentifier(column, r.context.Engine), sourceDetail(src), 5, 0)
				}
			}
		}
		if matched || schema != nil {
			return
		}
	}
	if schema != nil {
		return
	}
	if r.table {
		r.joinTables(&qualifier)
	}
	for _, entry := range r.context.Catalog {
		if !identifierEqual(qualifier, entry.Schema, r.context.Engine) {
			continue
		}
		if r.table && entry.Kind == "function" || !r.table && entry.Kind != "function" {
			continue
		}
		kind := 7
		if entry.Kind == "function" {
			kind = 3
		}
		r.add(entry.Name, quoteIdentifier(entry.Name, r.context.Engine), entry.Kind+" · "+entry.Schema, kind, 1)
	}
}

func (r *request) unqualified() {
	last := token{}
	if len(r.before) > 0 {
		last = r.before[len(r.before)-1]
	}
	for _, rule := range []struct {
		trigger string
		words   []string
	}{
		{"ORDER", []string{"BY"}}, {"GROUP", []string{"BY"}}, {"PARTITION", []string{"BY"}},
		{"LEFT", []string{"JOIN", "OUTER"}}, {"RIGHT", []string{"JOIN", "OUTER"}}, {"INNER", []string{"JOIN"}}, {"OUTER", []string{"JOIN"}}, {"FULL", []string{"JOIN", "OUTER"}}, {"CROSS", []string{"JOIN"}},
		{"INSERT", []string{"INTO"}}, {"DELETE", []string{"FROM"}}, {"UNION", []string{"SELECT", "ALL"}}, {"IS", []string{"NULL", "NOT", "TRUE", "FALSE"}},
	} {
		if word(last, rule.trigger) {
			for _, name := range rule.words {
				r.add(name, name, "Keyword", 14, 3)
			}
			return
		}
	}
	if r.table {
		r.joinTables(nil)
		// Local CTEs shadow catalog relations and inherited CTEs by name.
		shadowed := []token{}
		for i := len(r.scope.ctes) - 1; i >= 0; i-- {
			cte := r.scope.ctes[i]
			exists := false
			for _, name := range shadowed {
				exists = exists || identifierTokenEqual(name, cte.name, r.context.Engine)
			}
			if exists {
				continue
			}
			shadowed = append(shadowed, cte.name)
			r.add(cte.name.value, quoteIdentifier(identifierName(cte.name, r.context.Engine), r.context.Engine), "CTE", 7, 0)
		}
		for _, entry := range r.context.Catalog {
			if entry.Kind == "function" {
				continue
			}
			// Catalog names are schema-qualified, so remain usable even when a
			// CTE has the same name.
			r.add(entry.Name, qualifiedName(entry, r.context.Engine), entry.Kind+" · "+entry.Schema, 7, 1)
			if entry.Schema != "" {
				r.add(entry.Schema, quoteIdentifier(entry.Schema, r.context.Engine), "Schema", 9, 2)
			}
		}
		return
	}
	if r.clause == fromClause {
		if len(r.scope.sources) > 1 {
			r.add("ON", "ON", "Keyword", 14, 3)
			r.add("USING", "USING", "Keyword", 14, 3)
		}
		for _, name := range []string{"JOIN", "LEFT JOIN", "INNER JOIN", "WHERE", "GROUP BY", "ORDER BY", "LIMIT"} {
			r.add(name, name, "Keyword", 14, 3)
		}
		return
	}
	if r.clause == limitClause {
		r.add("OFFSET", "OFFSET", "Keyword", 14, 3)
		return
	}
	sources := r.visible()
	counts := map[string]int{}
	for _, src := range sources {
		local := map[string]bool{}
		for _, column := range src.columns {
			if !local[column] {
				counts[column]++
				local[column] = true
			}
		}
	}
	if r.clause == usingClause && len(sources) >= 2 {
		right := sources[len(sources)-1]
		for _, column := range right.columns {
			if counts[column] >= 2 {
				r.add(column, quoteIdentifier(column, r.context.Engine), "Shared JOIN column", 5, 0)
			}
		}
		return
	}
	for _, src := range sources {
		for _, column := range src.columns {
			insertion := quoteIdentifier(column, r.context.Engine)
			if counts[column] > 1 && src.name.value != "" {
				insertion = quoteIdentifier(identifierName(src.name, r.context.Engine), r.context.Engine) + "." + insertion
			}
			r.add(column, insertion, sourceDetail(src), 5, 0)
		}
		if src.name.value != "" {
			r.add(src.name.value, quoteIdentifier(identifierName(src.name, r.context.Engine), r.context.Engine), "Alias · "+sourceDetail(src), 6, 1)
		}
	}
	if r.clause == orderClause || r.clause == groupClause || r.clause == havingClause && r.context.Engine == "mysql" {
		for _, alias := range r.scope.aliases {
			r.add(alias, quoteIdentifier(alias, r.context.Engine), "SELECT alias", 5, 0)
		}
	}
	if r.clause == onClause {
		r.joinConditions()
	}
	if r.clause != orderClause && r.clause != groupClause && r.clause != setClause {
		for _, name := range functions(r.context.Engine) {
			r.add(name, name, "Function · "+r.context.Engine, 3, 2)
		}
		for _, entry := range r.context.Catalog {
			if entry.Kind == "function" {
				r.add(entry.Name, qualifiedName(entry, r.context.Engine), "Function · "+entry.Schema, 3, 2)
			}
		}
	}
	words := strings.Fields("CASE WHEN THEN ELSE END NULL TRUE FALSE DISTINCT FROM WHERE GROUP ORDER LIMIT")
	switch r.clause {
	case predicateClause, onClause, havingClause:
		words = strings.Fields("AND OR NOT NULL IS IN EXISTS BETWEEN LIKE TRUE FALSE CASE")
	case orderClause:
		words = strings.Fields("ASC DESC NULLS FIRST LAST LIMIT OFFSET")
	case groupClause:
		words = strings.Fields("HAVING ORDER LIMIT")
	case setClause:
		words = strings.Fields("DEFAULT NULL WHERE")
	case generalClause:
		words = keywords
	}
	for _, name := range words {
		r.add(name, name, "Keyword", 14, 3)
	}
}
