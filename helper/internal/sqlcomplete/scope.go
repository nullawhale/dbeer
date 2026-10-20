package sqlcomplete

import "strings"

// A binding is shared by CTE references so recursive terms can see the anchor
// projection. Catalog relations retain their identity only for direct sources;
// derived expressions never inherit foreign keys by guessing their lineage.
type binding struct {
	name    token
	columns []string
}
type source struct {
	name       token
	schema     token
	entries    []Relation
	columns    []string
	start, end int
}
type scope struct {
	lo, hi, body     int
	start, end       int
	ctes             []*binding
	sources, outer   []source
	outputs, aliases []string
	children         []*scope
	branches         []*scope
	setOrder         int
}
type analysis struct {
	tokens  []token
	pairs   map[int]int
	context Context
	scopes  int
	budget  int
	end     int
}

func analyze(tokens []token, context Context, start, end int) (*analysis, *scope) {
	a := &analysis{tokens: tokens, context: context, pairs: map[int]int{}, budget: 1_000_000, end: end}
	stack := []int{}
	for i, t := range tokens {
		if punct(t, "(") && t.kind == punctuationToken {
			stack = append(stack, i)
		}
		if punct(t, ")") && t.kind == punctuationToken && len(stack) > 0 {
			j := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			a.pairs[j] = i
		}
	}
	s := a.query(0, len(tokens), nil, nil, 0, nil)
	s.start, s.end = start, end
	return a, s
}

func (a *analysis) close(i, hi int) int {
	if j, ok := a.pairs[i]; ok && j < hi {
		return j
	}
	return hi
}

