package schemaimport

import (
	"context"
	"reflect"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
)

// Reconcile edited facts from current membership. Old derived edges and issues
// must not preserve deleted members or conceal a now-missing selected object.
func reconcile(ctx context.Context, c sc.Capture) (sc.Capture, int, error) {
	roots, members, schemas := map[sc.Ref]bool{}, map[sc.Ref]bool{}, map[string]bool{}
	for _, i := range c.Inventories {
		schemas[i.Schema] = true
	}
	for _, t := range c.Tables {
		roots[t.Ref] = true
		members[t.Ref] = true
		for _, v := range t.Columns.Items {
			members[v.Ref] = true
		}
		for _, v := range t.Constraints.Items {
			members[v.Ref] = true
		}
		for _, v := range t.Indexes.Items {
			members[v.Ref] = true
		}
	}
	for _, t := range c.Types {
		roots[t.Ref] = true
		members[t.Ref] = true
	}
	for _, s := range c.Sequences {
		roots[s.Ref] = true
		members[s.Ref] = true
	}
	issues := []sc.Issue{}
	for _, i := range c.Issues {
		if i.Ref == nil || i.Ref.Kind == "capture" || i.Ref.Kind == "schema" || !schemas[i.Ref.Schema] || members[*i.Ref] {
			issues = append(issues, i)
		}
	}
	c.Issues = issues
	for i := range c.Tables {
		if err := ctx.Err(); err != nil {
			return sc.Capture{}, 0, err
		}
		t := &c.Tables[i]
		old := t.Dependencies
		derived := sc.DerivedDependencies(*t)
		t.Dependencies.Items = derived.Items
		for _, edge := range old.Items {
			if edge.Kind == "catalogReference" {
				continue
			}
			if edge.From.Schema == t.Ref.Schema && (edge.From == t.Ref || edge.From.Table == t.Ref.Name) && !members[edge.From] {
				continue
			}
			t.Dependencies.Items = append(t.Dependencies.Items, edge)
		}
		for n := range t.Dependencies.Items {
			edge := &t.Dependencies.Items[n]
			to := edge.To
			if !schemas[to.Schema] || to.Schema == "pg_catalog" || to.Schema == "information_schema" || strings.EqualFold(to.Schema, "sqlite") {
				continue
			}
			if to.Kind != "table" && to.Kind != "type" && to.Kind != "sequence" {
				continue
			}
			if to.RowType {
				to = sc.Ref{Kind: "table", Schema: to.Schema, Name: to.Name}
			}
			if !roots[to] {
				edge.State = "unavailable"
				t.Dependencies.Complete = false
				t.Dependencies.State = "unsupported"
				t.Dependencies.Code = "offlineDependencyMissing"
			}
		}
		if t.Dependencies.Code == "offlineDependencyMissing" {
			ref := t.Ref
			c.Issues = append(c.Issues, sc.Issue{Ref: &ref, Property: "dependencies", Code: t.Dependencies.Code, Message: "A selected historical definition references an object that is no longer present in the imported SQL files.", BlocksEquality: true, Planning: "manual"})
		}
	}
	for _, sequence := range c.Sequences {
		if sequence.Owner.Value == nil {
			continue
		}
		owner := *sequence.Owner.Value
		if schemas[owner.Schema] && !members[owner] {
			ref := sequence.Ref
			c.Issues = append(c.Issues, sc.Issue{Ref: &ref, Property: "owner", Code: "offlineDependencyMissing", Message: "The sequence owner is no longer present in the imported SQL files.", BlocksEquality: true, Planning: "manual"})
		}
	}
	manualRoots := map[sc.Ref]bool{}
	for _, i := range c.Issues {
		if i.BlocksEquality && i.Ref != nil {
			r := *i.Ref
			if r.Table != "" {
				r = sc.Ref{Kind: "table", Schema: r.Schema, Name: r.Table}
			}
			if roots[r] {
				manualRoots[r] = true
			}
		}
	}
	for _, t := range c.Tables {
		if containsUnknown(reflect.ValueOf(t)) {
			manualRoots[t.Ref] = true
		}
	}
	for _, t := range c.Types {
		if containsUnknown(reflect.ValueOf(t)) {
			manualRoots[t.Ref] = true
		}
	}
	for _, sequence := range c.Sequences {
		if containsUnknown(reflect.ValueOf(sequence)) {
			manualRoots[sequence.Ref] = true
		}
	}
	return c, len(manualRoots), nil
}

func containsUnknown(v reflect.Value) bool {
	if v.Kind() == reflect.Pointer {
		return !v.IsNil() && containsUnknown(v.Elem())
	}
	switch v.Kind() {
	case reflect.Struct:
		name := v.Type().Name()
		if strings.HasPrefix(name, "Fact[") || strings.HasPrefix(name, "Collection[") {
			if v.FieldByName("State").String() != "known" {
				return true
			}
			if f := v.FieldByName("Complete"); f.IsValid() && !f.Bool() {
				return true
			}
		}
		for i := 0; i < v.NumField(); i++ {
			if containsUnknown(v.Field(i)) {
				return true
			}
		}
	case reflect.Slice:
		for i := 0; i < v.Len(); i++ {
			if containsUnknown(v.Index(i)) {
				return true
			}
		}
	}
	return false
}
