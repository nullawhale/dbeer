package protocol

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"strings"
	"unicode/utf8"
)

const DataTransferCapability = "dataTransferV1"
const MaxTransferColumns = 256
const MaxTransferInputRows = 10000
const MaxTransferInputBytes = 4 << 20
const MaxTransferDiagnostics = 100

type TransferEndpoint struct {
	Connection Connection `json:"connection"`
	Schema     string     `json:"schema"`
	Table      string     `json:"table"`
}
type TransferColumn struct {
	SourceIndex int    `json:"sourceIndex"`
	Name        string `json:"name"`
	Type        string `json:"type"`
	Nullable    bool   `json:"nullable"`
	Precision   int    `json:"precision,omitempty"`
	Scale       int    `json:"scale,omitempty"`
}
type TransferDiagnostic struct {
	Row     int    `json:"row"`
	Column  int    `json:"column"`
	Message string `json:"message"`
}
type TransferRequest struct {
	Mode         string            `json:"mode,omitempty"`
	Source       *TransferEndpoint `json:"source,omitempty"`
	Target       *TransferEndpoint `json:"target,omitempty"`
	Headers      []string          `json:"headers,omitempty"`
	Rows         [][]CellValue     `json:"rows,omitempty"`
	Columns      []TransferColumn  `json:"columns,omitempty"`
	JobID        string            `json:"jobId,omitempty"`
	PlanDigest   string            `json:"planDigest,omitempty"`
	SourceDigest string            `json:"sourceDigest,omitempty"`
	Confirmed    bool              `json:"confirmed,omitempty"`
}
type TransferReply struct {
	JobID          string               `json:"jobId"`
	State          string               `json:"state"`
	Phase          string               `json:"phase"`
	Code           string               `json:"code,omitempty"`
	Message        string               `json:"message,omitempty"`
	Columns        []TransferColumn     `json:"columns,omitempty"`
	Diagnostics    []TransferDiagnostic `json:"diagnostics,omitempty"`
	SQL            string               `json:"sql,omitempty"`
	PlanDigest     string               `json:"planDigest,omitempty"`
	SourceDigest   string               `json:"sourceDigest,omitempty"`
	RowsRead       int64                `json:"rowsRead"`
	RowsWritten    int64                `json:"rowsWritten"`
	Notices        []string             `json:"notices"`
	TableCreated   bool                 `json:"tableCreated"`
	OutcomeUnknown bool                 `json:"outcomeUnknown"`
}

