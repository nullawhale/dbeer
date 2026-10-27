package mysql

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/resultsource"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

const mysqlSourceUnavailable = "The source table metadata is unavailable. Open the table from Connections to edit it."

type mysqlSourceColumn struct {
	name, nativeType, dataType string
	primaryKey                 int
	generated, invisible       bool
}

func mysqlReadOnlySource(reason string) *protocol.ResultSource {
	return &protocol.ResultSource{Columns: []protocol.ResultSourceColumn{}, ReadOnlyReason: reason}
}

// attachResultSource runs within executeWith's exclusive worker, after the sole
// user execution has completed. A display label is never used as an origin.
func (session *Session) attachResultSource(ctx context.Context, sql string, collector *collector) error {
	selection, reason := resultsource.Parse(sql, "mysql")
	if reason != "" || len(collector.resultSets) != 0 {
		if reason == "" {
			reason = resultsource.Unsupported
		}
		collector.response.Source = mysqlReadOnlySource(reason)
		return nil
	}
	collector.sourceReadCompleted = true
	if ctx.Err() != nil || len(collector.originFields) == 0 || len(collector.response.Columns) != len(collector.originFields) {
		collector.response.Source = mysqlReadOnlySource(mysqlSourceUnavailable)
		return nil
	}
	if session.work.client.IsInTransaction() {
		collector.response.Source = mysqlReadOnlySource("Source-row actions require a result loaded outside an explicit transaction.")
		return nil
	}
	schema, table, ok := mysqlResultOrigin(selection, collector.originFields)
	if !ok {
		collector.response.Source = mysqlReadOnlySource("The server did not identify one unambiguous base table for every result column.")
		return nil
	}
	metadata, reason, err := session.resultSourceMetadata(schema, table)
	if err != nil {
		var server *wire.MyError
		if !errors.As(err, &server) {
			return err
		}
		// A denied or concurrently removed table must not turn a successful
		// SELECT into a failed query. ERR lacks status flags; recover with PING.
		collector.needsStatusProbe = true
		reason = mysqlSourceUnavailable
	}
	if reason != "" {
		collector.response.Source = mysqlReadOnlySource(reason)
		return nil
	}
	collector.response.Source = mysqlSourceForFields(schema, table, collector.originFields, metadata)
	if encoded, marshalErr := json.Marshal(collector.response); marshalErr != nil || len(encoded)+1024 > collector.maxBytes {
		collector.response.Source = mysqlReadOnlySource("Source metadata exceeds the display limit. Open the table from Connections.")
	}
	return nil
}

func mysqlResultOrigin(selection resultsource.Selection, fields []*wire.Field) (string, string, bool) {
	if len(fields) == 0 || len(fields) > maxResultColumns {
		return "", "", false
	}
	schema, table := string(fields[0].Schema), string(fields[0].OrgTable)
	if schema == "" || table == "" || len(schema) > 256 || len(table) > 256 || !utf8.ValidString(schema) || !utf8.ValidString(table) || table != selection.Table || selection.Schema != "" && selection.Schema != schema {
		return "", "", false
	}
	for _, field := range fields {
		if string(field.Schema) != schema || string(field.OrgTable) != table || len(field.OrgName) == 0 {
			return "", "", false
		}
	}
	return schema, table, true
}

