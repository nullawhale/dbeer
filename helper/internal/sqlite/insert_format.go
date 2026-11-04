package sqlite

import (
	"encoding/base64"
	"encoding/hex"

	"dbeer/helper/internal/insertformat"
	"dbeer/helper/internal/protocol"
)

func FormatInserts(r protocol.InsertFormatRequest) (string, error) {
	if r.Engine != "sqlite" || !r.Valid() {
		return "", insertformat.ErrInvalid
	}
	if r.SQLiteValues != nil {
		rows := make([][]protocol.CellValue, len(r.Rows))
		for i, row := range r.SQLiteValues {
			rows[i] = make([]protocol.CellValue, len(row))
			for j, v := range row {
				if v.Type == "null" {
					rows[i][j] = protocol.CellValue{Kind: "null"}
				} else {
					suffix := map[string]string{"integer": "Integer", "real": "Real", "text": "Text", "blob": "Blob"}[v.Type]
					payload := v.Value
					rows[i][j] = protocol.CellValue{Kind: "sqlite" + suffix, Value: &payload}
				}
			}
		}
		r.Rows = rows
	}
	return insertformat.Format(r, quote, func(c protocol.CellValue) (string, error) {
		switch c.Kind {
		case "null":
			return "NULL", nil
		case "default":
			return "", insertformat.ErrInvalid
		case "text":
			return "CAST(X'" + hex.EncodeToString([]byte(*c.Value)) + "' AS TEXT)", nil
		case "binary", "sqliteText", "sqliteBlob":
			b, e := base64.StdEncoding.DecodeString(*c.Value)
			if e != nil {
				return "", e
			}
			v := "X'" + hex.EncodeToString(b) + "'"
			if c.Kind == "sqliteText" {
				v = "CAST(" + v + " AS TEXT)"
			}
			return v, nil
		case "sqliteInteger":
			return *c.Value, nil
		case "sqliteReal":
			return exactRealSQL(*c.Value)
		default:
			return "", insertformat.ErrInvalid
		}
	})
}