func TransferTypeValid(kind string) bool {
	switch kind {
	case "text", "integer", "decimal", "real", "boolean", "date", "timestamp", "timestampTZ", "json", "binary":
		return true
	}
	return false
}
func (column TransferColumn) Valid() bool {
	if column.SourceIndex < 0 || column.SourceIndex >= MaxTransferColumns || !changeNameValid(column.Name) || !TransferTypeValid(column.Type) {
		return false
	}
	if column.Type == "decimal" {
		return column.Precision >= 1 && column.Precision <= 1000 && column.Scale >= 0 && column.Scale <= column.Precision
	}
	return column.Precision == 0 && column.Scale == 0
}
func (endpoint TransferEndpoint) Valid() bool {
	engine := endpoint.Connection.DatabaseEngine()
	return (engine == "postgresql" || engine == "mysql" || engine == "mariadb") && endpoint.Connection.Valid() &&
		endpoint.Connection.SessionPurpose == "" && changeNameValid(endpoint.Schema) && changeNameValid(endpoint.Table)
}
func transferDigest(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
func (request TransferRequest) Valid(kind string) bool {
	if kind == "transfer.status" || kind == "transfer.cancel" || kind == "transfer.close" || kind == "transfer.apply" {
		if !ValidID(request.JobID) || request.Source != nil || request.Target != nil || request.Mode != "" || request.Headers != nil || request.Rows != nil || request.Columns != nil || request.SourceDigest != "" {
			return false
		}
		if kind == "transfer.apply" {
			return transferDigest(request.PlanDigest) && request.Confirmed
		}
		return request.PlanDigest == "" && !request.Confirmed
	}
	if kind != "transfer.describe" && kind != "transfer.preview" || request.JobID != "" || request.PlanDigest != "" || request.Confirmed || request.Target == nil || !request.Target.Valid() {
		return false
	}
	width := 0
	switch request.Mode {
	case "csv":
		if request.Source != nil || request.SourceDigest != "" || len(request.Headers) == 0 || len(request.Headers) > MaxTransferColumns || len(request.Rows) > MaxTransferInputRows {
			return false
		}
		width = len(request.Headers)
		total := 0
		for _, header := range request.Headers {
			if len(header) > 1024 || !utf8.ValidString(header) || strings.ContainsRune(header, 0) {
				return false
			}
		}
		for _, row := range request.Rows {
			if len(row) != width {
				return false
			}
			for _, value := range row {
				if !value.Valid(false) {
					return false
				}
				if value.Value != nil {
					total += len(*value.Value)
					if total > MaxTransferInputBytes || !utf8.ValidString(*value.Value) || strings.ContainsRune(*value.Value, 0) {
						return false
					}
					if value.Kind == "binary" {
						b, err := base64.StdEncoding.DecodeString(*value.Value)
						if err != nil || base64.StdEncoding.EncodeToString(b) != *value.Value {
							return false
						}
					}
				}
			}
		}
	case "table":
		if request.Source == nil || !request.Source.Valid() || request.Headers != nil || request.Rows != nil {
			return false
		}
		width = MaxTransferColumns
		if kind == "transfer.preview" && !transferDigest(request.SourceDigest) || kind == "transfer.describe" && request.SourceDigest != "" {
			return false
		}
	default:
		return false
	}
	if kind == "transfer.describe" {
		return request.Columns == nil
	}
	if len(request.Columns) == 0 || len(request.Columns) > MaxTransferColumns {
		return false
	}
	names, sources := map[string]bool{}, map[int]bool{}
	for _, column := range request.Columns {
		if !column.Valid() || column.SourceIndex >= width || names[column.Name] || sources[column.SourceIndex] {
			return false
		}
		names[column.Name], sources[column.SourceIndex] = true, true
	}
	return true
}

// ParseTransfer has a closed shape; file contents and connection settings may
// never be smuggled into a retained-plan apply request.
func ParseTransfer(raw json.RawMessage, kind string) (*TransferRequest, bool) {
	allowed := "jobId"
	requiredNames := []string{"jobId"}
	if kind == "transfer.apply" {
		allowed += "|planDigest|confirmed"
		requiredNames = append(requiredNames, "planDigest", "confirmed")
	}
	if kind == "transfer.describe" || kind == "transfer.preview" {
		allowed = "mode|source|target|headers|rows"
		if kind == "transfer.preview" {
			allowed += "|columns|sourceDigest"
		}
		requiredNames = []string{"mode", "target"}
	}
	fields, ok := changesObject(raw, allowed, requiredNames...)
	if !ok {
		return nil, false
	}
	var request TransferRequest
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil {
		return nil, false
	}
	for _, pair := range []struct {
		name     string
		endpoint **TransferEndpoint
	}{{"source", &request.Source}, {"target", &request.Target}} {
		if value, exists := fields[pair.name]; exists {
			parts, valid := changesObject(value, "connection|schema|table", "connection", "schema", "table")
			if !valid {
				return nil, false
			}
			connection, valid := parseConnection(parts["connection"])
			if !valid || *pair.endpoint == nil {
				return nil, false
			}
			(*pair.endpoint).Connection = connection
		}
	}
	if columns, exists := fields["columns"]; exists {
		var values []json.RawMessage
		if json.Unmarshal(columns, &values) != nil {
			return nil, false
		}
		for _, value := range values {
			parts, ok := changesObject(value, "sourceIndex|name|type|nullable|precision|scale", "sourceIndex", "name", "type", "nullable")
			if !ok {
				return nil, false
			}
			for _, name := range []string{"sourceIndex", "nullable", "precision", "scale"} {
				if raw, exists := parts[name]; exists && bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
					return nil, false
				}
			}
		}
	}
	if rows, exists := fields["rows"]; exists {
		var values [][]json.RawMessage
		if json.Unmarshal(rows, &values) != nil {
			return nil, false
		}
		for _, row := range values {
			for _, cell := range row {
				parts, ok := changesObject(cell, "kind|value", "kind")
				if !ok {
					return nil, false
				}
				var kind string
				if !stringField(parts, "kind", &kind) {
					return nil, false
				}
				if kind == "null" && len(parts) != 1 {
					return nil, false
				}
			}
		}
	}
	return &request, request.Valid(kind)
}

func (reply TransferReply) Valid() bool {
	if !ValidID(reply.JobID) || reply.RowsRead < 0 || reply.RowsWritten < 0 || reply.RowsWritten > reply.RowsRead || len(reply.Columns) > MaxTransferColumns || len(reply.Diagnostics) > MaxTransferDiagnostics || len(reply.SQL) > 1<<20 || len(reply.Notices) > 32 || len(reply.Message) > 4096 || len(reply.Code) > 128 {
		return false
	}
	switch reply.State {
	case "pending", "running", "described", "ready", "completed", "failed", "cancelled", "outcomeUnknown", "closed":
	default:
		return false
	}
	for _, column := range reply.Columns {
		if !column.Valid() {
			return false
		}
	}
	for _, text := range []string{reply.SQL, reply.Code, reply.Phase, reply.Message} {
		if !utf8.ValidString(text) || strings.ContainsRune(text, 0) {
			return false
		}
	}
	if reply.PlanDigest != "" && !transferDigest(reply.PlanDigest) || reply.SourceDigest != "" && !transferDigest(reply.SourceDigest) {
		return false
	}
	for _, notice := range reply.Notices {
		if len(notice) > 4096 || !utf8.ValidString(notice) || strings.ContainsRune(notice, 0) {
			return false
		}
	}
	for _, diagnostic := range reply.Diagnostics {
		if diagnostic.Row < 0 || diagnostic.Column < 0 || len(diagnostic.Message) > 4096 || !utf8.ValidString(diagnostic.Message) {
			return false
		}
	}
	if reply.State == "ready" && (!transferDigest(reply.PlanDigest) || reply.SQL == "" || len(reply.Diagnostics) != 0) {
		return false
	}
	return !reply.OutcomeUnknown || reply.State == "outcomeUnknown" || reply.State == "closed"
}
