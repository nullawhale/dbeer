package schemaimport

import (
	"context"
	"reflect"

	sc "dbeer/helper/internal/schemacompare"
)

// Select retains explicitly mapped schemas and the typed external definitions
// reachable from them. A historical source cannot claim an uncaptured schema.
func Select(ctx context.Context, c sc.Capture, schemas []string) (sc.Capture, error) {
	if len(schemas) < 1 || len(schemas) > 32 {
		return sc.Capture{}, ErrInvalid
	}
	selected := map[string]bool{}
	for _, s := range schemas {
		if !sc.ValidName(s) || selected[s] {
			return sc.Capture{}, ErrInvalid
		}
		selected[s] = true
	}
	out := sc.Capture{Context: c.Context, Inventories: []sc.Inventory{}, Tables: []sc.Table{}, Types: []sc.TypeDefinition{}, Sequences: []sc.Sequence{}, Issues: []sc.Issue{}}
	for _, i := range c.Inventories {
		if selected[i.Schema] {
			out.Inventories = append(out.Inventories, i)
		}
	}
	if len(out.Inventories) != len(selected) {
		return sc.Capture{}, ErrInvalid
	}
	refs := map[sc.Ref]bool{}
	var visit func(reflect.Value)
	visit = func(v reflect.Value) {
		if v.Kind() == reflect.Pointer {
			if !v.IsNil() {
				visit(v.Elem())
			}
			return
		}
		if v.Type() == reflect.TypeFor[sc.Ref]() {
			refs[v.Interface().(sc.Ref)] = true
			return
		}
		switch v.Kind() {
		case reflect.Struct:
			for i := 0; i < v.NumField(); i++ {
				visit(v.Field(i))
			}
		case reflect.Slice:
			for i := 0; i < v.Len(); i++ {
				visit(v.Index(i))
			}
		}
	}
	for _, t := range c.Tables {
		if err := ctx.Err(); err != nil {
			return sc.Capture{}, err
		}
		if selected[t.Ref.Schema] {
			out.Tables = append(out.Tables, t)
			visit(reflect.ValueOf(t))
		}
	}
	keptTypes, keptSequences := map[sc.Ref]bool{}, map[sc.Ref]bool{}
	for changed := true; changed; {
		changed = false
		for _, t := range c.Types {
			if err := ctx.Err(); err != nil {
				return sc.Capture{}, err
			}
			if !keptTypes[t.Ref] && (selected[t.Ref.Schema] || refs[t.Ref]) {
				out.Types = append(out.Types, t)
				keptTypes[t.Ref] = true
				visit(reflect.ValueOf(t))
				changed = true
			}
		}
		for _, s := range c.Sequences {
			if err := ctx.Err(); err != nil {
				return sc.Capture{}, err
			}
			if !keptSequences[s.Ref] && (selected[s.Ref.Schema] || refs[s.Ref]) {
				out.Sequences = append(out.Sequences, s)
				keptSequences[s.Ref] = true
				visit(reflect.ValueOf(s))
				changed = true
			}
		}
	}
	for _, issue := range c.Issues {
		if issue.Ref == nil || selected[issue.Ref.Schema] || refs[*issue.Ref] {
			out.Issues = append(out.Issues, issue)
		}
	}
	return out, nil
}
