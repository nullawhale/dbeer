package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"fmt"
	"strings"
)

func (s *Session) prepareAuthoredIndexes(ctx context.Context, b tableedit.Baseline, d tableedit.Draft) ([]tableedit.IndexGuard, error) {
	var guards []tableedit.IndexGuard
	seen := map[string]bool{}
	add := func(kind string, ref tableedit.TypeReference, method string) error {
		key := kind + "\x00" + ref.Schema + "\x00" + ref.Name + "\x00" + method
		if seen[key] {
			return nil
		}
		if len(guards) >= 64 {
			return tableedit.ErrUnsupported
		}
		g, err := resolveIndexGuard(ctx, s.conn, kind, ref, method)
		if err != nil {
			return err
		}
		guards = append(guards, g)
		seen[key] = true
		return nil
	}
	for _, edit := range d.Indexes {
		if edit.Definition == nil {
			continue
		}
		x := *edit.Definition
		method := tableedit.CanonicalIndexMethod("postgresql", x.Method)
		if err := validatePGIndexDefinition(b, edit.Unique, x); err != nil {
			return nil, err
		}
		if err := add("accessMethod", tableedit.TypeReference{Schema: "pg_catalog", Name: method}, ""); err != nil {
			return nil, err
		}
		for _, term := range x.Terms {
			if term.Collation != nil {
				if err := add("collation", *term.Collation, ""); err != nil {
					return nil, err
				}
			}
			if term.Opclass != nil {
				if err := add("opclass", *term.Opclass, method); err != nil {
					return nil, err
				}
			}
		}
	}
	return guards, nil
}
func validatePGIndexDefinition(b tableedit.Baseline, unique bool, x tableedit.IndexDefinition) error {
	method := tableedit.CanonicalIndexMethod("postgresql", x.Method)
	if x.Visible != nil && !*x.Visible {
		return fmt.Errorf("PostgreSQL indexes have no INVISIBLE option.")
	}
	if x.NullsDistinct != nil && !*x.NullsDistinct && (b.Facts == nil || b.Facts.ServerVersion < 150000 || !unique || method != "btree") {
		return fmt.Errorf("NULLS NOT DISTINCT requires a unique PostgreSQL 15+ BTREE index.")
	}
	if unique && method != "btree" {
		return fmt.Errorf("PostgreSQL uniqueness requires the BTREE access method.")
	}
	if (method == "hash" || method == "spgist") && len(x.Terms) > 1 {
		return fmt.Errorf("This PostgreSQL access method supports one key term.")
	}
	if len(x.Includes) > 0 && method != "btree" && method != "gist" && method != "spgist" {
		return fmt.Errorf("INCLUDE requires BTREE, GiST or SP-GiST on supported PostgreSQL versions.")
	}
	for _, term := range x.Terms {
		if term.PrefixLength != nil {
			return fmt.Errorf("PostgreSQL indexes do not have MySQL prefix lengths; author an explicit expression instead.")
		}
		if method != "btree" && (term.Descending != nil || term.NullsFirst != nil) {
			return fmt.Errorf("Explicit direction and NULL ordering require the BTREE access method.")
		}
		if len(term.Options) > 0 && term.Opclass == nil {
			return fmt.Errorf("Operator-class options require an explicitly qualified operator class.")
		}
		if term.Expression != nil {
			if _, err := tableedit.ExpressionSlot("postgresql", *term.Expression); err != nil {
				return err
			}
		}
		if term.Column != nil {
			for _, include := range x.Includes {
				if include == *term.Column {
					return fmt.Errorf("An INCLUDE column cannot repeat a direct key column.")
				}
			}
		}
	}
	if x.Predicate != nil {
		if _, err := tableedit.ExpressionSlot("postgresql", *x.Predicate); err != nil {
			return err
		}
	}
	allowed := map[string]string{"btree": "fillfactor deduplicate_items", "hash": "fillfactor", "gist": "fillfactor buffering", "spgist": "fillfactor", "gin": "fastupdate gin_pending_list_limit", "brin": "pages_per_range autosummarize"}
	if names, known := allowed[method]; known {
		for _, option := range x.Options {
			found := false
			for _, name := range strings.Fields(names) {
				found = found || option.Name == name
			}
			if !found {
				return fmt.Errorf("This storage option is not supported by the selected PostgreSQL access method.")
			}
		}
	}
	return nil
}
func renderPGIndex(ctx context.Context, target tableedit.Target, edit tableedit.IndexEdit) (string, error) {
	if edit.Definition == nil {
		return "", tableedit.ErrInvalid
	}
	x := tableedit.IndexFacts("postgresql", target, edit.Name, edit.Unique, *edit.Definition)
	r := pgDefinition{w: &sc.DefinitionWriter{Context: ctx}, types: map[sc.Ref]sc.TypeDefinition{}}
	r.index(x, sc.Ref{Kind: "table", Schema: target.Schema, Name: target.Table})
	out, err := r.w.Finish()
	if err != nil {
		return "", err
	}
	if out.Limited {
		return "", fmt.Errorf("The index definition cannot be rendered completely within the supported bounds.")
	}
	return strings.TrimSpace(out.SQL), nil
}
