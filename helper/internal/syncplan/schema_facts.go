package syncplan

import (
	"reflect"

	sc "dbeer/helper/internal/schemacompare"
)

// SchemaFactsReason is deliberately stricter than a readable definition: a
// partial preview cannot become executable SQL. Expressions need a dedicated
// dialect transformation and are never copied or identifier-rewritten here.
func SchemaFactsReason(value any) string {
	var inspect func(reflect.Value) string
	inspect = func(v reflect.Value) string {
		if !v.IsValid() {
			return ""
		}
		if v.Type() == reflect.TypeOf(sc.Expression{}) {
			return "Expression-bearing changes require manual SQL and dependency review."
		}
		if v.Type() == reflect.TypeOf(sc.TypeUse{}) {
			u := v.Interface().(sc.TypeUse)
			if u.Modifiers.Value != nil && u.Ref.Schema != "pg_catalog" && (u.Modifiers.Value.Raw != nil || u.Modifiers.Value.SQL != nil) {
				return "User-defined type modifiers require manual dialect review."
			}
		}
		if v.Kind() == reflect.Struct {
			if state := v.FieldByName("State"); state.IsValid() && state.Kind() == reflect.String && state.String() != "known" && state.String() != "observed" {
				return "Required captured facts are unavailable."
			}
			if complete := v.FieldByName("Complete"); complete.IsValid() && complete.Kind() == reflect.Bool && !complete.Bool() {
				return "Required captured collections are incomplete."
			}
			if v.Type() == reflect.TypeOf(sc.Identity{}) && v.Interface().(sc.Identity).Kind != "none" {
				return "Identity and auto-increment definitions require manual sequence/key review."
			}
			for i := 0; i < v.NumField(); i++ {
				if reason := inspect(v.Field(i)); reason != "" {
					return reason
				}
			}
		}
		if v.Kind() == reflect.Pointer && !v.IsNil() {
			return inspect(v.Elem())
		}
		if v.Kind() == reflect.Slice {
			for i := 0; i < v.Len(); i++ {
				if reason := inspect(v.Index(i)); reason != "" {
					return reason
				}
			}
		}
		return ""
	}
	return inspect(reflect.ValueOf(value))
}

func SchemaTable(c sc.Capture, ref sc.Ref) (sc.Table, bool) {
	name := ref.Name
	if ref.Table != "" {
		name = ref.Table
	}
	for _, t := range c.Tables {
		if t.Ref.Schema == ref.Schema && t.Ref.Name == name {
			return t, true
		}
	}
	return sc.Table{}, false
}
func SchemaColumn(c sc.Capture, ref sc.Ref) (sc.Column, bool) {
	t, ok := SchemaTable(c, ref)
	if ok {
		for _, col := range t.Columns.Items {
			if col.Ref == ref {
				return col, true
			}
		}
	}
	return sc.Column{}, false
}
