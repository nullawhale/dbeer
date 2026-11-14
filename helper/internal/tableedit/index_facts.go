package tableedit

import (
	sc "dbeer/helper/internal/schemacompare"
	"encoding/json"
	"reflect"
	"sort"
	"strings"
)

func CanonicalIndexMethod(engine, method string) string {
	lower := strings.ToLower(method)
	if engine == "mysql" || engine == "mariadb" {
		if lower == "rtree" {
			return "spatial"
		}
		return lower
	}
	switch lower {
	case "btree", "hash", "gist", "spgist", "gin", "brin":
		return lower
	}
	return method
}
func IndexFacts(engine string, target Target, name string, unique bool, d IndexDefinition) sc.Index {
	method := CanonicalIndexMethod(engine, d.Method)
	nativeMethod := method
	if engine == "mysql" || engine == "mariadb" {
		nativeMethod = strings.ToUpper(method)
	}
	x := sc.Index{Ref: sc.Ref{Kind: "index", Schema: target.Schema, Table: target.Table, Name: name}, Method: sc.Known(nativeMethod), Unique: sc.Known(unique), NullsDistinct: sc.Known(true), Keys: sc.Complete[sc.IndexKey](nil), Includes: sc.Complete[sc.Ref](nil), Predicate: sc.Absent[sc.Expression](), Options: sc.Complete[sc.Option](nil), Visible: sc.Known(true), Valid: sc.Known(true), Ready: sc.Known(true), Constraint: sc.Absent[sc.Ref]()}
	if d.NullsDistinct != nil {
		x.NullsDistinct = sc.Known(*d.NullsDistinct)
	}
	if d.Visible != nil {
		x.Visible = sc.Known(*d.Visible)
	}
	for _, t := range d.Terms {
		desc := t.Descending != nil && *t.Descending
		first := !desc
		if engine == "postgresql" {
			first = desc
		}
		if t.NullsFirst != nil {
			first = *t.NullsFirst
		}
		k := sc.IndexKey{Column: sc.Absent[sc.Ref](), Expression: sc.Absent[sc.Expression](), Opclass: sc.Absent[sc.Ref](), Collation: sc.Absent[sc.Ref](), Descending: sc.Known(desc), NullsFirst: sc.Known(first), PrefixLength: sc.Absent[int64](), Options: sc.Complete[sc.Option](nil)}
		if t.Column != nil {
			k.Column = sc.Known(sc.Ref{Kind: "column", Schema: target.Schema, Table: target.Table, Name: *t.Column})
		}
		if t.Expression != nil {
			k.Expression = sc.Known(sc.Expression{Text: *t.Expression, Dependencies: sc.Complete[sc.Ref](nil)})
		}
		if t.Collation != nil {
			k.Collation = sc.Known(sc.Ref{Kind: "collation", Schema: t.Collation.Schema, Name: t.Collation.Name})
		}
		if t.Opclass != nil {
			k.Opclass = sc.Known(sc.Ref{Kind: "opclass", Schema: t.Opclass.Schema, Name: t.Opclass.Name})
		}
		if t.PrefixLength != nil {
			k.PrefixLength = sc.Known(*t.PrefixLength)
		}
		for _, o := range t.Options {
			k.Options.Items = append(k.Options.Items, sc.Option{Name: o.Name, Value: o.Value})
		}
		x.Keys.Items = append(x.Keys.Items, k)
	}
	for _, name := range d.Includes {
		x.Includes.Items = append(x.Includes.Items, sc.Ref{Kind: "column", Schema: target.Schema, Table: target.Table, Name: name})
	}
	if d.Predicate != nil {
		x.Predicate = sc.Known(sc.Expression{Text: *d.Predicate, Dependencies: sc.Complete[sc.Ref](nil)})
	}
	for _, o := range d.Options {
		x.Options.Items = append(x.Options.Items, sc.Option{Name: o.Name, Value: o.Value})
	}
	return x
}
func ObservedIndexDefinition(engine string, x sc.Index) (*IndexDefinition, bool) {
	if engine != "postgresql" && engine != "mysql" && engine != "mariadb" || x.Method.Value == nil || x.Unique.Value == nil || x.NullsDistinct.Value == nil || !x.Keys.Complete || !x.Includes.Complete || !x.Options.Complete || x.Predicate.State != "known" || x.Constraint.State != "known" || x.Visible.Value == nil || x.Valid.Value == nil || !*x.Valid.Value || x.Ready.Value == nil || !*x.Ready.Value {
		return nil, false
	}
	d := &IndexDefinition{Method: CanonicalIndexMethod(engine, *x.Method.Value), Terms: []IndexTerm{}, NullsDistinct: x.NullsDistinct.Value, Visible: x.Visible.Value}
	options := func(source sc.Collection[sc.Option]) []IndexOption {
		out := []IndexOption{}
		for _, o := range source.Items {
			out = append(out, IndexOption{Name: o.Name, Value: o.Value})
		}
		return out
	}
	expression := func(x *sc.Expression) bool {
		if x == nil {
			return false
		}
		switch x.Dependencies.Code {
		case "expressionIndexKey", "customTypeSupport", "indexExpressionSyntax":
			return false
		}
		// Catalog spelling is display evidence, not executable authoring. A copied
		// draft must pass the adapter's strict slot admission before Preview.
		return authoredText(x.Text)
	}
	for _, k := range x.Keys.Items {
		if k.Column.State != "known" || k.Expression.State != "known" || k.Opclass.State != "known" || k.Collation.State != "known" || k.PrefixLength.State != "known" || k.Descending.Value == nil || k.NullsFirst.Value == nil || !k.Options.Complete {
			return nil, false
		}
		t := IndexTerm{PrefixLength: k.PrefixLength.Value, Options: options(k.Options)}
		if k.Column.Value != nil {
			name := k.Column.Value.Name
			t.Column = &name
		}
		if k.Expression.Value != nil {
			if !expression(k.Expression.Value) {
				return nil, false
			}
			raw := k.Expression.Value.Text
			t.Expression = &raw
		}
		if d.Method == "btree" {
			t.Descending = k.Descending.Value
			if engine == "postgresql" {
				t.NullsFirst = k.NullsFirst.Value
			}
		}
		if k.Collation.Value != nil {
			t.Collation = &TypeReference{Schema: k.Collation.Value.Schema, Name: k.Collation.Value.Name}
		}
		if k.Opclass.Value != nil {
			t.Opclass = &TypeReference{Schema: k.Opclass.Value.Schema, Name: k.Opclass.Value.Name}
		}
		d.Terms = append(d.Terms, t)
	}
	for _, r := range x.Includes.Items {
		d.Includes = append(d.Includes, r.Name)
	}
	if x.Predicate.Value != nil {
		if !expression(x.Predicate.Value) {
			return nil, false
		}
		text := x.Predicate.Value.Text
		d.Predicate = &text
	}
	d.Options = options(x.Options)
	return d, d.Valid()
}
func indexOptionsEqual(a, b []IndexOption) bool {
	clone := func(in []IndexOption) []IndexOption {
		out := append([]IndexOption(nil), in...)
		sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
		return out
	}
	return reflect.DeepEqual(clone(a), clone(b))
}
func IndexDefinitionMatches(before, after Baseline, x sc.Index, w IndexDefinition) bool {
	actual, ok := ObservedIndexDefinition(after.Engine, x)
	if !ok || CanonicalIndexMethod(after.Engine, w.Method) != actual.Method || len(w.Terms) != len(actual.Terms) || !reflect.DeepEqual(w.Includes, actual.Includes) && !(len(w.Includes) == 0 && len(actual.Includes) == 0) {
		return false
	}
	value := func(p *bool, def bool) bool {
		if p != nil {
			return *p
		}
		return def
	}
	if value(w.Visible, true) != value(actual.Visible, true) || value(w.NullsDistinct, true) != value(actual.NullsDistinct, true) {
		return false
	}
	if (w.Predicate == nil) != (actual.Predicate == nil) || w.Predicate != nil && !SameCatalogExpression(after.Engine, *actual.Predicate, *w.Predicate, after.Facts) {
		return false
	}
	if !indexOptionsEqual(w.Options, actual.Options) {
		return false
	}
	for i, t := range w.Terms {
		a := actual.Terms[i]
		if !reflect.DeepEqual(t.Column, a.Column) || !reflect.DeepEqual(t.PrefixLength, a.PrefixLength) || (t.Expression == nil) != (a.Expression == nil) || t.Expression != nil && !SameCatalogExpression(after.Engine, *a.Expression, *t.Expression, after.Facts) && !builtinIndexExpressionMatches(after, *a.Expression, *t.Expression, x.Ref.Name, i) {
			return false
		}
		if value(t.Descending, false) != value(a.Descending, false) {
			return false
		}
		if after.Engine == "postgresql" && actual.Method == "btree" && value(t.NullsFirst, value(t.Descending, false)) != value(a.NullsFirst, false) {
			return false
		}
		if t.Collation != nil {
			if !reflect.DeepEqual(t.Collation, a.Collation) {
				return false
			}
		} else if after.Engine == "postgresql" {
			defaults := after.Facts.IndexDefaultCollations[x.Ref.Name]
			if len(defaults) <= i || !defaults[i] {
				return false
			}
		}
		if t.Opclass != nil {
			if !reflect.DeepEqual(t.Opclass, a.Opclass) {
				return false
			}
		} else if after.Engine == "postgresql" {
			defaults := after.Facts.IndexDefaultOpclasses[x.Ref.Name]
			if len(defaults) <= i || !defaults[i] {
				return false
			}
		}
		if !indexOptionsEqual(t.Options, a.Options) {
			return false
		}
	}
	return true
}

