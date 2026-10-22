package postgres

import (
	"encoding/base64"
	"encoding/hex"
	"strings"

	"dbeer/helper/internal/insertformat"
	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

// FormatInserts is entirely offline. Text remains an exact SQL string literal;
// the explicitly chosen destination column controls any server-side coercion.
func FormatInserts(request protocol.InsertFormatRequest) (string, error) {
	if request.Engine != "postgresql" {
		return "", insertformat.ErrInvalid
	}
	return insertformat.Format(request, func(name string) string { return pgx.Identifier{name}.Sanitize() }, insertLiteral)
}

func insertLiteral(cell protocol.CellValue) (string, error) {
	switch cell.Kind {
	case "null":
		return "NULL", nil
	case "default":
		return "DEFAULT", nil
	case "binary":
		value, err := base64.StdEncoding.DecodeString(*cell.Value)
		if err != nil {
			return "", insertformat.ErrInvalid
		}
		return "pg_catalog.decode('" + hex.EncodeToString(value) + "', 'hex')", nil
	case "text":
		if strings.ContainsRune(*cell.Value, 0) {
			return "", insertformat.ErrTextNUL
		}
		value := strings.ReplaceAll(*cell.Value, `\`, `\\`)
		value = strings.ReplaceAll(value, "'", "''")
		return "E'" + value + "'", nil
	default:
		return "", insertformat.ErrInvalid
	}
}
