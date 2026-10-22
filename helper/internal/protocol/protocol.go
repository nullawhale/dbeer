// Package protocol defines the versioned NDJSON boundary between DBeer and its helper.
package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/productidentity"
)

const Version = 5
const MaxFrameBytes = 16 * 1024 * 1024
const MaxIDBytes = 128

type Connection struct {
	SSH             *SSHSettings     `json:"ssh,omitempty"`
	Engine          string           `json:"engine,omitempty"`
	Host            string           `json:"host"`
	Port            int              `json:"port"`
	Database        string           `json:"database"`
	User            string           `json:"user"`
	Password        string           `json:"password"`
	SSLMode         string           `json:"sslMode"`
	ContactPoints   []string         `json:"contactPoints,omitempty"`
	LocalDatacenter string           `json:"localDatacenter,omitempty"`
	Consistency     string           `json:"consistency,omitempty"`
	SSLRootCert     string           `json:"sslRootCert,omitempty"`
	Policy          *ExecutionPolicy `json:"policy,omitempty"`
}

// Empty engines from an older saved profile retain PostgreSQL semantics. The
// protocol handshake itself is still strictly versioned.
func (connection Connection) DatabaseEngine() string {
	if connection.Engine == "" {
		return "postgresql"
	}
	return connection.Engine
}

type Command struct {
	SSHTrust        *SSHTrust            `json:"sshTrust,omitempty"`
	Insert          *InsertFormatRequest `json:"insert,omitempty"`
	Type            string               `json:"type"`
	RequestID       string               `json:"requestId"`
	ProtocolVersion int                  `json:"protocolVersion,omitempty"`
	Connection      *Connection          `json:"connection,omitempty"`
	SessionID       string               `json:"sessionId,omitempty"`
	QueryID         string               `json:"queryId,omitempty"`
	SQL             string               `json:"sql,omitempty"`
	Catalog         *CatalogRequest      `json:"catalog,omitempty"`
	Stream          bool                 `json:"stream,omitempty"`
	Export          *ExportRequest       `json:"export,omitempty"`
	Sequence        int                  `json:"sequence,omitempty"`
	Changes         *ChangesRequest      `json:"changes,omitempty"`
	Operations      []OperationRequest   `json:"operations,omitempty"`
	Authorization   string               `json:"authorization,omitempty"`
}

type ExportRequest struct {
	Path        string             `json:"path"`
	Format      string             `json:"format"`
	NullMarker  *string            `json:"nullMarker,omitempty"`
	Destination *ExportDestination `json:"destination,omitempty"`
}

type ExportDestination struct {
	Identity            *string `json:"identity,omitempty"`
	ParentIdentity      *string `json:"parentIdentity,omitempty"`
	Exists              bool    `json:"exists"`
	Size                int64   `json:"size"`
	SHA256              string  `json:"sha256"`
	ModifiedNanoseconds *string `json:"modifiedNanoseconds,omitempty"`
}