func (session *Session) resultSourceMetadata(schema, table string) ([]mysqlSourceColumn, string, error) {
	// Origin identifiers themselves use the connection's result encoding. A
	// lossy encoding could make an unqualified Unicode schema name collide with
	// another actual schema, even when its integer key value remains exact.
	encoding, err := session.work.client.Execute("SELECT @@SESSION.character_set_results")
	if err != nil {
		return nil, "", err
	}
	charset, charsetErr := encoding.GetString(0, 0)
	losslessEncoding := charsetErr == nil && charset == "utf8mb4"
	encoding.Close()
	if !losslessEncoding {
		return nil, "Source-row actions require lossless UTF-8 result metadata. Restore the connection's UTF-8 result encoding and run the query again.", nil
	}
	object, err := session.work.client.Execute(`SELECT TABLE_TYPE,ENGINE FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=? AND BINARY TABLE_NAME=? LIMIT 1`, schema, table)
	if err != nil {
		return nil, "", err
	}
	if object.RowNumber() != 1 {
		object.Close()
		return nil, mysqlSourceUnavailable, nil
	}
	kind, _ := object.GetString(0, 0)
	engine, _ := object.GetString(0, 1)
	baseInnoDB := kind == "BASE TABLE" && engine == "InnoDB"
	object.Close()
	if !baseInnoDB {
		return nil, "SQL result editing and source rows require an InnoDB base table with a primary key.", nil
	}
	// A temporary table can shadow a permanent table with identical wire
	// origins. SHOW CREATE resolves the same actual object as the user's SELECT;
	// information_schema alone would incorrectly authorize the permanent table.
	definition, err := session.work.client.Execute("SHOW CREATE TABLE " + QuoteIdentifier(schema) + "." + QuoteIdentifier(table))
	if err != nil {
		return nil, "", err
	}
	ddl, ddlErr := definition.GetString(0, 1)
	permanent := ddlErr == nil && strings.HasPrefix(ddl, "CREATE TABLE ")
	definition.Close()
	if !permanent {
		return nil, "Temporary tables and views cannot be opened or edited through a separate source-row session.", nil
	}
	rows, err := session.work.client.Execute(`SELECT c.COLUMN_NAME,c.COLUMN_TYPE,c.DATA_TYPE,COALESCE(c.GENERATION_EXPRESSION,''),COALESCE(k.ORDINAL_POSITION,0),c.EXTRA FROM information_schema.COLUMNS c LEFT JOIN information_schema.KEY_COLUMN_USAGE k ON k.TABLE_SCHEMA=c.TABLE_SCHEMA AND k.TABLE_NAME=c.TABLE_NAME AND k.COLUMN_NAME=c.COLUMN_NAME AND k.CONSTRAINT_NAME='PRIMARY' WHERE BINARY c.TABLE_SCHEMA=? AND BINARY c.TABLE_NAME=? ORDER BY c.ORDINAL_POSITION LIMIT 4097`, schema, table)
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()
	if rows.RowNumber() == 0 || rows.RowNumber() > maxResultColumns {
		return nil, mysqlSourceUnavailable, nil
	}
	columns := make([]mysqlSourceColumn, 0, rows.RowNumber())
	for index := 0; index < rows.RowNumber(); index++ {
		name, _ := rows.GetString(index, 0)
		native, _ := rows.GetString(index, 1)
		dataType, _ := rows.GetString(index, 2)
		generated, _ := rows.GetString(index, 3)
		primary, _ := rows.GetInt(index, 4)
		extra, _ := rows.GetString(index, 5)
		if name == "" || native == "" || primary < 0 || primary > int64(rows.RowNumber()) {
			return nil, mysqlSourceUnavailable, nil
		}
		// GetString aliases the driver's pooled packet storage. Provenance
		// outlives this result and must own every retained metadata string.
		columns = append(columns, mysqlSourceColumn{name: strings.Clone(name), nativeType: strings.Clone(native), dataType: strings.Clone(dataType), primaryKey: int(primary), generated: generated != "", invisible: strings.Contains(extra, "INVISIBLE")})
	}
	return columns, "", nil
}

func mysqlSourceForFields(schema, table string, fields []*wire.Field, metadata []mysqlSourceColumn) *protocol.ResultSource {
	byName := make(map[string]int, len(metadata))
	primaryCount := 0
	for index, column := range metadata {
		if column.name == "" || len(column.name) > 256 || column.nativeType == "" || len(column.nativeType) > 16_384 || !utf8.ValidString(column.name) || !utf8.ValidString(column.nativeType) {
			return mysqlReadOnlySource("The source column metadata exceeds the supported limits. Open the table from Connections.")
		}
		if _, duplicate := byName[column.name]; duplicate {
			return mysqlReadOnlySource(mysqlSourceUnavailable)
		}
		byName[column.name] = index
		if column.primaryKey > 0 {
			primaryCount++
		}
	}
	if primaryCount == 0 {
		return mysqlReadOnlySource("The source table has no primary key.")
	}
	source := &protocol.ResultSource{Schema: schema, Table: table, Columns: make([]protocol.ResultSourceColumn, 0, len(fields))}
	seen, keys := map[int]bool{}, map[int]bool{}
	needsStorage, unsupported, invisible := false, false, false
	for _, field := range fields {
		ordinal, ok := byName[string(field.OrgName)]
		if !ok || seen[ordinal] {
			return mysqlReadOnlySource("Repeated or unavailable source columns make this result ambiguous.")
		}
		seen[ordinal] = true
		column := metadata[ordinal]
		lossless := !strings.HasPrefix(mysqlWireTypeIdentity(field), "unresolved:")
		if column.primaryKey > 0 {
			if !lossless || mysqlStorageKind(column.dataType) || !editableType(column.dataType) {
				return mysqlReadOnlySource("The primary key's result representation is not lossless. Open the table from Connections.")
			}
			keys[column.primaryKey] = true
		}
		needsStorage = needsStorage || !lossless || mysqlStorageKind(column.dataType)
		unsupported = unsupported || !editableType(column.dataType)
		invisible = invisible || column.invisible
		source.Columns = append(source.Columns, protocol.ResultSourceColumn{Name: column.name, NativeType: column.nativeType, TableIndex: ordinal, PrimaryKey: column.primaryKey, Editable: !column.generated && editableType(column.dataType) && lossless, Generated: column.generated})
	}
	if len(keys) != primaryCount {
		return mysqlReadOnlySource("The result does not contain the complete primary key. Include every key column to open its source row.")
	}
	for key := 1; key <= primaryCount; key++ {
		if !keys[key] {
			return mysqlReadOnlySource(mysqlSourceUnavailable)
		}
	}
	switch {
	case len(seen) != len(metadata):
		source.ReadOnlyReason = "Result editing requires every source column exactly once. Open Source Row to edit the complete row."
	case needsStorage:
		source.ReadOnlyReason = "These SQL result types need lossless storage evidence before editing. Open Source Row to edit the table safely."
	case unsupported || invisible:
		source.ReadOnlyReason = "This table has unsupported or invisible columns. Open the table from Connections to review editing support."
	}
	return source
}