func (a *analysis) query(lo, hi int, inherited []*binding, outer []source, depth int, recursive *binding) *scope {
	s := &scope{lo: lo, hi: hi, body: lo, ctes: append([]*binding{}, inherited...), outer: outer}
	if lo < hi {
		s.start = a.tokens[lo].start
		s.end = a.tokens[hi-1].end
	}
	a.scopes++
	if depth >= 48 || a.scopes > 512 || a.budget <= 0 {
		return s
	}
	t := a.tokens
	used := map[int]bool{}
	// WITH declarations are parsed in order. Later siblings are not visible in
	// earlier bodies; a nested WITH shadows an inherited name locally.
	if lo < hi && word(t[lo], "WITH") {
		i := lo + 1
		isRecursive := i < hi && word(t[i], "RECURSIVE")
		if isRecursive {
			i++
		}
		for i < hi && identifier(t[i]) {
			b := &binding{name: t[i]}
			i++
			explicit := []string{}
			if i < hi && punct(t[i], "(") {
				j := a.close(i, hi)
				explicit = a.columnList(i+1, j)
				i = min(j+1, hi)
			}
			if i >= hi || !word(t[i], "AS") {
				break
			}
			i++
			if i < hi && word(t[i], "NOT") {
				i++
			}
			if i < hi && word(t[i], "MATERIALIZED") {
				i++
			}
			if i >= hi || !punct(t[i], "(") {
				break
			}
			open, j := i, a.close(i, hi)
			env := append([]*binding{}, s.ctes...)
			b.columns = explicit
			if isRecursive {
				env = append(env, b)
			}
			child := a.query(i+1, j, env, outer, depth+1, b)
			if len(explicit) > 0 {
				b.columns = explicit
			} else {
				b.columns = child.outputs
			}
			a.attach(s, child, open, j)
			used[open] = true
			s.ctes = append(s.ctes, b)
			i = min(j+1, hi)
			if i >= hi || !punct(t[i], ",") {
				s.body = i
				break
			}
			i++
			s.body = i
		}
	}
	// Set-operation branches have independent FROM namespaces. Their result
	// names are defined by the first branch, including recursive CTE anchors.
	splits := []int{}
	for i := s.body; i < hi; i++ {
		a.budget--
		if punct(t[i], "(") {
			i = a.close(i, hi)
			continue
		}
		if word(t[i], "UNION") || word(t[i], "EXCEPT") || word(t[i], "INTERSECT") {
			splits = append(splits, i)
		}
	}
	if len(splits) > 0 {
		setEnd := hi
		for i := splits[len(splits)-1] + 1; i < hi; i++ {
			if punct(t[i], "(") {
				i = a.close(i, hi)
				continue
			}
			if word(t[i], "ORDER") || word(t[i], "LIMIT") || word(t[i], "OFFSET") {
				setEnd = i
				s.setOrder = t[i].start
				break
			}
		}
		begin := s.body
		for _, end := range append(splits, setEnd) {
			child := a.query(begin, end, s.ctes, outer, depth+1, nil)
			if begin >= end && end > 0 {
				child.start = t[end-1].end
				child.end = child.start
			}
			if len(s.children) == len(used) {
				s.outputs = child.outputs
				if recursive != nil && len(recursive.columns) == 0 {
					recursive.columns = child.outputs
				}
			}
			s.children = append(s.children, child)
			s.branches = append(s.branches, child)
			begin = end + 1
			if begin < hi && (word(t[begin], "ALL") || word(t[begin], "DISTINCT")) {
				begin++
			}
		}
		s.aliases = append([]string{}, s.outputs...)
		return s
	}
	inFrom, expectSource := false, false
	for i := s.body; i < hi && a.budget > 0; i++ {
		a.budget--
		if word(t[i], "FROM") || word(t[i], "JOIN") || word(t[i], "UPDATE") || word(t[i], "INTO") {
			inFrom, expectSource = true, true
			continue
		}
		if clauseBoundary(t[i]) {
			inFrom, expectSource = false, false
		}
		if inFrom && punct(t[i], ",") {
			expectSource = true
			continue
		}
		if !expectSource {
			if punct(t[i], "(") {
				i = a.close(i, hi)
			}
			continue
		}
		lateral := word(t[i], "LATERAL")
		if lateral {
			i++
			if i >= hi {
				break
			}
		}
		candidate := source{start: t[i].start}
		if punct(t[i], "(") {
			j := a.close(i, hi)
			if a.queryStart(i+1, j) {
				visible := outer
				if lateral {
					visible = append(append([]source{}, s.sources...), outer...)
				}
				child := a.query(i+1, j, s.ctes, visible, depth+1, nil)
				a.attach(s, child, i, j)
				used[i] = true
				candidate.columns = child.outputs
			}
			i = min(j, hi-1)
		} else if identifier(t[i]) {
			candidate.name = t[i]
			if i+2 < hi && punct(t[i+1], ".") && identifier(t[i+2]) {
				candidate.schema = t[i]
				candidate.name = t[i+2]
				i += 2
			}
			if i+1 < hi && punct(t[i+1], "(") {
				// Unknown table-valued functions do not acquire the columns of
				// an unrelated catalog table with the same spelling.
				i = min(a.close(i+1, hi), hi-1)
			} else {
				a.resolve(&candidate, s.ctes)
			}
		} else {
			expectSource = false
			continue
		}
		j := i + 1
		if j < hi && word(t[j], "AS") {
			j++
		}
		if j < hi && identifier(t[j]) {
			candidate.name = t[j]
			candidate.schema = token{}
			i = j
			j++
		}
		if j < hi && punct(t[j], "(") {
			close := a.close(j, hi)
			names := a.columnList(j+1, close)
			for k, name := range names {
				if k < len(candidate.columns) {
					candidate.columns[k] = name
				} else {
					candidate.columns = append(candidate.columns, name)
				}
			}
			i = min(close, hi-1)
		}
		candidate.end = t[i].end
		if candidate.name.value != "" || len(candidate.columns) > 0 {
			s.sources = append(s.sources, candidate)
		}
		expectSource = false
		if len(s.sources) >= 256 {
			break
		}
	}
	s.outputs, s.aliases = a.projection(s)
	// Scalar/EXISTS subqueries can correlate with the enclosing query. Derived
	// tables were handled above, with the narrower LATERAL visibility rules.
	for i := s.body; i < hi && a.budget > 0; i++ {
		a.budget--
		if !punct(t[i], "(") {
			continue
		}
		j := a.close(i, hi)
		if used[i] {
			i = j
			continue
		}
		if a.queryStart(i+1, j) {
			child := a.query(i+1, j, s.ctes, append(append([]source{}, s.sources...), outer...), depth+1, nil)
			a.attach(s, child, i, j)
			i = j
		}
	}
	return s
}

