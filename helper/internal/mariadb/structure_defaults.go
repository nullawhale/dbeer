package mariadb

import (
	"dbeer/helper/internal/tableedit"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
	"unicode/utf8"
)

// I_S may print replacement characters for a stored literal. Display the exact
// witnessed fact; never turn that lossy spelling into a portable original.
func mariaDBObservedDefaults(b *tableedit.Baseline) error {
	for i := range b.Columns {
		c, ok := tableedit.FindColumn(*b, b.Columns[i].Name)
		if !ok || c.Default.Value == nil || c.Default.Value.Kind != "literal" || c.Default.Value.Value == nil {
			continue
		}
		d := c.Default.Value
		value := *d.Value
		sql := ""
		switch d.Encoding {
		case "base64":
			raw, e := base64.StdEncoding.DecodeString(value)
			if e != nil {
				return errors.New("Native default byte evidence is invalid.")
			}
			sql = "X'" + hex.EncodeToString(raw) + "'"
		case "text":
			if !utf8.ValidString(value) {
				return errors.New("Native default text evidence is invalid.")
			}
			numeric := c.Type.Value != nil && mariaCatalogNumber.MatchString(value)
			if numeric {
				switch c.Type.Value.Ref.Name {
				case "tinyint", "smallint", "mediumint", "int", "bigint", "float", "double", "decimal", "numeric", "bit", "year":
				default:
					numeric = false
				}
			}
			if numeric {
				sql = value
			} else {
				literal := true
				for _, r := range value {
					if r == '\\' || r < 32 || r == 127 {
						literal = false
						break
					}
				}
				if literal {
					sql = "'" + strings.ReplaceAll(value, "'", "''") + "'"
				} else {
					sql = "CONVERT(X'" + hex.EncodeToString([]byte(value)) + "' USING utf8mb4)"
				}
			}
		default:
			return errors.New("The exact native default literal encoding is unsupported.")
		}
		if len(sql) > 65536 {
			return errors.New("The exact native default display exceeds the supported bound.")
		}
		b.Columns[i].DefaultExpression = &sql
	}
	return nil
}
