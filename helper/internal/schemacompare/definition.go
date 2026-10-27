package schemacompare

import (
	"context"
	"reflect"
	"strings"

	"dbeer/helper/internal/textdiff"
)

// Definition is a readable definition preview, never an executable migration.
// Database adapters own its SQL grammar; comparison owns selection and mapping.
type Definition struct {
	SQL     string
	Limited bool
}
type DefinitionRenderer func(context.Context, Capture, Ref) (Definition, error)

// DefinitionWriter bounds adapter output and records unavailable metadata in
// SQL comments. Values are never substituted for unknown facts.
type DefinitionWriter struct {
	Context context.Context
	Text    strings.Builder
	Limited bool
	notes   []string
	seen    map[string]bool
}

func (w *DefinitionWriter) Full() bool {
	if w.Text.Len() >= textdiff.MaxTextBytes {
		w.Limited = true
		return true
	}
	return w.Context.Err() != nil
}
func (w *DefinitionWriter) Write(s string) {
	remaining := textdiff.MaxTextBytes - w.Text.Len()
	if len(s) > remaining {
		w.Limited = true
		s = s[:max(0, remaining)]
	}
	w.Text.WriteString(s)
}
func (w *DefinitionWriter) Note(s string) {
	w.Limited = true
	s = strings.NewReplacer("\n", " ", "\r", " ").Replace(s)
	if len(s) > 384 {
		s = strings.ToValidUTF8(s[:384], "") + "…"
	}
	if w.seen == nil {
		w.seen = map[string]bool{}
	}
	if !w.seen[s] && len(w.notes) < 12 {
		w.notes = append(w.notes, "-- "+s+"\n")
		w.seen[s] = true
	}
}
func (w *DefinitionWriter) Finish() (Definition, error) {
	if e := w.Context.Err(); e != nil {
		return Definition{}, e
	}
	for _, note := range w.notes {
		w.Write(note)
	}
	if w.Limited && w.Text.Len() == textdiff.MaxTextBytes {
		// Leave truncation to textdiff, whose UTF-8-aware fallback never splits
		// a Unicode scalar. Its explicit limited status remains visible.
		return Definition{strings.ToValidUTF8(w.Text.String(), ""), true}, nil
	}
	return Definition{w.Text.String(), w.Limited}, nil
}
func DefinitionFact[T any](w *DefinitionWriter, label string, f Fact[T]) *T {
	if f.State != "known" {
		w.Note("Unavailable " + label + " (" + f.State + " " + f.Code + ").")
		return nil
	}
	return f.Value
}
func DefinitionItems[T any](w *DefinitionWriter, label string, c Collection[T]) []T {
	if !c.Complete || c.State != "known" {
		w.Note("Incomplete " + label + " (" + c.State + " " + c.Code + ").")
	}
	return c.Items
}

func definitionRoot(c Capture, ref Ref) (Capture, Ref, bool) {
	selected := Capture{Context: c.Context}
	member := ref.Table != ""
	if member {
		ref = Ref{Kind: "table", Schema: ref.Schema, Name: ref.Table}
	}
	switch ref.Kind {
	case "table":
		for _, t := range c.Tables {
			if t.Ref == ref {
				selected.Tables = []Table{t}
				return selected, ref, true
			}
		}
		if member {
			for _, t := range c.Types {
				if t.Ref.Schema == ref.Schema && t.Ref.Name == ref.Name {
					selected.Types = []TypeDefinition{t}
					return selected, t.Ref, true
				}
			}
		}
	case "type":
		for _, t := range c.Types {
			if t.Ref == ref {
				selected.Types = []TypeDefinition{t}
				return selected, ref, true
			}
		}
	case "sequence":
		for _, s := range c.Sequences {
			if s.Ref == ref {
				selected.Sequences = []Sequence{s}
				return selected, ref, true
			}
		}
	case "schema":
		for _, i := range c.Inventories {
			if i.Schema == ref.Name {
				selected.Inventories = []Inventory{i}
				return selected, ref, i.Existence != "absent"
			}
		}
		return selected, ref, true
	case "capture":
		return selected, ref, true
	}
	return selected, ref, false
}

