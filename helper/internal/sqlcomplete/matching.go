package sqlcomplete

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// Search is deliberately independent of SQL identifier binding. A fuzzy match
// suggests the catalog's original spelling; it never changes scope resolution.
type matchRank struct {
	tier, penalty int
}

type nameMatcher struct {
	prefix  string
	query   []rune
	compact []rune
}

const maxFuzzyRunes = 64

func newNameMatcher(prefix string) nameMatcher {
	m := nameMatcher{prefix: strings.ToLower(prefix)}
	m.query = []rune(m.prefix)
	for _, r := range m.query {
		if matchWordRune(r) {
			m.compact = append(m.compact, r)
		}
	}
	return m
}

func (m nameMatcher) match(label string) (matchRank, bool) {
	return m.search(label, nil)
}

func (m nameMatcher) spans(label string) []MatchSpan {
	var spans []MatchSpan
	m.search(label, &spans)
	return spans
}

func (m nameMatcher) search(label string, spans *[]MatchSpan) (matchRank, bool) {
	folded := strings.ToLower(label)
	if strings.HasPrefix(folded, m.prefix) {
		if spans != nil && m.prefix != "" {
			end, count := len(label), 0
			for offset := range label {
				if count == len(m.query) {
					end = offset
					break
				}
				count++
			}
			*spans = []MatchSpan{{Start: 0, End: end}}
		}
		if folded == m.prefix && m.prefix != "" {
			return matchRank{}, true
		}
		return matchRank{tier: 1}, true
	}
	// Ordinary prefixes remain available for arbitrarily long identifiers. Fuzzy
	// work has separate bounds, independent of catalog and document limits.
	if len(m.query) > maxFuzzyRunes {
		return matchRank{}, false
	}
	name := []rune(label)
	if len(name) > 256 {
		return matchRank{}, false
	}
	if len(m.compact) >= 2 {
		var trace *wordMatchTrace
		if spans != nil {
			trace = new(wordMatchTrace)
		}
		if gap, ok := matchWordPrefixes(m.compact, name, trace); ok {
			if trace != nil {
				var selected [256]bool
				for _, index := range trace.current[len(m.compact)][:len(m.compact)] {
					selected[index] = true
				}
				*spans = selectedMatchSpans(label, selected[:])
			}
			return matchRank{tier: 1, penalty: 1 + gap}, true
		}
	}
	if len(m.query) < 3 {
		return matchRank{}, false
	}
	limit := 1
	if len(m.query) >= 7 {
		limit = 2
	}
	for i := range name {
		name[i] = unicode.ToLower(name[i])
	}
	var trace *editMatchTrace
	if spans != nil {
		trace = new(editMatchTrace)
	}
	if edits, ok := prefixEditDistance(m.query, name, limit, trace); ok {
		if trace != nil {
			*spans = selectedMatchSpans(label, trace.selected(m.query, name))
		}
		return matchRank{tier: 1 + edits}, true
	}
	return matchRank{}, false
}

func selectedMatchSpans(label string, selected []bool) []MatchSpan {
	var spans []MatchSpan
	index := 0
	for offset := range label {
		if index < len(selected) && selected[index] {
			_, size := utf8.DecodeRuneInString(label[offset:])
			end := offset + size
			if len(spans) > 0 && spans[len(spans)-1].End == offset {
				spans[len(spans)-1].End = end
			} else {
				spans = append(spans, MatchSpan{Start: offset, End: end})
			}
		}
		index++
	}
	return spans
}

func matchWordRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r) || unicode.IsMark(r)
}

func matchWordStart(name []rune, i int) bool {
	if !matchWordRune(name[i]) {
		return false
	}
	if i == 0 || !matchWordRune(name[i-1]) {
		return true
	}
	previous, current := name[i-1], name[i]
	return unicode.IsLower(previous) && unicode.IsUpper(current) ||
		unicode.IsUpper(previous) && unicode.IsUpper(current) && i+1 < len(name) && unicode.IsLower(name[i+1]) ||
		unicode.IsDigit(previous) != unicode.IsDigit(current)
}

type wordMatchTrace struct {
	current, next [maxFuzzyRunes + 1][maxFuzzyRunes]uint8
}

