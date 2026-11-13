// Package protocol defines the versioned NDJSON boundary between DBeer and its helper.
package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/jsoncheck"
	"dbeer/helper/internal/productidentity"
	"dbeer/helper/internal/tableedit"
)

const Version = 6
const MaxFrameBytes = 16 * 1024 * 1024
const MaxIDBytes = 128

type Connection struct {
	SQLite          *SQLiteSettings  `json:"sqlite,omitempty"`
	SessionPurpose  string           `json:"sessionPurpose,omitempty"`
	MongoDB         *MongoDBSettings `json:"mongodb,omitempty"`
	PasswordCommand *PasswordCommand `json:"passwordCommand,omitempty"`
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
	NativeCommand      *NativeCommand            `json:"nativeCommand,omitempty"`
	SchemaObservation  *SchemaObservationRequest `json:"schemaObservation,omitempty"`
	CatalogMetadata    *CatalogMetadataRequest   `json:"catalogMetadata,omitempty"`
	Transfer           *TransferRequest          `json:"transfer,omitempty"`
	DatabaseTools      *DatabaseToolsRequest     `json:"databaseTools,omitempty"`
	TableImport        *TableImportRequest       `json:"tableImport,omitempty"`
	Structure          *tableedit.Request        `json:"structure,omitempty"`
	PreparedExplainSQL string                    `json:"-"`
	Explain            *ExplainRequest           `json:"explain,omitempty"`
	DataComparison     *DataComparisonRequest    `json:"dataComparison,omitempty"`
	SchemaComparison   *SchemaComparisonRequest  `json:"schemaComparison,omitempty"`
	Comparison         *ComparisonRequest        `json:"comparison,omitempty"`
	SSHTrust           *SSHTrust                 `json:"sshTrust,omitempty"`
	Insert             *InsertFormatRequest      `json:"insert,omitempty"`
	Type               string                    `json:"type"`
	RequestID          string                    `json:"requestId"`
	ProtocolVersion    int                       `json:"protocolVersion,omitempty"`
	Connection         *Connection               `json:"connection,omitempty"`
	SessionID          string                    `json:"sessionId,omitempty"`
	QueryID            string                    `json:"queryId,omitempty"`
	SQL                string                    `json:"sql,omitempty"`
	Parameters         []QueryParameter          `json:"parameters,omitempty"`
	Catalog            *CatalogRequest           `json:"catalog,omitempty"`
	Stream             bool                      `json:"stream,omitempty"`
	ResultValues       string                    `json:"resultValues,omitempty"`
	Export             *ExportRequest            `json:"export,omitempty"`
	Sequence           int                       `json:"sequence,omitempty"`
	Changes            *ChangesRequest           `json:"changes,omitempty"`
	Operations         []OperationRequest        `json:"operations,omitempty"`
	Authorization      string                    `json:"authorization,omitempty"`
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
	RelationshipScope *SQLiteRelationshipScope `json:"relationshipScope,omitempty"`
	TypeChange        *TypeChange              `json:"typeChange,omitempty"`
	Kind              string                   `json:"kind"`
	Schema            string                   `json:"schema,omitempty"`
	Object            string                   `json:"object,omitempty"`
	ObjectKind        string                   `json:"objectKind,omitempty"`
	Identity          string                   `json:"identity,omitempty"`
	Search            string                   `json:"search,omitempty"`
	Cursor            string                   `json:"cursor,omitempty"`
	Page              int                      `json:"page,omitempty"`
	Sort              []CatalogSort            `json:"sort,omitempty"`
	Filters           []CatalogFilter          `json:"filters,omitempty"`
	FilterExpression  *CatalogFilterExpression `json:"filterExpression,omitempty"`
}

// TypeChange is a preview request, never an executable catalog operation.
// Pointers preserve an empty enum label independently of an omitted field.
type TypeChange struct {
	Operation string  `json:"operation"`
	NewName   *string `json:"newName,omitempty"`
	OldValue  *string `json:"oldValue,omitempty"`
	Value     *string `json:"value,omitempty"`
}

