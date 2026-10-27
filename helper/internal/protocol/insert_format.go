package protocol

import (
	"bytes"
	"encoding/json"
	"io"
)

const MaxInsertRows = 1000
const MaxInsertColumns = 4096
const MaxInsertCells = 100000
const MaxInsertBytes = 8 * 1024 * 1024

// InsertFormatRequest contains only a deliberately chosen target and loaded
// values. It has no connection, session or executable SQL fields.
type InsertFormatRequest struct {
	Engine  string               `json:"engine"`
	Schema  string               `json:"schema"`
	Table   string               `json:"table"`
	Columns []InsertFormatColumn `json:"columns"`
	Rows    [][]CellValue        `json:"rows"`
}

type InsertFormatColumn struct {
	Name string `json:"name"`
}

func (request InsertFormatRequest) Valid() bool {
	if (request.Engine != "postgresql" && request.Engine != "mysql") || (request.Schema != "" && !changeNameValid(request.Schema)) || !changeNameValid(request.Table) ||
		len(request.Columns) == 0 || len(request.Columns) > MaxInsertColumns || len(request.Rows) == 0 || len(request.Rows) > MaxInsertRows ||
		len(request.Columns)*len(request.Rows) > MaxInsertCells {
		return false
	}
	seen := make(map[string]bool, len(request.Columns))
	size := len(request.Schema) + len(request.Table)
	for _, column := range request.Columns {
		if !changeNameValid(column.Name) || seen[column.Name] {
			return false
		}
		seen[column.Name] = true
		size += len(column.Name)
	}
	for _, row := range request.Rows {
		if len(row) != len(request.Columns) {
			return false
		}
		for _, cell := range row {
			if !cell.Valid(true) {
				return false
			}
			if cell.Value != nil {
				size += len(*cell.Value)
			}
			if size > MaxInsertBytes {
				return false
			}
		}
	}
	return true
}

func parseInsertFormat(raw json.RawMessage) (InsertFormatRequest, bool) {
	var request InsertFormatRequest
	if !uniqueObjectKeys(raw) {
		return request, false
	}
	root, ok := changesObject(raw, "engine|schema|table|columns|rows", "engine", "schema", "table", "columns", "rows")
	if !ok {
		return request, false
	}
	var columns []json.RawMessage
	var rows [][]json.RawMessage
	if json.Unmarshal(root["columns"], &columns) != nil || json.Unmarshal(root["rows"], &rows) != nil {
		return request, false
	}
	for _, column := range columns {
		if _, ok := changesObject(column, "name", "name"); !ok {
			return request, false
		}
	}
	for _, row := range rows {
		for _, cell := range row {
			fields, ok := changesObject(cell, "kind|value", "kind")
			if !ok {
				return request, false
			}
			// null and DEFAULT have no payload; explicit JSON null is not a
			// second spelling for an absent typed value.
			if _, exists := fields["value"]; exists && !required(fields, "value") {
				return request, false
			}
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil {
		return request, false
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return request, false
	}
	return request, request.Valid()
}