// Each typed chunk must be a word prefix. Whole words may be skipped, but
// arbitrary letters inside a word may not: oi matches order_items, not noise.
// This also supports orditem, camelCase, and acronym boundaries like HTTPServer.
func matchWordPrefixes(query, name []rune, trace *wordMatchTrace) (int, bool) {
	var reachable [maxFuzzyRunes + 1]bool
	reachable[0] = true
	for start := 0; start < len(name); start++ {
		if !matchWordStart(name, start) {
			continue
		}
		end := start + 1
		for end < len(name) && matchWordRune(name[end]) && !matchWordStart(name, end) {
			end++
		}
		next := reachable
		if trace != nil {
			trace.next = trace.current
		}
		for consumed := 0; consumed < len(query); consumed++ {
			if !reachable[consumed] {
				continue
			}
			for i := start; i < end && consumed+i-start < len(query); i++ {
				n := consumed + i - start
				if unicode.ToLower(name[i]) != query[n] {
					break
				}
				if trace != nil && (!next[n+1] || n+1 == len(query)) {
					trace.next[n+1] = trace.current[consumed]
					for j := start; j <= i; j++ {
						trace.next[n+1][consumed+j-start] = uint8(j)
					}
				}
				if n+1 == len(query) {
					if trace != nil {
						trace.current = trace.next
					}
					return i + 1 - len(query), true
				}
				next[n+1] = true
			}
		}
		reachable = next
		if trace != nil {
			trace.current = trace.next
		}
		start = end - 1
	}
	return 0, false
}

type editMatchTrace struct {
	cost [maxFuzzyRunes + 1][maxFuzzyRunes + 3]uint8
	end  int
}

// Banded optimal-string-alignment distance includes adjacent transpositions.
// Compare against a name prefix, so a typo can be corrected before the user
// finishes typing. The band is at most five cells wide; rows stay on the stack.
func prefixEditDistance(query, name []rune, limit int, trace *editMatchTrace) (int, bool) {
	m, n := len(query), min(len(name), len(query)+limit)
	if n < m-limit {
		return 0, false
	}
	const width = maxFuzzyRunes + 3
	var previous, beforePrevious, current [width]int
	for j := range previous {
		previous[j] = min(j, limit+1)
		beforePrevious[j] = limit + 1
	}
	if trace != nil {
		for i := range trace.cost {
			for j := range trace.cost[i] {
				trace.cost[i][j] = uint8(limit + 1)
			}
			trace.cost[i][0] = uint8(min(i, limit+1))
		}
		for j := range previous {
			trace.cost[0][j] = uint8(previous[j])
		}
	}
	for i := 1; i <= m; i++ {
		for j := range current {
			current[j] = limit + 1
		}
		current[0] = min(i, limit+1)
		for j := max(1, i-limit); j <= min(n, i+limit); j++ {
			cost := 0
			if query[i-1] != name[j-1] {
				cost = 1
			}
			current[j] = min(previous[j]+1, current[j-1]+1, previous[j-1]+cost)
			if i > 1 && j > 1 && query[i-1] == name[j-2] && query[i-2] == name[j-1] {
				current[j] = min(current[j], beforePrevious[j-2]+1)
			}
			if trace != nil {
				trace.cost[i][j] = uint8(current[j])
			}
		}
		beforePrevious, previous = previous, current
	}
	best := limit + 1
	for j := max(1, m-limit); j <= n; j++ {
		if trace != nil && previous[j] <= best {
			// Prefer the longest equally good prefix: a missing name letter
			// then remains unhighlighted instead of looking like a substitution.
			trace.end = j
		}
		best = min(best, previous[j])
	}
	return best, best <= limit
}

func (trace *editMatchTrace) selected(query, name []rune) []bool {
	selected := make([]bool, len(name))
	for i, j := len(query), trace.end; i > 0 && j > 0; {
		cost := trace.cost[i][j]
		switch {
		case query[i-1] == name[j-1] && cost == trace.cost[i-1][j-1]:
			selected[j-1] = true
			i, j = i-1, j-1
		case i > 1 && j > 1 && query[i-1] == name[j-2] && query[i-2] == name[j-1] && cost == trace.cost[i-2][j-2]+1:
			selected[j-1], selected[j-2] = true, true
			i, j = i-2, j-2
		case cost == trace.cost[i-1][j-1]+1:
			i, j = i-1, j-1 // Substituted letters do not match.
		case cost == trace.cost[i-1][j]+1:
			i-- // Extra typed letter.
		default:
			j-- // Missing name letter.
		}
	}
	return selected
}

func lessCompletion(a, b Item) bool {
	// Keep matching FK snippets ahead of generic identifiers (e.g. ON o should
	// still offer o.customer_id = c.id before the alias o). Other exact names
	// win over prefixes. Strong matches favor query columns and CTEs over
	// general candidates; typo-only matches follow, with one edit before two.
	aTier, bTier := a.match.tier, b.match.tier
	if a.priority < 0 && aTier == 1 {
		aTier = 0
	}
	if b.priority < 0 && bTier == 1 {
		bTier = 0
	}
	if aTier != bTier {
		return aTier < bTier
	}
	if a.priority != b.priority {
		return a.priority < b.priority
	}
	if a.match.penalty != b.match.penalty {
		return a.match.penalty < b.match.penalty
	}
	if a.sortLabel != b.sortLabel {
		return a.sortLabel < b.sortLabel
	}
	return a.InsertText < b.InsertText
}
