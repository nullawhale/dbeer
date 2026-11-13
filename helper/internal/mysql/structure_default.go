package mysql

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"math/big"
)

func structureDefaultMatches(c sc.Column, want tableedit.Default) bool {
	return structureDefaultMatchesFacts(c, want, nil)
}
func structureDefaultMatchesFacts(c sc.Column, want tableedit.Default, facts *tableedit.Facts) bool {
	if c.Default.Value == nil {
		return false
	}
	d := c.Default.Value
	switch want.Kind {
	case "none":
		return d.Kind == "none" || c.Nullable.Value != nil && *c.Nullable.Value && d.Kind == "sqlNull"
	case "expression":
		return d.Kind == "expression" && d.Expression != nil && want.Value != nil && tableedit.SameCatalogExpression("mysql", d.Expression.Text, *want.Value, facts)
	case "null":
		return d.Kind == "sqlNull"
	case "text":
		return d.Kind == "literal" && d.Value != nil && want.Value != nil && *d.Value == *want.Value
	case "numeric":
		if d.Kind != "literal" || d.Value == nil || want.Value == nil {
			return false
		}
		a, ok := new(big.Rat).SetString(*d.Value)
		b, other := new(big.Rat).SetString(*want.Value)
		return ok && other && a.Cmp(b) == 0
	}
	return false
}
