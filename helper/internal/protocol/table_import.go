package protocol

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"unicode/utf8"
)

const TableImportCapability = "tableImportV1"
const MaxImportRows = 10000
const MaxImportColumns = 256
const MaxImportCells = 100000
const MaxImportValueBytes = 4 * 1024 * 1024

type TableImportRequest struct {
	Schema      string        `json:"schema"`
	Table       string        `json:"table"`
	Fingerprint string        `json:"fingerprint,omitempty"`
	Columns     []string      `json:"columns,omitempty"`
	Rows        [][]CellValue `json:"rows,omitempty"`
}

type TableImportColumn struct {
	Name       string `json:"name"`
	NativeType string `json:"nativeType"`
	Nullable   bool   `json:"nullable"`
	HasDefault bool   `json:"hasDefault"`
	Generated  bool   `json:"generated"`
	Binary     bool   `json:"binary"`
}

type TableImportReply struct {
	Columns     []TableImportColumn `json:"columns,omitempty"`
	Fingerprint string              `json:"fingerprint,omitempty"`
	RowCount    *int                `json:"rowCount,omitempty"`
	SQL         string              `json:"sql,omitempty"`
	Row         *int                `json:"row,omitempty"`
}

func (request TableImportRequest) Valid(kind string) bool {
	if !changeNameValid(request.Schema) || !changeNameValid(request.Table) {
		return false
	}
	if kind == "import.describe" {
		return request.Fingerprint == "" && request.Columns == nil && request.Rows == nil
	}
	if kind != "import.preview" && kind != "import.apply" {
		return false
	}
	if len(request.Fingerprint) != 64 {
		return false
	}
	for _, c := range request.Fingerprint {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	if len(request.Columns) == 0 || len(request.Columns) > MaxImportColumns || len(request.Rows) == 0 || len(request.Rows) > MaxImportRows || len(request.Rows)*len(request.Columns) > MaxImportCells {
		return false
	}
	seen, total := map[string]bool{}, 0
	for _, column := range request.Columns {
		if !changeNameValid(column) || seen[column] {
			return false
		}
		seen[column] = true
	}
	for _, row := range request.Rows {
		if len(row) != len(request.Columns) {
			return false
		}
		for _, cell := range row {
			if !cell.Valid(false) {
				return false
			}
			if cell.Value != nil {
				total += len(*cell.Value)
				if total > MaxImportValueBytes || !utf8.ValidString(*cell.Value) || strings.ContainsRune(*cell.Value, 0) {
					return false
				}
				if cell.Kind == "binary" {
					decoded, err := base64.StdEncoding.DecodeString(*cell.Value)
					if err != nil || base64.StdEncoding.EncodeToString(decoded) != *cell.Value {
						return false
					}
				}
			}
		}
	}
	return true
}

func parseTableImport(raw json.RawMessage, kind string) (*TableImportRequest, bool) {
	allowed := "schema|table"
	if kind != "import.describe" {
		allowed += "|fingerprint|columns|rows"
	}
	fields, ok := changesObject(raw, allowed, "schema", "table")
	if !ok {
		return nil, false
	}
	var request TableImportRequest
	if !stringField(fields, "schema", &request.Schema) || !stringField(fields, "table", &request.Table) {
		return nil, false
	}
	if kind != "import.describe" {
		if !stringField(fields, "fingerprint", &request.Fingerprint) || !required(fields, "columns") || !required(fields, "rows") || json.Unmarshal(fields["columns"], &request.Columns) != nil {
			return nil, false
		}
		if len(request.Columns) == 0 || len(request.Columns) > MaxImportColumns {
			return nil, false
		}
		var rows [][]json.RawMessage
		if json.Unmarshal(fields["rows"], &rows) != nil || len(rows) > MaxImportRows || len(rows)*len(request.Columns) > MaxImportCells {
			return nil, false
		}
		request.Rows = make([][]CellValue, len(rows))
		for index, row := range rows {
			if len(row) > MaxImportColumns {
				return nil, false
			}
			for _, cell := range row {
				fields, ok := changesObject(cell, "kind|value", "kind")
				if !ok {
					return nil, false
				}
				var value CellValue
				if !stringField(fields, "kind", &value.Kind) {
					return nil, false
				}
				if value.Kind == "null" {
					if len(fields) != 1 {
						return nil, false
					}
				} else {
					var text string
					if !stringField(fields, "value", &text) {
						return nil, false
					}
					value.Value = &text
				}
				request.Rows[index] = append(request.Rows[index], value)
			}
		}
	}
	return &request, request.Valid(kind)
}
