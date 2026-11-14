package mysql

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"fmt"
	"strings"
)

func validateMySQLIndexDefinition(b tableedit.Baseline, x tableedit.IndexDefinition) error {
	method := tableedit.CanonicalIndexMethod("mysql", x.Method)
	if method == "hash" {
		return fmt.Errorf("InnoDB cannot retain a HASH index: MySQL normalizes USING HASH to BTREE. HASH requires a different table engine, outside this ordinary InnoDB editor.")
	}
	if method != "btree" && method != "fulltext" && method != "spatial" {
		return fmt.Errorf("This InnoDB index type is unavailable; choose BTREE, FULLTEXT or SPATIAL.")
	}
	if len(x.Includes) > 0 || x.Predicate != nil || x.NullsDistinct != nil && !*x.NullsDistinct {
		return fmt.Errorf("MySQL has no INCLUDE, partial-index predicate or NULLS NOT DISTINCT index option.")
	}
	if method == "spatial" && len(x.Terms) != 1 {
		return fmt.Errorf("An InnoDB SPATIAL index requires one spatial column.")
	}
	for _, term := range x.Terms {
		if term.Opclass != nil || term.Collation != nil || term.NullsFirst != nil || len(term.Options) > 0 {
			return fmt.Errorf("MySQL index terms have no operator-class, COLLATE, NULL ordering or operator-class parameter clause.")
		}
		if method != "btree" && (term.Expression != nil || term.PrefixLength != nil || term.Descending != nil) {
			return fmt.Errorf("FULLTEXT/SPATIAL indexes require direct columns without prefix, expression or direction clauses.")
		}
		if term.Expression != nil {
			if _, err := tableedit.ExpressionSlot("mysql", *term.Expression); err != nil {
				return err
			}
			if term.PrefixLength != nil {
				return fmt.Errorf("MySQL functional key parts cannot have a prefix length.")
			}
		}
		if term.Column != nil {
			c, found := tableedit.FindColumn(b, *term.Column)
			if !found || c.Type.Value == nil {
				return tableedit.ErrUnsupported
			}
			typ := strings.ToLower(c.Type.Value.Ref.Name)
			text := typ == "char" || typ == "varchar" || strings.HasSuffix(typ, "text")
			bytes := typ == "binary" || typ == "varbinary" || strings.HasSuffix(typ, "blob")
			if term.PrefixLength != nil && !text && !bytes {
				return fmt.Errorf("MySQL prefix lengths require a character or binary string column.")
			}
			if method == "fulltext" && !text {
				return fmt.Errorf("MySQL FULLTEXT indexes require CHAR, VARCHAR or TEXT columns.")
			}
			if method == "spatial" && (!spatialType(typ) || c.Nullable.Value == nil || *c.Nullable.Value) {
				return fmt.Errorf("MySQL SPATIAL indexes require a NOT NULL spatial column.")
			}
		}
	}
	for _, option := range x.Options {
		if option.Name != "comment" {
			return fmt.Errorf("This index option has no complete structured InnoDB metadata reader; only COMMENT is currently exposed. No option is silently ignored.")
		}
	}
	return nil
}
func renderMySQLIndex(ctx context.Context, b tableedit.Baseline, edit tableedit.IndexEdit) (string, error) {
	if edit.Definition == nil || b.Facts == nil {
		return "", tableedit.ErrInvalid
	}
	x := tableedit.IndexFacts("mysql", b.Target, edit.Name, edit.Unique, *edit.Definition)
	r := myDefinition{w: &sc.DefinitionWriter{Context: ctx}, engine: sc.Known(b.Facts.EngineContext), authored: map[*sc.Expression]bool{}}
	for _, term := range x.Keys.Items {
		if term.Expression.Value != nil {
			r.authored[term.Expression.Value] = true
		}
	}
	r.w.Write("CREATE ")
	method := tableedit.CanonicalIndexMethod("mysql", edit.Definition.Method)
	if method == "fulltext" || method == "spatial" {
		r.w.Write(strings.ToUpper(method) + " ")
	} else if edit.Unique {
		r.w.Write("UNIQUE ")
	}
	r.w.Write("INDEX ")
	r.identifier(edit.Name)
	r.w.Write(" ON ")
	r.ref(sc.Ref{Kind: "table", Schema: b.Target.Schema, Name: b.Target.Table})
	r.w.Write(" ")
	r.indexKeys(x)
	r.indexOptions(x)
	r.w.Write(";")
	out, err := r.w.Finish()
	if err != nil {
		return "", err
	}
	if out.Limited {
		return "", fmt.Errorf("The index definition cannot be rendered completely within the supported bounds.")
	}
	return out.SQL, nil
}
