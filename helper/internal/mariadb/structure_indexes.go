package mariadb

import (
	"dbeer/helper/internal/tableedit"
	"errors"
	"strconv"
	"strings"
)

func mariaDBRichIndex(b tableedit.Baseline, edit tableedit.IndexEdit) (string, error) {
	if edit.Definition == nil || !edit.Definition.Valid() || b.Facts == nil {
		return "", tableedit.ErrInvalid
	}
	x := edit.Definition
	method := tableedit.CanonicalIndexMethod("mariadb", x.Method)
	if method == "hash" {
		return "", errors.New("Native InnoDB, MyISAM and Aria tables do not retain a user HASH index; choose a supported index method.")
	}
	if method != "btree" && method != "fulltext" && method != "spatial" {
		return "", errors.New("The selected native table model supports BTREE, FULLTEXT or SPATIAL indexes in this workflow.")
	}
	if len(x.Includes) > 0 || x.Predicate != nil || x.NullsDistinct != nil && !*x.NullsDistinct {
		return "", errors.New("MariaDB has no INCLUDE, partial-index predicate or NULLS NOT DISTINCT index clause.")
	}
	if method == "spatial" && len(x.Terms) != 1 {
		return "", errors.New("A native SPATIAL index requires one spatial column.")
	}
	terms := []string{}
	for _, term := range x.Terms {
		if term.Expression != nil {
			return "", errors.New("MariaDB does not expose MySQL-style functional index key expressions. Author an explicit generated column and index that native column.")
		}
		if term.Column == nil || term.Opclass != nil || term.Collation != nil || term.NullsFirst != nil || len(term.Options) > 0 {
			return "", errors.New("MariaDB index terms have no operator-class, per-term COLLATE, explicit NULL ordering or operator-class option clause.")
		}
		c, ok := tableedit.FindColumn(b, *term.Column)
		if !ok || c.Type.Value == nil {
			return "", tableedit.ErrUnsupported
		}
		kind := strings.ToLower(c.Type.Value.Ref.Name)
		text := kind == "char" || kind == "varchar" || strings.HasSuffix(kind, "text")
		binary := kind == "binary" || kind == "varbinary" || strings.HasSuffix(kind, "blob")
		if term.PrefixLength != nil {
			if !text && !binary {
				return "", errors.New("Native prefix lengths require character or binary string columns.")
			}
			if c.Type.Value.Modifiers.Value == nil {
				return "", tableedit.ErrUnsupported
			}
			if length := c.Type.Value.Modifiers.Value.Length; length != nil && *term.PrefixLength > *length {
				return "", errors.New("The selected prefix exceeds the captured native column length.")
			}
		}
		if method != "btree" && (term.PrefixLength != nil || term.Descending != nil) {
			return "", errors.New("Native FULLTEXT/SPATIAL indexes require direct columns without prefix or direction clauses.")
		}
		if method == "fulltext" && !text {
			return "", errors.New("Native FULLTEXT indexes require CHAR, VARCHAR or TEXT columns.")
		}
		if method == "spatial" && (!mariaDBSpatialIndexKind(kind) || c.Nullable.Value == nil || *c.Nullable.Value) {
			return "", errors.New("Native SPATIAL indexes require a NOT NULL spatial column.")
		}
		sql := QuoteIdentifier(*term.Column)
		if term.PrefixLength != nil {
			sql += "(" + strconv.FormatInt(*term.PrefixLength, 10) + ")"
		}
		if term.Descending != nil {
			if *term.Descending {
				sql += " DESC"
			} else {
				sql += " ASC"
			}
		}
		terms = append(terms, sql)
	}
	keyword := ""
	if method == "fulltext" || method == "spatial" {
		keyword = strings.ToUpper(method) + " "
	}
	sql := "CREATE " + keyword + "INDEX " + QuoteIdentifier(edit.Name) + " ON " + QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(b.Target.Table) + " (" + strings.Join(terms, ", ") + ")"
	if method == "btree" {
		sql += " USING BTREE"
	}
	for _, option := range x.Options {
		if option.Name != "comment" {
			return "", errors.New("This native index option has no complete structured authoring proof; only COMMENT is exposed.")
		}
		for _, r := range option.Value {
			if r == '\\' || r < 32 || r == 127 {
				return "", errors.New("Index comments containing backslashes or control characters require a separate mode-bound native literal proof.")
			}
		}
		sql += " COMMENT '" + strings.ReplaceAll(option.Value, "'", "''") + "'"
	}
	if x.Visible != nil && !*x.Visible {
		sql += " IGNORED"
	}
	return sql + ";", nil
}
func mariaDBSpatialIndexKind(kind string) bool {
	switch kind {
	case "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection":
		return true
	}
	return false
}