func (change TypeChange) Valid() bool {
	for _, value := range []*string{change.NewName, change.OldValue, change.Value} {
		if value != nil && (len(*value) > 63 || !utf8.ValidString(*value) || strings.ContainsRune(*value, 0)) {
			return false
		}
	}
	switch change.Operation {
	case "renameType":
		return change.NewName != nil && *change.NewName != "" && change.OldValue == nil && change.Value == nil
	case "addEnumValue":
		return change.NewName == nil && change.OldValue == nil && change.Value != nil
	case "renameEnumValue":
		return change.NewName == nil && change.OldValue != nil && change.Value != nil
	default:
		return false
	}
}

// ValidLocalTypeOID accepts only canonical nonzero PostgreSQL OID strings.
// This is a connection-local catalog handle, never a portable type identity.
func ValidLocalTypeOID(identity string) bool {
	oid, err := strconv.ParseUint(identity, 10, 32)
	return err == nil && oid != 0 && strconv.FormatUint(oid, 10) == identity
}

func (request CatalogRequest) IsPostgresTypeOperation() bool {
	switch request.Kind {
	case "typeDetails", "enumValues", "typeDependencies", "typeDDL":
		return true
	}
	return request.ObjectKind == "enum"
}

type CatalogSort struct {
	Column    string `json:"column"`
	Direction string `json:"direction"`
}
type CatalogFilter struct {
	Column      string                 `json:"column"`
	Operator    string                 `json:"operator"`
	Value       *string                `json:"value,omitempty"`
	SQLiteValue *SQLiteValue           `json:"sqliteValue,omitempty"`
	NativeValue *NativeCellFilterValue `json:"nativeValue,omitempty"`
}

func (request CatalogRequest) Valid() bool {
	if request.RelationshipScope != nil && (request.Kind != "browse" || !request.RelationshipScope.Valid() || request.Schema != request.RelationshipScope.Child.Schema || request.Object != request.RelationshipScope.Child.Name || request.ObjectKind != "table") {
		return false
	}

	if request.Kind == "typeDDL" {
		if request.TypeChange == nil || !request.TypeChange.Valid() {
			return false
		}
	} else if request.TypeChange != nil {
		return false
	}
	if request.Cursor != "" && (!ValidID(request.Cursor) || strings.ContainsRune(request.Cursor, 0) || request.Kind != "browse" || request.Page != 0) {
		return false
	}
	if request.Page < 0 || request.Page > 1000000 || len(request.Sort) > 32 || len(request.Filters) > 32 {
		return false
	}
	if _, valid := request.EffectiveFilterExpression(); !valid {
		return false
	}
	if request.Kind != "browse" && (len(request.Sort) != 0 || len(request.Filters) != 0 || request.FilterExpression != nil || request.Page != 0 && request.Kind != "completion") {
		return false
	}
	seenSort := make(map[string]bool)
	for _, sort := range request.Sort {
		if sort.Column == "" || len(sort.Column) > 1024 || strings.ContainsRune(sort.Column, 0) || (sort.Direction != "asc" && sort.Direction != "desc") {
			return false
		}
		if seenSort[sort.Column] {
			return false
		}
		seenSort[sort.Column] = true
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
	objectKindValid := objectKind == "table" || objectKind == "view" || objectKind == "function" || objectKind == "procedure" || objectKind == "trigger" || objectKind == "type" || objectKind == "enum"
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
	case "referencingTables":
		return request.Schema != "" && request.Object != "" && (objectKind == "" || objectKind == "table") && request.Identity == ""
	case "keys", "foreignKeys", "indexes", "constraints", "triggers":
		return request.Schema != "" && request.Object != "" && (objectKind == "" || objectKind == "table" || objectKind == "view") && request.Identity == ""
	case "definition":
		return request.Schema != "" && request.Object != "" && objectKindValid &&
			(objectKind != "enum" || validTypeHandle(request)) &&
			(objectKind != "type" || request.Identity == "" || validTypeHandle(request))
	case "name":
		return request.Schema != "" && request.Object != "" && objectKindValid &&
			(request.Identity == "" || objectKind == "function" || objectKind == "procedure" || objectKind == "trigger" || objectKind == "type" || objectKind == "enum") &&
			(objectKind != "enum" || validTypeHandle(request)) &&
			(objectKind != "type" || request.Identity == "" || validTypeHandle(request))
	case "typeDetails", "enumValues", "typeDependencies", "typeDDL":
		return (objectKind == "enum" || objectKind == "type") && validTypeHandle(request)
	case "select", "browse":
		return request.Schema != "" && request.Object != "" && (objectKind == "table" || objectKind == "view") && request.Identity == ""
	default:
		return false
	}
}