// PostgreSQL adds a binary VARCHAR-to-text relabel for its builtin lower/upper
// functions. Prove only that exact call shape; no SQL is rewritten or evaluated.
func builtinIndexExpressionMatches(b Baseline, actual, authored, index string, term int) bool {
	if b.Engine != "postgresql" || b.Facts == nil {
		return false
	}
	functions := b.Facts.IndexBuiltinFunctions[index]
	if len(functions) <= term {
		return false
	}
	function := functions[term]
	if function != "lower" && function != "upper" {
		return false
	}
	names := expressionIdentifiers(b.Facts)
	a, ok := expressionTokens("postgresql", actual, names, false)
	if !ok {
		return false
	}
	w, ok := expressionTokens("postgresql", authored, names, false)
	if !ok {
		return false
	}
	if len(w) == 6 && w[0] == "word:pg_catalog" && w[1] == "." {
		w = w[2:]
	}
	if len(w) != 4 || w[0] != "word:"+function || w[1] != "(" || w[3] != ")" {
		return false
	}
	name := ""
	if strings.HasPrefix(w[2], "word:") {
		name = strings.TrimPrefix(w[2], "word:")
	} else if strings.HasPrefix(w[2], "identifier:") {
		if json.Unmarshal([]byte(strings.TrimPrefix(w[2], "identifier:")), &name) != nil {
			return false
		}
	} else {
		return false
	}
	c, found := FindColumn(b, name)
	if !found || c.Type.Value == nil || c.Type.Value.Kind != "builtin" || c.Type.Value.Ref.Schema != "pg_catalog" || c.Type.Value.Ref.Name != "varchar" {
		return false
	}
	expected := []string{"word:" + function, "(", "(", w[2], ")", ":", ":", "word:text", ")"}
	return reflect.DeepEqual(a, expected)
}
