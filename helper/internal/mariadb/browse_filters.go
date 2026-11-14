package mariadb

import (
	"dbeer/helper/internal/browsevalue"
	"dbeer/helper/internal/datatransfer"
	"dbeer/helper/internal/protocol"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"math"
	"strconv"
	"strings"
	"time"
)

// Operands are bounded data encoded as hexadecimal literals. The executed and
// standalone queries use exactly the same predicate, independent of SQL mode.
func mariaDBBrowsePredicate(r protocol.CatalogRequest, actual map[string]string) (string, error) {
	if _, valid := r.EffectiveFilterExpression(); !valid {
		return "", errors.New("Invalid native browse filter expression.")
	}
	var compile func(protocol.CatalogFilterExpression) (string, error)
	compile = func(e protocol.CatalogFilterExpression) (string, error) {
		if e.Kind == "condition" {
			return mariaDBBrowseCondition(*e.Condition, actual)
		}
		parts := []string{}
		for _, c := range e.Children {
			s, err := compile(c)
			if err != nil {
				return "", err
			}
			parts = append(parts, s)
		}
		return "(" + strings.Join(parts, " "+strings.ToUpper(e.Kind)+" ") + ")", nil
	}
	if r.FilterExpression != nil {
		return compile(*r.FilterExpression)
	}
	parts := []string{}
	for _, f := range r.Filters {
		s, e := mariaDBBrowseCondition(f, actual)
		if e != nil {
			return "", e
		}
		parts = append(parts, s)
	}
	return strings.Join(parts, " AND "), nil
}
func mariaDBBrowseCondition(f protocol.CatalogFilter, actual map[string]string) (string, error) {
	fail := func() (string, error) {
		return "", errors.New("The native filter operand cannot be represented exactly by the selected MariaDB column.")
	}
	kind, ok := actual[f.Column]
	if !ok || f.SQLiteValue != nil {
		return fail()
	}
	column := QuoteIdentifier(f.Column)
	if f.Operator == "isNull" || f.Operator == "isNotNull" {
		if f.Value != nil || f.NativeValue != nil {
			return fail()
		}
		if f.Operator == "isNull" {
			return column + " IS NULL", nil
		}
		return column + " IS NOT NULL", nil
	}
	numeric, bits := false, 0
	switch kind {
	case "tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric":
		numeric = true
	case "float":
		numeric, bits = true, 32
	case "double":
		numeric, bits = true, 64
	}
	binary := mariaDBBinaryType(kind) || kind == "enumBinary" || kind == "setBinary"
	value := f.Value
	if f.NativeValue != nil {
		v, e := browsevalue.Server(*f.NativeValue, browsevalue.Target{Binary: binary, Numeric: numeric, FloatBits: bits})
		if e != nil {
			return fail()
		}
		value = v.Value
	}
	if value == nil || len(*value) > protocol.NativeCellFilterValueLimit {
		return fail()
	}
	literal := ""
	if binary {
		raw, e := base64.StdEncoding.DecodeString(*value)
		if e != nil {
			return fail()
		}
		literal = "X'" + hex.EncodeToString(raw) + "'"
		if mariaDBSpatialIndexKind(kind) {
			column = "UNHEX(HEX(" + column + "))"
		}
	} else {
		text := *value
		if numeric && bits == 0 {
			canonical, precision, scale, e := datatransfer.Decimal(text)
			if e != nil || precision > 65 || scale > 38 {
				return fail()
			}
			literal = "CAST(CONVERT(X'" + hex.EncodeToString([]byte(canonical)) + "' USING utf8mb4) AS DECIMAL(65," + strconv.Itoa(scale) + "))"
		} else if bits != 0 {
			n, e := strconv.ParseFloat(text, 64)
			if e != nil || math.IsInf(n, 0) || math.IsNaN(n) {
				return fail()
			}
			literal = "CAST(CONVERT(X'" + hex.EncodeToString([]byte(text)) + "' USING utf8mb4) AS DOUBLE)"
		} else {
			if kind == "timestamp" {
				if f.NativeValue != nil && f.NativeValue.SourceEngine != "mariadb" && f.NativeValue.SourceEngine != "mysql" {
					return fail()
				}
				t, e := time.Parse("2006-01-02 15:04:05.999999", text)
				if e != nil || t.Year() < 1000 {
					return fail()
				}
				text = t.Format("2006-01-02 15:04:05.000000")
				column = MariaDBStableProjection(f.Column, kind)
			}
			literal = "CONVERT(X'" + hex.EncodeToString([]byte(text)) + "' USING utf8mb4)"
		}
	}
	if f.Operator == "contains" {
		if numeric {
			return fail()
		}
		return "LOCATE(" + literal + ", " + column + ") > 0", nil
	}
	op := map[string]string{"eq": "=", "ne": "<>", "lt": "<", "lte": "<=", "gt": ">", "gte": ">="}[f.Operator]
	if op == "" {
		return fail()
	}
	return column + " " + op + " " + literal, nil
}
