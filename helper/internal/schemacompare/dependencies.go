package schemacompare

import (
	"reflect"
	"sort"
)

// Retain semantic dependency edges for later planning. No display string or
// database-local address is used to reconstruct this graph.
func linkDependencies(table *Table) {
	edges := map[string]Dependency{}
	declared := table.Dependencies
	for _, edge := range declared.Items {
		edges[refKey(edge.From)+refKey(edge.To)+edge.Kind+edge.State] = edge
	}
	var visit func(reflect.Value, Ref)
	visit = func(v reflect.Value, from Ref) {
		if !v.IsValid() {
			return
		}
		if v.Type() == reflect.TypeOf(Ref{}) {
			to := v.Interface().(Ref)
			if to != from {
				edge := Dependency{From: from, To: to, Kind: "catalogReference", State: "observed"}
				edges[refKey(from)+refKey(to)+edge.Kind+edge.State] = edge
			}
			return
		}
		switch v.Kind() {
		case reflect.Pointer:
			if !v.IsNil() {
				visit(v.Elem(), from)
			}
		case reflect.Struct:
			if ref := nodeRef(v); ref != nil {
				if *ref != from {
					edge := Dependency{From: from, To: *ref, Kind: "catalogReference", State: "observed"}
					edges[refKey(from)+refKey(*ref)+edge.Kind+edge.State] = edge
				}
				from = *ref
			}
			for i := 0; i < v.NumField(); i++ {
				if v.Type().Field(i).Name != "Dependencies" && v.Type().Field(i).Name != "Ref" {
					visit(v.Field(i), from)
				}
			}
			// Expression dependencies are observations rather than graph node ownership.
			if v.Type() == reflect.TypeOf(Expression{}) {
				for _, ref := range v.Interface().(Expression).Dependencies.Items {
					visit(reflect.ValueOf(ref), from)
				}
			}
		case reflect.Slice:
			for i := 0; i < v.Len(); i++ {
				visit(v.Index(i), from)
			}
		}
	}
	visit(reflect.ValueOf(*table), table.Ref)
	keys := make([]string, 0, len(edges))
	for k := range edges {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	table.Dependencies = Complete[Dependency](nil)
	if declared.State != "" {
		table.Dependencies.Complete = declared.Complete
		table.Dependencies.State = declared.State
		table.Dependencies.Code = declared.Code
	}
	for _, key := range keys {
		table.Dependencies.Items = append(table.Dependencies.Items, edges[key])
	}
}