func (a *analysis) attach(parent, child *scope, open, close int) {
	child.start = a.tokens[open].end
	if close < len(a.tokens) {
		child.end = a.tokens[close].start
	} else {
		child.end = a.end
	}
	parent.children = append(parent.children, child)
}
func (a *analysis) queryStart(lo, hi int) bool {
	return lo < hi && (word(a.tokens[lo], "SELECT") || word(a.tokens[lo], "WITH") || word(a.tokens[lo], "UPDATE") || word(a.tokens[lo], "INSERT") || word(a.tokens[lo], "DELETE"))
}
func (a *analysis) resolve(candidate *source, ctes []*binding) {
	if candidate.schema.value == "" {
		for i := len(ctes) - 1; i >= 0; i-- {
			if identifierTokenEqual(candidate.name, ctes[i].name, a.context.Engine) {
				candidate.columns = append([]string{}, ctes[i].columns...)
				return
			}
		}
	}
	for _, entry := range a.context.Catalog {
		if a.context.Engine == "cassandra" && candidate.schema.value == "" && a.context.Keyspace != "" && entry.Schema != a.context.Keyspace {
			continue
		}
		if entry.Kind != "function" && identifierEqual(candidate.name, entry.Name, a.context.Engine) && (candidate.schema.value == "" || identifierEqual(candidate.schema, entry.Schema, a.context.Engine)) {
			candidate.entries = append(candidate.entries, entry)
			candidate.columns = append(candidate.columns, entry.Columns...)
		}
	}
}
func (a *analysis) columnList(lo, hi int) []string {
	names := []string{}
	for i := lo; i < hi; i++ {
		if identifier(a.tokens[i]) {
			names = append(names, identifierName(a.tokens[i], a.context.Engine))
		}
	}
	return names
}
func clauseBoundary(t token) bool {
	for _, name := range []string{"WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "SET", "RETURNING", "UNION", "EXCEPT", "INTERSECT", "WINDOW", "FETCH", "FOR", "VALUES"} {
		if word(t, name) {
			return true
		}
	}
	return false
}
func (s *scope) at(offset int) *scope {
	if len(s.branches) > 0 && s.setOrder > 0 && offset >= s.setOrder {
		return s
	}
	for _, child := range s.children {
		if offset >= child.start && offset <= child.end {
			return child.at(offset)
		}
	}
	if len(s.branches) > 0 {
		for i := len(s.branches) - 1; i >= 0; i-- {
			if offset >= s.branches[i].start {
				return s.branches[i].at(offset)
			}
		}
	}
	return s
}
func (s *scope) visible(engine string) []source {
	result := append([]source{}, s.sources...)
	for _, candidate := range s.outer {
		shadowed := false
		for _, local := range result {
			if identifierTokenEqual(local.name, candidate.name, engine) {
				shadowed = true
				break
			}
		}
		if !shadowed {
			result = append(result, candidate)
		}
	}
	return result
}
func (a *analysis) projection(s *scope) ([]string, []string) {
	t := a.tokens
	begin := s.body
	for begin < s.hi && !word(t[begin], "SELECT") {
		begin++
	}
	if begin >= s.hi {
		return nil, nil
	}
	begin++
	if begin < s.hi && (word(t[begin], "DISTINCT") || word(t[begin], "ALL")) {
		begin++
		if begin < s.hi && word(t[begin], "ON") && begin+1 < s.hi && punct(t[begin+1], "(") {
			begin = min(a.close(begin+1, s.hi)+1, s.hi)
		}
	}
	outputs, aliases := []string{}, []string{}
	add := func(lo, hi int) {
		if lo >= hi {
			return
		}
		for i := lo; i+1 < hi; i++ {
			if punct(t[i], "(") {
				i = a.close(i, hi)
				continue
			}
			if word(t[i], "AS") && identifier(t[i+1]) {
				outputs = append(outputs, identifierName(t[i+1], a.context.Engine))
				aliases = append(aliases, identifierName(t[i+1], a.context.Engine))
				return
			}
		}
		if hi-lo > 1 && identifier(t[hi-1]) && (identifier(t[hi-2]) || punct(t[hi-2], ")") || t[hi-2].kind == stringToken || word(t[hi-2], "END") || t[hi-2].kind == wordToken && len(t[hi-2].value) > 0 && t[hi-2].value[0] >= '0' && t[hi-2].value[0] <= '9') {
			outputs = append(outputs, identifierName(t[hi-1], a.context.Engine))
			aliases = append(aliases, identifierName(t[hi-1], a.context.Engine))
			return
		}
		if hi-lo == 1 && identifier(t[lo]) {
			outputs = append(outputs, identifierName(t[lo], a.context.Engine))
			return
		}
		if hi-lo == 3 && punct(t[lo+1], ".") && identifier(t[lo+2]) {
			outputs = append(outputs, identifierName(t[lo+2], a.context.Engine))
			return
		}
		if hi-lo == 1 && punct(t[lo], "*") {
			for _, src := range s.sources {
				outputs = append(outputs, src.columns...)
			}
			return
		}
		if hi-lo == 3 && punct(t[lo+1], ".") && punct(t[lo+2], "*") {
			for _, src := range s.sources {
				if identifierTokenEqual(t[lo], src.name, a.context.Engine) {
					outputs = append(outputs, src.columns...)
				}
			}
		}
	}
	item := begin
	for i := begin; i < s.hi; i++ {
		if punct(t[i], "(") {
			i = a.close(i, s.hi)
			continue
		}
		if word(t[i], "FROM") || word(t[i], "INTO") || clauseBoundary(t[i]) {
			add(item, i)
			return outputs, aliases
		}
		if punct(t[i], ",") {
			add(item, i)
			item = i + 1
		}
	}
	add(item, s.hi)
	return outputs, aliases
}

func sourceDetail(src source) string {
	if len(src.entries) > 0 {
		return strings.TrimPrefix(src.entries[0].Schema+"."+src.entries[0].Name, ".")
	}
	return "Query · " + src.name.value
}