func validTypeHandle(request CatalogRequest) bool {
	return request.Schema != "" && len(request.Schema) <= 63 && request.Object != "" && len(request.Object) <= 63 && ValidLocalTypeOID(request.Identity)
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
	case "connect", "sqlite.create", "ssh.probe", "ssh.trust":
		allowed["connection"] = true
		connection, ok := parseConnection(fields["connection"])
		if !ok {
			return command, failure
		}
		command.Connection = &connection
		if command.Type != "connect" && command.Type != "sqlite.create" && connection.SSH == nil {
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
	case "transfer.describe", "transfer.preview", "transfer.apply", "transfer.status", "transfer.cancel", "transfer.close":
		allowed["transfer"] = true
		request, ok := ParseTransfer(fields["transfer"], command.Type)
		if !ok {
			return command, failure
		}
		command.Transfer = request
	case "dbtools.preview", "dbtools.start", "dbtools.status", "dbtools.cancel", "dbtools.close":
		allowed["databaseTools"] = true
		request, ok := parseDatabaseTools(fields["databaseTools"], command.Type)
		if !ok {
			return command, failure
		}
		command.DatabaseTools = &request
	case "data.describe", "data.start", "data.status", "data.page", "data.value", "data.diff", "data.plan", "data.cancel", "data.close":
		allowed["dataComparison"] = true
		request, ok := parseDataComparison(fields["dataComparison"], command.Type)
		if !ok {
			return command, failure
		}
		command.DataComparison = &request
	case "schema.import.start", "schema.import.status", "schema.import.cancel", "schema.import.close", "schema.bundle.start", "schema.bundle.status", "schema.bundle.export", "schema.bundle.cancel", "schema.bundle.close", "schema.start", "schema.status", "schema.page", "schema.value", "schema.diff", "schema.export", "schema.plan", "schema.cancel", "schema.close":
		allowed["schemaComparison"] = true
		request, ok := parseSchemaComparison(fields["schemaComparison"], command.Type)
		if !ok {
			return command, failure
		}
		command.SchemaComparison = &request
	case "compare.start", "compare.status", "compare.page", "compare.value", "compare.cancel", "compare.close":
		allowed["comparison"] = true
		request, ok := parseComparison(fields["comparison"], command.Type)
		if !ok {
			return command, failure
		}
		command.Comparison = &request
	case "formatInserts":
		allowed["insert"] = true
		request, ok := parseInsertFormat(fields["insert"])
		if !ok {
			return command, failure
		}
		command.Insert = &request
	case "monitor.snapshot", "monitor.schema", "import.describe", "import.preview", "import.apply", "structure.load", "structure.preview", "structure.apply", "structure.status", "structure.close", "execute", "command.execute", "explain.run", "catalog", "catalog.page", "catalog.batch", "catalog.close", "cancel", "disconnect", "stream.ack", "changes.preview", "changes.apply", "operation.assess":
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
		if command.Type == "monitor.schema" {
			allowed["schemaObservation"] = true
			request, ok := parseSchemaObservation(fields["schemaObservation"])
			if !ok {
				return command, failure
			}
			command.SchemaObservation = request
		}
		if strings.HasPrefix(command.Type, "import.") {
			allowed["tableImport"] = true
			request, ok := parseTableImport(fields["tableImport"], command.Type)
			if !ok {
				return command, failure
			}
			command.TableImport = request
		}
		if strings.HasPrefix(command.Type, "structure.") {
			allowed["structure"] = true
			request, ok := parseStructure(fields["structure"], command.Type)
			if !ok {
				return command, failure
			}
			command.Structure = &request
		}
		if command.Type == "changes.preview" || command.Type == "changes.apply" {
			allowed["changes"] = true
			request, ok := parseChanges(fields["changes"])
			if !ok {
				return command, failure
			}
			command.Changes = &request
		}
		if command.Type == "execute" || command.Type == "command.execute" || command.Type == "explain.run" || command.Type == "changes.apply" || command.Type == "structure.apply" || command.Type == "import.apply" {
			allowed["authorization"] = true
			if _, exists := fields["authorization"]; exists && (!stringField(fields, "authorization", &command.Authorization) || !ValidID(command.Authorization)) {
				return command, failure
			}
		}
		if command.Type == "explain.run" {
			allowed["explain"] = true
			request, ok := parseExplain(fields["explain"])
			if !ok {
				return command, failure
			}
			command.Explain = request
		}
		if command.Type == "operation.assess" {
			allowed["operations"] = true
			operations, ok := parseOperations(fields["operations"])
			if !ok {
				return command, failure
			}
			command.Operations = operations
		}
		if command.Type == "command.execute" {
			allowed["nativeCommand"], allowed["resultValues"] = true, true
			var native NativeCommand
			if json.Unmarshal(fields["nativeCommand"], &native) != nil || json.Unmarshal(fields["resultValues"], &command.ResultValues) != nil || command.ResultValues != NativeResultValuesFormat {
				return command, failure
			}
			command.NativeCommand = &native
		}
		if command.Type == "execute" {
			allowed["sql"] = true
			allowed["parameters"] = true
			if raw, exists := fields["parameters"]; exists {
				var ok bool
				command.Parameters, ok = parseQueryParameters(raw)
				if !ok {
					return command, failure
				}
			}
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
			allowed["resultValues"] = true
			if raw, exists := fields["resultValues"]; exists && (json.Unmarshal(raw, &command.ResultValues) != nil || command.ResultValues != NativeResultValuesFormat) {
				return command, failure
			}
			if raw, exists := fields["stream"]; exists && (bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &command.Stream) != nil) {
				return command, failure
			}
		}
		if command.Type == "catalog.page" || command.Type == "catalog.batch" || command.Type == "catalog.close" {
			allowed["catalogMetadata"] = true
			request, ok := parseCatalogMetadata(fields["catalogMetadata"], command.Type)
			if !ok {
				return command, failure
			}
			command.CatalogMetadata = request
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
	if command.ResultValues != "" && command.Type == "catalog" && (command.Catalog == nil || command.Catalog.Kind != "browse") {
		return command, failure
	}
	for name := range fields {
		if !allowed[name] {
			return command, failure
		}
	}
	if (command.NativeCommand != nil || command.Operations != nil || command.ResultValues != "" || command.SchemaComparison != nil || command.Catalog != nil && command.Catalog.HasNativeValue()) && !JSONUnicodeValid(frame) {
		failure.RequestID, failure.SessionID, failure.QueryID = "", "", ""
		return Command{}, failure
	}
	return command, nil
}

func parseCatalog(raw json.RawMessage) (CatalogRequest, bool) {
	var request CatalogRequest
	var fields map[string]json.RawMessage
	if !utf8.Valid(raw) || json.Unmarshal(raw, &fields) != nil || fields == nil || !stringField(fields, "kind", &request.Kind) {
		return request, false
	}
	// Type operations have a closed request shape. Even otherwise innocuous
	// empty/zero paging fields are rejected instead of silently ignored.
	_, typeKind := fields["objectKind"]
	var objectKind string
	if typeKind {
		_ = stringField(fields, "objectKind", &objectKind)
	}
	if request.IsPostgresTypeOperation() || (request.Kind == "definition" || request.Kind == "name") && (objectKind == "enum" || objectKind == "type") {
		for name := range fields {
			if name != "kind" && name != "schema" && name != "object" && name != "objectKind" && name != "identity" && !(name == "typeChange" && request.Kind == "typeDDL") {
				return request, false
			}
		}
	}
	if request.Kind == "name" || request.Kind == "foreignKeys" || request.Kind == "referencingTables" {
		for name := range fields {
			if name != "kind" && name != "schema" && name != "object" && name != "objectKind" && name != "identity" {
				return request, false
			}
			if (request.Kind == "foreignKeys" || request.Kind == "referencingTables") && name == "identity" {
				return request, false
			}
		}
	}
	allowed := map[string]*string{"schema": &request.Schema, "object": &request.Object, "objectKind": &request.ObjectKind, "identity": &request.Identity, "search": &request.Search, "cursor": &request.Cursor}
	for name := range fields {
		if name == "kind" {
			continue
		}
		if name == "typeChange" {
			change, ok := parseTypeChange(fields[name])
			if request.Kind != "typeDDL" || !ok {
				return request, false
			}
			request.TypeChange = &change
			continue
		}
		if name == "page" {
			if !required(fields, name) || json.Unmarshal(fields[name], &request.Page) != nil {
				return request, false
			}
			continue
		}
		if name == "relationshipScope" {
			var scope SQLiteRelationshipScope
			if !required(fields, name) || json.Unmarshal(fields[name], &scope) != nil {
				return request, false
			}
			request.RelationshipScope = &scope
			continue
		}
		if name == "filterExpression" {
			if !required(fields, name) {
				return request, false
			}
			var expression CatalogFilterExpression
			if json.Unmarshal(fields[name], &expression) != nil {
				return request, false
			}
			request.FilterExpression = &expression
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
	if request.HasNativeValue() && (!nativeJSONUnicodeValid(raw) || !uniqueObjectKeys(raw)) {
		return request, false
	}
	return request, request.Valid()
}

func parseTypeChange(raw json.RawMessage) (TypeChange, bool) {
	var change TypeChange
	var fields map[string]json.RawMessage
	if !utf8.Valid(raw) || json.Unmarshal(raw, &fields) != nil || fields == nil || !stringField(fields, "operation", &change.Operation) {
		return change, false
	}
	for name := range fields {
		if name == "operation" {
			continue
		}
		var value string
		if !stringField(fields, name, &value) {
			return change, false
		}
		switch name {
		case "newName":
			change.NewName = &value
		case "oldValue":
			change.OldValue = &value
		case "value":
			change.Value = &value
		default:
			return change, false
		}
	}
	return change, change.Valid()
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
	if !required(fields, "port") || json.Unmarshal(fields["port"], &connection.Port) != nil || connection.Port < 0 || connection.Port > 65535 {
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
	if _, exists := fields["sessionPurpose"]; exists {
		if !stringField(fields, "sessionPurpose", &connection.SessionPurpose) || (connection.SessionPurpose != "structure" && connection.SessionPurpose != "import" && connection.SessionPurpose != "monitor") || (connection.DatabaseEngine() != "postgresql" && connection.DatabaseEngine() != "mysql" && (connection.DatabaseEngine() != "sqlite" || connection.SessionPurpose == "monitor")) {
			return connection, false
		}
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
	if raw, exists := fields["sqlite"]; exists {
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&connection.SQLite) != nil || connection.SQLite == nil || !connection.SQLite.Valid() {
			return connection, false
		}
	}
	if raw, exists := fields["mongodb"]; exists {
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&connection.MongoDB) != nil || connection.MongoDB == nil || !connection.MongoDB.Valid() {
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
	if raw, exists := fields["passwordCommand"]; exists {
		if _, ok := changesObject(raw, "executable|arguments", "executable", "arguments"); !ok {
			return connection, false
		}
		if json.Unmarshal(raw, &connection.PasswordCommand) != nil || connection.PasswordCommand == nil || connection.PasswordCommand.Arguments == nil {
			return connection, false
		}
	}
	if !connection.Valid() {
		return connection, false
	}
	for name := range fields {
		switch name {
		case "sessionPurpose", "engine", "host", "port", "database", "user", "password", "sslMode", "sslRootCert", "policy", "contactPoints", "localDatacenter", "consistency", "ssh", "passwordCommand", "mongodb", "sqlite":
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
func uniqueObjectKeys(frame []byte) bool { return jsoncheck.UniqueObjectKeys(frame) }

type Column struct {
	Index        int    `json:"index"`
	Name         string `json:"name"`
	Engine       string `json:"engine,omitempty"`
	NativeType   string `json:"nativeType,omitempty"`
	TypeIdentity string `json:"typeIdentity,omitempty"`
	Encoding     string `json:"encoding,omitempty"`
	TypeOID      uint32 `json:"typeOid,omitempty"`
}

type ResultSet struct {
	NativeValues  [][]NativeValue `json:"nativeValues,omitempty"`
	SQLiteValues  [][]SQLiteValue `json:"sqliteValues,omitempty"`
	Source        *ResultSource   `json:"source,omitempty"`
	StorageTokens []string        `json:"storageTokens,omitempty"`
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
	if result.NativeValues != nil && !NativeMatrixValid(result.NativeValues, len(result.Rows), len(result.Columns)) {
		return nil, errors.New("invalid native result matrix")
	}
	var native *[][]NativeValue
	if result.NativeValues != nil {
		native = &result.NativeValues
	}
	return json.Marshal(struct {
		plain
		NativeValues *[][]NativeValue `json:"nativeValues,omitempty"`
	}{plain(result), native})
}

type Response struct {
	NativeValues          [][]NativeValue
	SchemaObservation     *SchemaObservation
	CatalogMetadata       *CatalogMetadataReply
	MetadataStale         bool
	MetadataTarget        *CatalogRelationTarget // Internal adapter proof; only the metadata store serializes it.
	Transfer              *TransferReply
	DatabaseTools         *DatabaseToolsReply
	Monitor               *SessionMonitorSnapshot
	SQLiteValues          [][]SQLiteValue
	TableImport           *TableImportReply
	Structure             *tableedit.Reply
	Explain               *ExplainResult
	ExplainSupport        *ExplainSupport
	OperationSupport      *OperationSupport
	Source                *ResultSource
	StorageTokens         []string
	DataComparison        *DataComparisonResponse
	SchemaComparison      *SchemaComparisonResponse
	Comparison            *ComparisonResponse
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
	if response.OperationSupport != nil {
		if !response.OperationSupport.Valid() ||
			response.Type == "connect.result" && (response.OperationSupport.Scope != "session" || response.OperationSupport.Engine != response.Engine) ||
			response.Type != "connect.result" && (!strings.HasPrefix(response.Type, "structure.") || response.OperationSupport.Scope != "structure") {
			return nil, errors.New("invalid operation support response")
		}
		fields["operationSupport"] = response.OperationSupport
	}
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
	if response.SQLiteValues != nil && (response.Type == "query.result" || response.Type == "query.chunk") {
		fields["sqliteValues"] = response.SQLiteValues
	}
	if response.NativeValues != nil {
		columns := len(response.Columns)
		if response.Type == "query.chunk" && response.Columns == nil && len(response.Rows) > 0 {
			columns = len(response.Rows[0])
		}
		if (response.Type != "query.result" && response.Type != "query.chunk") || !NativeMatrixValid(response.NativeValues, len(response.Rows), columns) {
			return nil, errors.New("invalid native response matrix")
		}
		fields["nativeValues"] = response.NativeValues
	}
	switch response.Type {
	case "catalog.page.result", "catalog.batch.result", "catalog.close.result":
		if response.CatalogMetadata == nil || !response.CatalogMetadata.Valid() {
			return nil, errors.New("invalid catalog metadata response")
		}
		fields["catalogMetadata"] = response.CatalogMetadata
		fields["connected"] = response.Connected
		fields["transactionStatus"] = response.TransactionStatus
	case "transfer.describe.result", "transfer.preview.result", "transfer.apply.result", "transfer.status.result", "transfer.cancel.result", "transfer.close.result":
		if response.Transfer == nil || !response.Transfer.Valid() {
			return nil, errors.New("invalid data transfer response")
		}
		fields["transfer"] = response.Transfer
	case "dbtools.preview.result", "dbtools.start.result", "dbtools.status.result", "dbtools.cancel.result", "dbtools.close.result":
		if response.DatabaseTools == nil || !response.DatabaseTools.Valid(response.Type) {
			return nil, errors.New("invalid database tools response")
		}
		fields["databaseTools"] = response.DatabaseTools
	case "monitor.schema.result":
		if response.SchemaObservation == nil || !response.SchemaObservation.Valid() || !response.Connected || response.TransactionStatus != "idle" {
			return nil, errors.New("invalid schema observation response")
		}
		fields["schemaObservation"] = response.SchemaObservation
		fields["connected"] = response.Connected
		fields["transactionStatus"] = response.TransactionStatus
	case "monitor.result":
		if response.Monitor == nil || !response.Monitor.Valid() || !response.Connected || response.TransactionStatus != "idle" {
			return nil, errors.New("invalid session monitor response")
		}
		fields["monitor"] = response.Monitor
		fields["connected"] = response.Connected
		fields["transactionStatus"] = response.TransactionStatus
	case "import.describe.result", "import.preview.result", "import.apply.result":
		fields["tableImport"] = response.TableImport
		fields["connected"] = response.Connected
		fields["transactionStatus"] = response.TransactionStatus
	case "structure.load.result", "structure.preview.result", "structure.apply.result", "structure.status.result", "structure.close.result":
		fields["structure"] = response.Structure
		fields["connected"] = response.Connected
		if response.TransactionStatus != "" && response.TransactionStatus != "unknown" {
			fields["transactionStatus"] = response.TransactionStatus
		}
	case "data.describe.result", "data.start.result", "data.status.result", "data.page.result", "data.value.result", "data.diff.result", "data.plan.result", "data.cancel.result", "data.close.result":
		fields["dataComparison"] = response.DataComparison
	case "schema.import.start.result", "schema.import.status.result", "schema.import.cancel.result", "schema.import.close.result", "schema.bundle.start.result", "schema.bundle.status.result", "schema.bundle.export.result", "schema.bundle.cancel.result", "schema.bundle.close.result", "schema.start.result", "schema.status.result", "schema.page.result", "schema.value.result", "schema.diff.result", "schema.export.result", "schema.plan.result", "schema.cancel.result", "schema.close.result":
		fields["schemaComparison"] = response.SchemaComparison
	case "compare.start.result", "compare.status.result", "compare.page.result", "compare.value.result", "compare.cancel.result", "compare.close.result":
		fields["comparison"] = response.Comparison
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
	case "explain.result":
		fields["explain"] = response.Explain
		fields["transactionStatus"] = response.TransactionStatus
		fields["durationMs"] = response.DurationMS
		fields["sqlCompleted"] = true
	case "operation.assessment":
		fields["assessment"] = response.Assessment
	case "connect.result":
		if response.ExplainSupport != nil {
			fields["explainSupport"] = response.ExplainSupport
		}
		fields["transactionStatus"] = response.TransactionStatus
		fields["engine"] = response.Engine
		capabilities := response.Capabilities
		if capabilities == nil {
			capabilities = []string{}
		}
		fields["capabilities"] = capabilities
	case "sqlite.create.result", "query.started", "disconnect.ack", "shutdown.ack":
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
		if response.Source != nil {
			fields["source"] = response.Source
		}
		if response.StorageTokens != nil {
			fields["storageTokens"] = response.StorageTokens
		}
		if response.SQL != "" {
			fields["sql"] = response.SQL
		}
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
		if response.TableImport != nil {
			fields["tableImport"] = response.TableImport
		}
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

// WithReadSQL observes the native source metadata limit and the complete encoded
// wire frame budget. Large filters must not make a successful browse fail or
// displace the captured rows merely to carry optional source metadata.
func (response Response) WithReadSQL(sql string) Response {
	if response.Type != "query.result" || sql == "" {
		return response
	}
	response.SQL = sql
	if len(sql) <= MaxFrameBytes/2 {
		encoded, err := json.Marshal(response)
		if err == nil && len(encoded) <= MaxFrameBytes {
			return response
		}
	}
	response.SQL = ""
	if response.DisplayNotice != "" {
		response.DisplayNotice += " "
	}
	response.DisplayNotice += "The generated read statement is too large to capture with this result. Reduce filter values to include its source SQL."
	return response
}

func ErrorResponse(command Command, category, message string) Response {
	return Response{Type: "error", RequestID: command.RequestID, SessionID: command.SessionID,
		QueryID: command.QueryID, Category: category, Message: message}
}