// Copy only the selected object graph. Strings remain immutable and shared;
// pointers and slices are copied before typed identifier mapping is applied.
func copyDefinition(v reflect.Value) reflect.Value {
	switch v.Kind() {
	case reflect.Pointer:
		if v.IsNil() {
			return reflect.Zero(v.Type())
		}
		out := reflect.New(v.Type().Elem())
		out.Elem().Set(copyDefinition(v.Elem()))
		return out
	case reflect.Slice:
		if v.IsNil() {
			return reflect.Zero(v.Type())
		}
		out := reflect.MakeSlice(v.Type(), v.Len(), v.Len())
		for i := 0; i < v.Len(); i++ {
			out.Index(i).Set(copyDefinition(v.Index(i)))
		}
		return out
	case reflect.Struct:
		out := reflect.New(v.Type()).Elem()
		for i := 0; i < v.NumField(); i++ {
			out.Field(i).Set(copyDefinition(v.Field(i)))
		}
		return out
	default:
		return v
	}
}

// TextDiff compares rendered definitions from the frozen typed captures. The
// source uses mapped target identifiers, while arbitrary expression text stays
// byte-exact. Original identifiers remain available on the difference itself.
func (r *Result) TextDiff(ctx context.Context, index int64, render DefinitionRenderer) (textdiff.Diff, error) {
	if index < 0 || index >= int64(len(r.Report.Differences)) {
		return textdiff.Diff{}, ErrInvalid
	}
	if e := ctx.Err(); e != nil {
		return textdiff.Diff{}, e
	}
	difference := r.Report.Differences[index]
	sourceRef, targetRef := difference.SourceRef, difference.TargetRef
	// Missing members still have a parent definition on both sides. Missing
	// whole tables/types retain an absent side instead of fabricating SQL.
	if sourceRef == nil && targetRef != nil && targetRef.Table != "" {
		_, targetRoot, ok := definitionRoot(r.Report.Target, *targetRef)
		if ok {
			for _, table := range r.Report.Source.Tables {
				if r.mappings.mapRef(table.Ref) == targetRoot {
					ref := table.Ref
					sourceRef = &ref
					break
				}
			}
			if sourceRef == nil {
				for _, typ := range r.Report.Source.Types {
					if r.mappings.mapRef(typ.Ref) == targetRoot {
						ref := typ.Ref
						sourceRef = &ref
						break
					}
				}
			}
		}
	}
	if targetRef == nil && sourceRef != nil && sourceRef.Table != "" {
		_, sourceRoot, ok := definitionRoot(r.Report.Source, *sourceRef)
		if ok {
			mapped := r.mappings.mapRef(sourceRoot)
			if _, _, found := definitionRoot(r.Report.Target, mapped); found {
				targetRef = &mapped
			}
		}
	}
	read := func(c Capture, ref *Ref, source bool) (textdiff.Input, error) {
		missing := func() textdiff.Input {
			if difference.Kind == "indeterminate" {
				input := textdiff.Text("-- Definition unavailable in captured metadata.\n")
				input.Limited = true
				return input
			}
			return textdiff.Input{Kind: "absent"}
		}
		if ref == nil {
			return missing(), nil
		}
		selected, root, found := definitionRoot(c, *ref)
		if !found {
			return missing(), nil
		}
		if source {
			selected = copyDefinition(reflect.ValueOf(selected)).Interface().(Capture)
			remap(reflect.ValueOf(&selected).Elem(), r.mappings)
			root = r.mappings.mapRef(root)
			if root.Kind == "schema" {
				for _, p := range r.mappings.Schemas {
					if root.Name == p.Source {
						root.Name = p.Target
						break
					}
				}
			}
		}
		var definition Definition
		var e error
		if render == nil {
			definition = Definition{"-- SQL definition renderer unavailable.\n", true}
		} else {
			definition, e = render(ctx, selected, root)
		}
		if e != nil {
			return textdiff.Input{}, e
		}
		input := textdiff.Text(definition.SQL)
		input.Limited = definition.Limited
		return input, nil
	}
	a, e := read(r.Report.Source, sourceRef, true)
	if e != nil {
		return textdiff.Diff{}, e
	}
	b, e := read(r.Report.Target, targetRef, false)
	if e != nil {
		return textdiff.Diff{}, e
	}
	if a.Kind == "text" && b.Kind == "text" && a.Text == b.Text {
		const note = "-- This property is not represented in SQL; see metadata details.\n"
		a.Text += note
		b.Text += note
		a.TotalBytes = int64(len(a.Text))
		b.TotalBytes = int64(len(b.Text))
		a.Limited = true
		b.Limited = true
	}
	incomplete := a.Limited || b.Limited || difference.Kind == "indeterminate"
	// Missing catalog facts do not prevent exact alignment of the known SQL.
	// Reserve textdiff's coarse fallback for actual input/work/output budgets.
	a.Limited = false
	b.Limited = false
	diff, e := textdiff.Compare(ctx, a, b)
	if e == nil && incomplete && diff.Status == "complete" {
		diff.Status = "limited"
	}
	return diff, e
}
