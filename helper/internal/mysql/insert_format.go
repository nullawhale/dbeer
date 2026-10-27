package mysql

import (
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
	"unicode"

	"dbeer/helper/internal/insertformat"
	"dbeer/helper/internal/protocol"
)

var errInsertColumnCollision = errors.New("MySQL target column names must be unique regardless of letter case. Rename the duplicate target mappings.")

// FormatInserts uses hexadecimal text with an explicit character set so its
// meaning is independent of NO_BACKSLASH_ESCAPES, ANSI_QUOTES and client charset.
func FormatInserts(request protocol.InsertFormatRequest) (string, error) {
	if request.Engine != "mysql" || !request.Valid() {
		return "", insertformat.ErrInvalid
	}
	seen := make(map[string]bool, len(request.Columns))
	for _, column := range request.Columns {
		key := insertColumnCaseKey(column.Name)
		if seen[key] {
			return "", errInsertColumnCollision
		}
		seen[key] = true
	}
	return insertformat.Format(request, QuoteIdentifier, insertLiteral)
}

// Select a stable member of each Unicode simple-fold cycle. This has the same
// equality semantics as strings.EqualFold without comparing every pair of
// mapped columns or normalizing their original Unicode spelling.
func insertColumnCaseKey(name string) string {
	return strings.Map(func(value rune) rune {
		key := value
		for next := unicode.SimpleFold(value); next != value; next = unicode.SimpleFold(next) {
			if next < key {
				key = next
			}
		}
		return key
	}, name)
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
		return "X'" + hex.EncodeToString(value) + "'", nil
	case "text":
		return "CONVERT(X'" + hex.EncodeToString([]byte(*cell.Value)) + "' USING utf8mb4)", nil
	default:
		return "", insertformat.ErrInvalid
	}
}