func (destination ExportDestination) Valid() bool {
	for _, identity := range []*string{destination.Identity, destination.ParentIdentity} {
		if identity != nil {
			if len(*identity) == 0 || len(*identity) > 128 {
				return false
			}
			for _, c := range *identity {
				if c != ':' && (c < '0' || c > '9') {
					return false
				}
			}
		}
	}

	if !destination.Exists {
		return destination.Size == 0 && destination.SHA256 == "" && destination.ModifiedNanoseconds == nil && destination.Identity == nil
	}
	if destination.Size < 0 || len(destination.SHA256) != 64 {
		return false
	}
	for _, c := range destination.SHA256 {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	if destination.ModifiedNanoseconds != nil {
		if len(*destination.ModifiedNanoseconds) > 32 || len(*destination.ModifiedNanoseconds) == 0 {
			return false
		}
		for _, c := range *destination.ModifiedNanoseconds {
			if c < '0' || c > '9' {
				return false
			}
		}
	}
	return true
}

func (request ExportRequest) Valid() bool {
	if request.Format == "csv" && request.NullMarker != nil && *request.NullMarker == "" {
		return false
	}
	if request.Destination != nil && !request.Destination.Valid() {
		return false
	}
	if !filepath.IsAbs(request.Path) || len(request.Path) > 4096 || strings.ContainsRune(request.Path, 0) || (request.Format != "csv" && request.Format != "json") {
		return false
	}
	return request.NullMarker == nil || (len(*request.NullMarker) <= 1024 && !strings.ContainsRune(*request.NullMarker, 0))
}

type CatalogRequest struct {
	Kind       string          `json:"kind"`
	Schema     string          `json:"schema,omitempty"`
	Object     string          `json:"object,omitempty"`
	ObjectKind string          `json:"objectKind,omitempty"`
	Identity   string          `json:"identity,omitempty"`
	Search     string          `json:"search,omitempty"`
	Cursor     string          `json:"cursor,omitempty"`
	Page       int             `json:"page,omitempty"`
	Sort       []CatalogSort   `json:"sort,omitempty"`
	Filters    []CatalogFilter `json:"filters,omitempty"`
}

type CatalogSort struct {
	Column    string `json:"column"`
	Direction string `json:"direction"`
}
type CatalogFilter struct {
	Column   string  `json:"column"`
	Operator string  `json:"operator"`
	Value    *string `json:"value,omitempty"`
}

func (request CatalogRequest) Valid() bool {
	if request.Cursor != "" && (!ValidID(request.Cursor) || strings.ContainsRune(request.Cursor, 0) || request.Kind != "browse" || request.Page != 0) {
		return false
	}
	if request.Page < 0 || request.Page > 1000000 || len(request.Sort) > 32 || len(request.Filters) > 32 {
		return false
	}
	if request.Kind != "browse" && (len(request.Sort) != 0 || len(request.Filters) != 0 || request.Page != 0 && request.Kind != "completion") {
		return false
	}
	for _, sort := range request.Sort {
		if sort.Column == "" || len(sort.Column) > 1024 || strings.ContainsRune(sort.Column, 0) || (sort.Direction != "asc" && sort.Direction != "desc") {
			return false
		}
	}
	for _, filter := range request.Filters {
		if filter.Column == "" || len(filter.Column) > 1024 || strings.ContainsRune(filter.Column, 0) {
			return false
		}
		switch filter.Operator {
		case "eq", "ne", "lt", "lte", "gt", "gte", "contains":
			if filter.Value == nil || len(*filter.Value) > 1024*1024 || strings.ContainsRune(*filter.Value, 0) {
				return false
			}
		case "isNull", "isNotNull":
			if filter.Value != nil {
				return false
			}
		default:
			return false
		}
	}
	for _, name := range []string{request.Schema, request.Object, request.ObjectKind, request.Search} {
		if len(name) > 1024 || !utf8.ValidString(name) || strings.ContainsRune(name, 0) {
			return false
		}
	}
	if len(request.Identity) > 128 || !utf8.ValidString(request.Identity) || strings.ContainsRune(request.Identity, 0) {
		return false
	}
	objectKind := request.ObjectKind
	if request.Kind != "search" && request.Search != "" {
		return false
	}
	objectKindValid := objectKind == "table" || objectKind == "view" || objectKind == "function" || objectKind == "procedure" || objectKind == "trigger" || objectKind == "type"
	switch request.Kind {
	case "completion":
		return request.Object == "" && objectKind == "" && request.Identity == ""
	case "search":
		return request.Search != "" && request.Object == "" && objectKind == "" && request.Identity == ""
	case "schemas", "clusterNodes":
		return request.Schema == "" && request.Object == "" && objectKind == "" && request.Identity == ""
	case "objects":
		return request.Schema != "" && request.Object == "" && objectKindValid && request.Identity == ""
	case "columns":
		return request.Schema != "" && request.Object != "" && (objectKind == "" || objectKind == "table" || objectKind == "view" || objectKind == "type") && request.Identity == ""
	case "keys", "indexes", "constraints", "triggers":
		return request.Schema != "" && request.Object != "" && (objectKind == "" || objectKind == "table" || objectKind == "view") && request.Identity == ""
	case "definition":
		return request.Schema != "" && request.Object != "" && objectKindValid
	case "name":
		return request.Schema != "" && request.Object != "" && objectKindValid &&
			(request.Identity == "" || objectKind == "function" || objectKind == "procedure" || objectKind == "trigger")
	case "select", "browse":
		return request.Schema != "" && request.Object != "" && (objectKind == "table" || objectKind == "view") && request.Identity == ""
	default:
		return false
	}
}

// ProtocolError contains only validated identifiers and a fixed diagnostic.
// It never retains input, credentials, or errors from JSON decoding.
type ProtocolError struct {
	RequestID string
	SessionID string
	QueryID   string
	Message   string
}

func (e *ProtocolError) Error() string { return e.Message }

func ValidID(value string) bool {
	return value != "" && len(value) <= MaxIDBytes && utf8.ValidString(value)
}

func ParseCommand(frame []byte) (Command, error) {
	var command Command
	failure := &ProtocolError{Message: "Invalid protocol message."}
	if len(frame) > MaxFrameBytes {
		failure.Message = "Protocol message exceeds the size limit."
		return command, failure
	}
	if !utf8.Valid(frame) {
		failure.Message = "Protocol message is not valid UTF-8."
		return command, failure
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(frame, &fields); err != nil || fields == nil {
		return command, failure
	}
	for name, target := range map[string]*string{
		"requestId": &failure.RequestID, "sessionId": &failure.SessionID, "queryId": &failure.QueryID,
	} {
		var value string
		if json.Unmarshal(fields[name], &value) == nil && ValidID(value) {
			*target = value
		}
	}
	if !uniqueObjectKeys(frame) {
		return command, failure
	}
	if !stringField(fields, "type", &command.Type) || !stringField(fields, "requestId", &command.RequestID) || !ValidID(command.RequestID) {
		return command, failure
	}
	allowed := map[string]bool{"type": true, "requestId": true}
	switch command.Type {
	case "hello":
		allowed["protocolVersion"] = true
		if !required(fields, "protocolVersion") || json.Unmarshal(fields["protocolVersion"], &command.ProtocolVersion) != nil {
			return command, failure
		}
	case "connect", "ssh.probe", "ssh.trust":
		allowed["connection"] = true
		connection, ok := parseConnection(fields["connection"])
		if !ok {
			return command, failure
		}
		command.Connection = &connection
		if command.Type != "connect" && connection.SSH == nil {
			return command, failure
		}
		if command.Type == "ssh.trust" {
			allowed["sshTrust"] = true
			var trust SSHTrust
			decoder := json.NewDecoder(bytes.NewReader(fields["sshTrust"]))
			decoder.DisallowUnknownFields()
			if !required(fields, "sshTrust") || decoder.Decode(&trust) != nil || !ValidID(trust.Token) {
				return command, failure
			}
			command.SSHTrust = &trust
		}
	case "formatInserts":
		allowed["insert"] = true
		request, ok := parseInsertFormat(fields["insert"])
		if !ok {
			return command, failure
		}
		command.Insert = &request
	case "execute", "catalog", "cancel", "disconnect", "stream.ack", "changes.preview", "changes.apply", "operation.assess":
		allowed["sessionId"] = true
		if !stringField(fields, "sessionId", &command.SessionID) || !ValidID(command.SessionID) {
			return command, failure
		}
		if command.Type != "disconnect" {
			allowed["queryId"] = true
			if !stringField(fields, "queryId", &command.QueryID) || !ValidID(command.QueryID) {
				return command, failure
			}
		}
		if command.Type == "stream.ack" {
			allowed["sequence"] = true
			if !required(fields, "sequence") || json.Unmarshal(fields["sequence"], &command.Sequence) != nil || command.Sequence < 1 {
				return command, failure
			}
		}
		if command.Type == "changes.preview" || command.Type == "changes.apply" {
			allowed["changes"] = true
			request, ok := parseChanges(fields["changes"])
			if !ok {
				return command, failure
			}
			command.Changes = &request
		}
		if command.Type == "execute" || command.Type == "changes.apply" {
			allowed["authorization"] = true
			if _, exists := fields["authorization"]; exists && (!stringField(fields, "authorization", &command.Authorization) || !ValidID(command.Authorization)) {
				return command, failure
			}
		}
		if command.Type == "operation.assess" {
			allowed["operations"] = true
			operations, ok := parseOperations(fields["operations"])
			if !ok {
				return command, failure
			}
			command.Operations = operations
		}
		if command.Type == "execute" {
			allowed["sql"] = true
			if !stringField(fields, "sql", &command.SQL) {
				return command, failure
			}
			allowed["export"] = true
			if raw, exists := fields["export"]; exists {
				var request ExportRequest
				decoder := json.NewDecoder(bytes.NewReader(raw))
				decoder.DisallowUnknownFields()
				if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || decoder.Decode(&request) != nil || !request.Valid() {
					return command, failure
				}
				command.Export = &request
			}
		}
		if command.Type == "execute" || command.Type == "catalog" {
			allowed["stream"] = true
			if raw, exists := fields["stream"]; exists && (bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &command.Stream) != nil) {
				return command, failure
			}
		}
		if command.Type == "catalog" {
			allowed["catalog"] = true
			catalog, ok := parseCatalog(fields["catalog"])
			if !ok {
				return command, failure
			}
			command.Catalog = &catalog
		}
	case "shutdown":
	default:
		failure.Message = "Unknown protocol command."
		return command, failure
	}
	for name := range fields {
		if !allowed[name] {
			return command, failure
		}
	}
	return command, nil
}

func parseCatalog(raw json.RawMessage) (CatalogRequest, bool) {
	var request CatalogRequest
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields == nil || !stringField(fields, "kind", &request.Kind) {
		return request, false
	}
	if request.Kind == "name" {
		for name := range fields {
			if name != "kind" && name != "schema" && name != "object" && name != "objectKind" && name != "identity" {
				return request, false
			}
		}
	}
	allowed := map[string]*string{"schema": &request.Schema, "object": &request.Object, "objectKind": &request.ObjectKind, "identity": &request.Identity, "search": &request.Search, "cursor": &request.Cursor}
	for name := range fields {
		if name == "kind" {
			continue
		}
		if name == "page" {
			if !required(fields, name) || json.Unmarshal(fields[name], &request.Page) != nil {
				return request, false
			}
			continue
		}
		if name == "sort" || name == "filters" {
			decoder := json.NewDecoder(bytes.NewReader(fields[name]))
			decoder.DisallowUnknownFields()
			if !required(fields, name) {
				return request, false
			}
			if name == "sort" {
				if decoder.Decode(&request.Sort) != nil {
					return request, false
				}
			} else {
				if decoder.Decode(&request.Filters) != nil {
					return request, false
				}
			}
			continue
		}
		target, ok := allowed[name]
		if !ok || !stringField(fields, name, target) {
			return request, false
		}
	}
	if request.Kind == "name" && (request.ObjectKind == "table" || request.ObjectKind == "view") {
		if _, exists := fields["identity"]; exists {
			return request, false
		}
	}
	return request, request.Valid()
}

func parseConnection(raw json.RawMessage) (Connection, bool) {
	var connection Connection
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields == nil {
		return connection, false
	}
	for name, target := range map[string]*string{
		"host": &connection.Host, "database": &connection.Database, "user": &connection.User,
		"password": &connection.Password, "sslMode": &connection.SSLMode,
	} {
		if !stringField(fields, name, target) {
			return connection, false
		}
	}
	if !required(fields, "port") || json.Unmarshal(fields["port"], &connection.Port) != nil || connection.Port < 1 || connection.Port > 65535 {
		return connection, false
	}
	switch connection.SSLMode {
	case "disable", "allow", "prefer", "require", "verify-ca", "verify-full":
	default:
		return connection, false
	}
	if _, exists := fields["sslRootCert"]; exists && !stringField(fields, "sslRootCert", &connection.SSLRootCert) {
		return connection, false
	}
	if _, exists := fields["engine"]; exists && !stringField(fields, "engine", &connection.Engine) {
		return connection, false
	}
	if raw, exists := fields["policy"]; exists {
		var policy ExecutionPolicy
		if _, ok := changesObject(raw, "environment|readOnly", "environment", "readOnly"); !ok {
			return connection, false
		}
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.DisallowUnknownFields()
		if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || decoder.Decode(&policy) != nil || !policy.Valid() {
			return connection, false
		}
		connection.Policy = &policy
	}
	for name, target := range map[string]*string{"localDatacenter": &connection.LocalDatacenter, "consistency": &connection.Consistency} {
		if _, exists := fields[name]; exists && !stringField(fields, name, target) {
			return connection, false
		}
	}
	if raw, exists := fields["contactPoints"]; exists {
		if !required(fields, "contactPoints") || json.Unmarshal(raw, &connection.ContactPoints) != nil || len(connection.ContactPoints) == 0 {
			return connection, false
		}
	}
	if raw, exists := fields["ssh"]; exists {
		var ok bool
		connection.SSH, ok = parseSSH(raw)
		if !ok {
			return connection, false
		}
	}
	if !connection.Valid() {
		return connection, false
	}
	for name := range fields {
		switch name {
		case "engine", "host", "port", "database", "user", "password", "sslMode", "sslRootCert", "policy", "contactPoints", "localDatacenter", "consistency", "ssh":
		default:
			return connection, false
		}
	}
	return connection, true
}

func required(fields map[string]json.RawMessage, name string) bool {
	raw, exists := fields[name]
	return exists && !bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

func stringField(fields map[string]json.RawMessage, name string, target *string) bool {
	return required(fields, name) && json.Unmarshal(fields[name], target) == nil
}

// Reject repeated object keys, including keys inside connection, rather than
// allowing the JSON decoder to silently select the last value.
func uniqueObjectKeys(frame []byte) bool {
	decoder := json.NewDecoder(bytes.NewReader(frame))
	decoder.UseNumber()
	var value func() bool
	value = func() bool {
		token, err := decoder.Token()
		if err != nil {
			return false
		}
		delimiter, nested := token.(json.Delim)
		if !nested {
			return true
		}
		if delimiter == '{' {
			keys := make(map[string]bool)
			for decoder.More() {
				keyToken, err := decoder.Token()
				key, ok := keyToken.(string)
				if err != nil || !ok || keys[key] {
					return false
				}
				keys[key] = true
				if !value() {
					return false
				}
			}
		} else if delimiter == '[' {
			for decoder.More() {
				if !value() {
					return false
				}
			}
		} else {
			return false
		}
		_, err = decoder.Token()
		return err == nil
	}
	if !value() {
		return false
	}
	_, err := decoder.Token()
	return errors.Is(err, io.EOF)
}

type Column struct {
	Index      int    `json:"index"`
	Name       string `json:"name"`
	Engine     string `json:"engine,omitempty"`
	NativeType string `json:"nativeType,omitempty"`
	Encoding   string `json:"encoding,omitempty"`
	TypeOID    uint32 `json:"typeOid,omitempty"`
}

type ResultSet struct {
	// False means rowCount is a returned-row count, not an affected-row assertion.
	AffectedRowCountKnown *bool       `json:"affectedRowCountKnown,omitempty"`
	NextCursor            string      `json:"nextCursor,omitempty"`
	Columns               []Column    `json:"columns"`
	Rows                  [][]*string `json:"rows"`
	CommandTag            string      `json:"commandTag"`
	RowCount              int64       `json:"rowCount"`
	DisplayedRowCount     int         `json:"displayedRowCount"`
	Truncated             bool        `json:"truncated"`
	DisplayNotice         string      `json:"displayNotice,omitempty"`
}

func (result ResultSet) MarshalJSON() ([]byte, error) {
	type plain ResultSet
	if result.Columns == nil {
		result.Columns = []Column{}
	}
	if result.Rows == nil {
		result.Rows = [][]*string{}
	}
	return json.Marshal(plain(result))
}

type Response struct {
	SQL                   string
	SSH                   *SSHProbe
	AppliedChangeCount    *int
	CurrentKeyspace       *string
	AffectedRowCountKnown *bool
	NextCursor            string
	Type                  string
	RequestID             string
	ProtocolVersion       int
	BuildIdentity         *productidentity.Identity
	SessionID             string
	QueryID               string
	DurationMS            float64
	Columns               []Column
	Rows                  [][]*string
	CommandTag            string
	RowCount              int64
	DisplayedRowCount     int
	Truncated             bool
	TransactionStatus     string
	DisplayNotice         string
	Status                string
	Category              string
	Message               string
	SQLState              string
	ErrorPosition         int
	Connected             bool
	OutcomeUnknown        bool
	SQLCompleted          bool
	SQLNotExecuted        bool
	ExportPublication     string
	Engine                string
	Capabilities          []string
	ResultSets            []ResultSet
	Streamed              bool
	Sequence              int
	ResultIndex           int
	ExportPath            string
	ExportFormat          string
	ExportRowCount        int64
	Assessment            *OperationAssessment
}

func (response Response) MarshalJSON() ([]byte, error) {
	fields := map[string]any{"type": response.Type, "requestId": response.RequestID}
	if response.AppliedChangeCount != nil && (response.Type == "query.result" || response.Type == "error") {
		fields["appliedChangeCount"] = *response.AppliedChangeCount
	}
	if response.SessionID != "" {
		fields["sessionId"] = response.SessionID
	}
	if response.QueryID != "" {
		fields["queryId"] = response.QueryID
	}
	if response.CurrentKeyspace != nil && (response.Type == "connect.result" || response.Type == "query.result" || response.Type == "error") {
		fields["currentKeyspace"] = *response.CurrentKeyspace
	}
	switch response.Type {
	case "insertSQL":
		fields["sql"] = response.SQL
	case "ssh.probe.result", "ssh.trust.result":
		fields["ssh"] = response.SSH
	case "hello.ack":
		fields["protocolVersion"] = response.ProtocolVersion
		if response.BuildIdentity != nil {
			fields["buildIdentity"] = response.BuildIdentity
		}
		if response.Capabilities != nil {
			fields["capabilities"] = response.Capabilities
		}
	case "operation.assessment":
		fields["assessment"] = response.Assessment
	case "connect.result":
		fields["transactionStatus"] = response.TransactionStatus
		fields["engine"] = response.Engine
		capabilities := response.Capabilities
		if capabilities == nil {
			capabilities = []string{}
		}
		fields["capabilities"] = capabilities
	case "query.started", "disconnect.ack", "shutdown.ack":
	case "query.progress":
		fields["resultIndex"], fields["rowCount"], fields["sequence"] = response.ResultIndex, response.RowCount, response.Sequence
	case "query.chunk":
		fields["sequence"], fields["resultIndex"] = response.Sequence, response.ResultIndex
		if response.Columns != nil {
			fields["columns"] = response.Columns
		}
		rows := response.Rows
		if rows == nil {
			rows = [][]*string{}
		}
		fields["rows"] = rows
	case "query.result":
		columns, rows := response.Columns, response.Rows
		if columns == nil {
			columns = []Column{}
		}
		if rows == nil {
			rows = [][]*string{}
		}
		fields["durationMs"], fields["columns"], fields["rows"] = response.DurationMS, columns, rows
		fields["commandTag"], fields["rowCount"] = response.CommandTag, response.RowCount
		fields["displayedRowCount"], fields["truncated"] = response.DisplayedRowCount, response.Truncated
		fields["transactionStatus"] = response.TransactionStatus
		if response.AffectedRowCountKnown != nil {
			fields["affectedRowCountKnown"] = *response.AffectedRowCountKnown
		}
		if response.NextCursor != "" {
			fields["nextCursor"] = response.NextCursor
		}
		if response.DisplayNotice != "" {
			fields["displayNotice"] = response.DisplayNotice
		}
		if response.ResultSets != nil {
			fields["resultSets"] = response.ResultSets
		}
		if response.Streamed {
			fields["streamed"] = true
		}
		if response.ExportPath != "" {
			fields["exportPath"], fields["exportFormat"], fields["exportRowCount"] = response.ExportPath, response.ExportFormat, response.ExportRowCount
		}
	case "cancel.ack":
		fields["status"] = response.Status
	case "error":
		fields["category"], fields["message"] = response.Category, response.Message
		fields["connected"], fields["outcomeUnknown"] = response.Connected, response.OutcomeUnknown
		if response.SQLNotExecuted {
			fields["sqlNotExecuted"] = true
		}
		if response.SQLCompleted {
			fields["sqlCompleted"] = true
		}
		if response.ExportPublication != "" {
			fields["exportPublication"] = response.ExportPublication
		}
		if response.SQLState != "" {
			fields["sqlState"] = response.SQLState
		}
		if response.ErrorPosition > 0 {
			fields["errorPosition"] = response.ErrorPosition
		}
		if response.TransactionStatus != "" {
			fields["transactionStatus"] = response.TransactionStatus
		}
		if response.ResultSets != nil {
			fields["resultSets"] = response.ResultSets
		}
		if response.Streamed {
			fields["streamed"] = true
		}
	default:
		return nil, errors.New("unknown protocol response type")
	}
	return json.Marshal(fields)
}

func ErrorResponse(command Command, category, message string) Response {
	return Response{Type: "error", RequestID: command.RequestID, SessionID: command.SessionID,
		QueryID: command.QueryID, Category: category, Message: message}
}
