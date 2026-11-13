package sqlite

import (
	"encoding/json"
	"strings"

	"dbeer/helper/internal/protocol"
)

func sqliteColumnComparison(native string) protocol.CatalogColumnComparison {
	// The JOIN renderer uses target.column = +source.column, so SQLite itself
	// applies the target column's actual collation and affinity.
	upper := strings.ToUpper(native)
	if upper == "ANY" {
		return protocol.CatalogColumnComparison{Kind: "unknown", BaseType: "any"}
	}
	affinity := "numeric"
	switch {
	case strings.Contains(upper, "INT"):
		affinity = "integer"
	case strings.Contains(upper, "CHAR"), strings.Contains(upper, "CLOB"), strings.Contains(upper, "TEXT"):
		affinity = "text"
	case upper == "" || strings.Contains(upper, "BLOB"):
		affinity = "blob"
	case strings.Contains(upper, "REAL"), strings.Contains(upper, "FLOA"), strings.Contains(upper, "DOUB"):
		affinity = "real"
	}
	return protocol.CatalogColumnComparison{Kind: "native", BaseType: affinity}
}

func sqliteComparisonJSON(native string) string {
	data, _ := json.Marshal(sqliteColumnComparison(native))
	return string(data)
}
