package schemabundle

import (
	"context"
	"encoding/json"
	"reflect"
	"sort"
	"strings"
	"unicode/utf8"

	sc "dbeer/helper/internal/schemacompare"
)

// Canonical retains semantic identifiers and ordered members. It removes only
// capture provenance, never schema/database qualification from object refs.
func Canonical(ctx context.Context, source sc.Capture) (sc.Capture, error) {
	if !validStrings(reflect.ValueOf(source)) {
		return sc.Capture{}, ErrInvalid
	}
	collector := sc.NewCollector(ctx, sc.DefaultLimits())
	if err := collector.Context(source.Context); err != nil {
		return sc.Capture{}, err
	}
	for _, v := range source.Inventories {
		if err := collector.Inventory(v); err != nil {
			return sc.Capture{}, err
		}
	}
	for _, v := range source.Tables {
		if err := collector.Table(v); err != nil {
			return sc.Capture{}, err
		}
	}
	for _, v := range source.Types {
		if err := collector.Type(v); err != nil {
			return sc.Capture{}, err
		}
	}
	for _, v := range source.Sequences {
		if err := collector.Sequence(v); err != nil {
			return sc.Capture{}, err
		}
	}
	for _, v := range source.Issues {
		if err := collector.Issue(v); err != nil {
			return sc.Capture{}, err
		}
	}
	// JSON copies pointers/slices without aliasing a retained comparison capture.
	raw, err := json.Marshal(collector.Capture)
	if err != nil {
		return sc.Capture{}, err
	}
	var c sc.Capture
	if err = json.Unmarshal(raw, &c); err != nil {
		return sc.Capture{}, err
	}
	c.Context.Origin = nil
	c.Context.StartedAt = ""
	c.Context.FinishedAt = ""
	c.Context.Database = ""
	c.Context.Version = ""
	normalize(reflect.ValueOf(&c).Elem())
	sort.Slice(c.Inventories, func(i, j int) bool { return c.Inventories[i].Schema < c.Inventories[j].Schema })
	for i := range c.Inventories {
		v := &c.Inventories[i]
		sortRefs(v.Tables.Items)
		sortRefs(v.Types.Items)
	}
	sort.Slice(c.Tables, func(i, j int) bool { return refKey(c.Tables[i].Ref) < refKey(c.Tables[j].Ref) })
	sort.Slice(c.Types, func(i, j int) bool { return refKey(c.Types[i].Ref) < refKey(c.Types[j].Ref) })
	sort.Slice(c.Sequences, func(i, j int) bool { return refKey(c.Sequences[i].Ref) < refKey(c.Sequences[j].Ref) })
	for i := range c.Issues {
		c.Issues[i].Index = 0
		c.Issues[i].Side = "source"
	}
	sort.Slice(c.Issues, func(i, j int) bool { return encoded(c.Issues[i]) < encoded(c.Issues[j]) })
	for i := range c.Issues {
		c.Issues[i].Index = int64(i)
	}
	return c, nil
}
func encoded(v any) string { b, _ := json.Marshal(v); return string(b) }
func sortRefs(refs []sc.Ref) {
	sort.Slice(refs, func(i, j int) bool { return refKey(refs[i]) < refKey(refs[j]) })
}
func normalize(v reflect.Value) {
	if v.Kind() == reflect.Pointer {
		if !v.IsNil() {
			normalize(v.Elem())
		}
		return
	}
	switch v.Kind() {
	case reflect.Struct:
		for i := 0; i < v.NumField(); i++ {
			normalize(v.Field(i))
		}
		if v.Type() == reflect.TypeFor[sc.Expression]() {
			expression := v.Addr().Interface().(*sc.Expression)
			sortRefs(expression.Dependencies.Items)
		}
	case reflect.Slice:
		for i := 0; i < v.Len(); i++ {
			normalize(v.Index(i))
		}
		if v.IsNil() {
			v.Set(reflect.MakeSlice(v.Type(), 0, 0))
		}
		switch v.Type().Elem() {
		case reflect.TypeFor[sc.Option](), reflect.TypeFor[sc.Dependency](), reflect.TypeFor[sc.TypeCollation](), reflect.TypeFor[sc.TypeFunction](), reflect.TypeFor[sc.TypeOperator](), reflect.TypeFor[sc.Constraint]():
			sort.SliceStable(v.Interface(), func(i, j int) bool { return encoded(v.Index(i).Interface()) < encoded(v.Index(j).Interface()) })
		case reflect.TypeFor[sc.Index]():
			sort.SliceStable(v.Interface(), func(i, j int) bool {
				return refKey(v.Index(i).Interface().(sc.Index).Ref) < refKey(v.Index(j).Interface().(sc.Index).Ref)
			})
		case reflect.TypeFor[sc.Column]():
			sort.SliceStable(v.Interface(), func(i, j int) bool {
				a, b := v.Index(i).Interface().(sc.Column), v.Index(j).Interface().(sc.Column)
				if a.Ordinal.State == "known" && a.Ordinal.Value != nil && b.Ordinal.State == "known" && b.Ordinal.Value != nil && *a.Ordinal.Value != *b.Ordinal.Value {
					return *a.Ordinal.Value < *b.Ordinal.Value
				}
				return refKey(a.Ref) < refKey(b.Ref)
			})
		}
	}
}
func factOrCollection(v reflect.Value) bool {
	return strings.HasPrefix(v.Type().Name(), "Fact[") || strings.HasPrefix(v.Type().Name(), "Collection[")
}

func validStrings(v reflect.Value) bool {
	switch v.Kind() {
	case reflect.Pointer:
		if !v.IsNil() {
			return validStrings(v.Elem())
		}
	case reflect.String:
		return utf8.ValidString(v.String()) && !strings.ContainsRune(v.String(), 0)
	case reflect.Struct:
		for i := 0; i < v.NumField(); i++ {
			if !validStrings(v.Field(i)) {
				return false
			}
		}
	case reflect.Slice:
		for i := 0; i < v.Len(); i++ {
			if !validStrings(v.Index(i)) {
				return false
			}
		}
	}
	return true
}
