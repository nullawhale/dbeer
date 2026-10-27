// Package insertformat assembles bounded offline INSERT statements. Identifier
// and value syntax belongs to the selected database adapter.
package insertformat

import (
	"errors"
	"strings"

	"dbeer/helper/internal/protocol"
)

var ErrInvalid = errors.New("The INSERT formatting request is invalid.")
var ErrTooLarge = errors.New("The formatted INSERT statements exceed the copy size limit.")
var ErrTextNUL = errors.New("PostgreSQL text values cannot contain a zero byte. Choose a binary value or another target dialect.")

func Format(request protocol.InsertFormatRequest, quote func(string) string, literal func(protocol.CellValue) (string, error)) (string, error) {
	if !request.Valid() {
		return "", ErrInvalid
	}
	names := make([]string, len(request.Columns))
	for index, column := range request.Columns {
		names[index] = quote(column.Name)
	}
	target := quote(request.Table)
	if request.Schema != "" {
		target = quote(request.Schema) + "." + target
	}
	prefix := "INSERT INTO " + target + " (" + strings.Join(names, ", ") + ") VALUES ("
	var result strings.Builder
	for rowIndex, row := range request.Rows {
		if rowIndex > 0 {
			result.WriteByte('\n')
		}
		if result.Len()+len(prefix)+3 > protocol.MaxInsertBytes {
			return "", ErrTooLarge
		}
		result.WriteString(prefix)
		for index, cell := range row {
			value, err := literal(cell)
			if err != nil {
				return "", err
			}
			if result.Len()+len(value)+4 > protocol.MaxInsertBytes {
				return "", ErrTooLarge
			}
			if index > 0 {
				result.WriteString(", ")
			}
			result.WriteString(value)
		}
		result.WriteString(");")
	}
	return result.String(), nil
}
