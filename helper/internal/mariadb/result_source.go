package mariadb

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

const mariadbSourceUnavailable = "The source table metadata is unavailable. Open the table from Connections to edit it."

type mariadbSourceColumn struct {
	name, nativeType, dataType string
	primaryKey                 int
	generated, invisible       bool
}

func mariadbReadOnlySource(reason string) *protocol.ResultSource {
	return &protocol.ResultSource{Columns: []protocol.ResultSourceColumn{}, ReadOnlyReason: reason}
}

// attachResultSource runs within executeWith's exclusive worker, after the sole
// user execution has completed. A display label is never used as an origin.
func (session *Session) attachResultSource(ctx context.Context, sql string, collector *collector) error {
	selection, reason := resultsource.Parse(sql, "mariadb")
	if reason != "" || len(collector.resultSets) != 0 {
		if reason == "" {
			reason = resultsource.Unsupported
		}
		collector.response.Source = mariadbReadOnlySource(reason)
		return nil
	}
	collector.sourceReadCompleted = true
	if ctx.Err() != nil || len(collector.originFields) == 0 || len(collector.response.Columns) != len(collector.originFields) {
		collector.response.Source = mariadbReadOnlySource(mariadbSourceUnavailable)
		return nil
	}
	inTransaction := session.work.client.IsInTransaction()
	if collector.actualTerminalStatus != nil {
		inTransaction = *collector.actualTerminalStatus&wire.SERVER_STATUS_IN_TRANS != 0
	}
	if inTransaction {
		collector.response.Source = mariadbReadOnlySource("Source-row actions require a result loaded outside an explicit transaction.")
		return nil
	}
	schema, table, ok := mariadbResultOrigin(selection, collector.originFields)
	if !ok {
		collector.response.Source = mariadbReadOnlySource("The server did not identify one unambiguous base table for every result column.")
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
		reason = mariadbSourceUnavailable
	}
	if reason != "" {
		collector.response.Source = mariadbReadOnlySource(reason)
		return nil
	}
	collector.response.Source = mariadbSourceForFields(schema, table, collector.originFields, metadata)
	if encoded, marshalErr := json.Marshal(collector.response); marshalErr != nil || len(encoded)+1024 > collector.maxBytes {
		collector.response.Source = mariadbReadOnlySource("Source metadata exceeds the display limit. Open the table from Connections.")
	}
	return nil
}

func mariadbResultOrigin(selection resultsource.Selection, fields []*wire.Field) (string, string, bool) {
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

func (session *Session) resultSourceMetadata(schema, table string) ([]mariadbSourceColumn, string, error) {
	// Origin identifiers themselves use the connection's result encoding. A
	// lossy encoding could make an unqualified Unicode schema name collide with
	// another actual schema, even when its integer key value remains exact.
	encoding, err := session.work.client.Execute("SELECT @@SESSION.character_set_client,@@SESSION.character_set_connection,@@SESSION.character_set_results,@@SESSION.sql_mode")
	if err != nil {
		return nil, "", err
	}
	losslessEncoding := encoding.RowNumber() == 1 && encoding.ColumnNumber() == 4
	for i := 0; i < 3 && losslessEncoding; i++ {
		charset, charsetErr := encoding.GetString(0, i)
		losslessEncoding = charsetErr == nil && charset == "utf8mb4"
	}
	mode, modeErr := encoding.GetString(0, 3)
	compatibleMode := modeErr == nil
	for _, part := range strings.Split(mode, ",") {
		compatibleMode = compatibleMode && part != "EMPTY_STRING_IS_NULL" && part != "ORACLE"
	}
	encoding.Close()
	if !compatibleMode {
		return nil, "Source-row editing requires a native SQL mode that preserves exact empty values and parameter syntax; no mode is changed implicitly.", nil
	}
	if !losslessEncoding {
		return nil, "Source-row actions require already active utf8mb4 client, connection and result encodings. Restore those settings explicitly and run the query again.", nil
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
	object, err := session.work.client.Execute(`SELECT TABLE_TYPE,ENGINE FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? LIMIT 1`, schema, table)
	if err != nil {
		return nil, "", err
	}
	if object.RowNumber() != 1 {
		object.Close()
		return nil, mariadbSourceUnavailable, nil
	}
	kind, _ := object.GetString(0, 0)
	engine, _ := object.GetString(0, 1)
	baseInnoDB := kind == "BASE TABLE" && engine == "InnoDB"
	object.Close()
	if !baseInnoDB {
		return nil, "SQL result editing and source rows require an InnoDB base table with a primary key.", nil
	}
	rows, err := session.work.client.Execute(`SELECT c.COLUMN_NAME,c.COLUMN_TYPE,c.DATA_TYPE,COALESCE(c.GENERATION_EXPRESSION,''),COALESCE(k.ORDINAL_POSITION,0),c.EXTRA FROM information_schema.COLUMNS c LEFT JOIN information_schema.KEY_COLUMN_USAGE k ON BINARY k.TABLE_SCHEMA=BINARY c.TABLE_SCHEMA AND BINARY k.TABLE_NAME=BINARY c.TABLE_NAME AND BINARY k.COLUMN_NAME=BINARY c.COLUMN_NAME AND k.CONSTRAINT_NAME='PRIMARY' WHERE BINARY c.TABLE_SCHEMA=BINARY ? AND BINARY c.TABLE_NAME=BINARY ? ORDER BY c.ORDINAL_POSITION LIMIT 4097`, schema, table)
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()
	if rows.RowNumber() == 0 || rows.RowNumber() > maxResultColumns {
		return nil, mariadbSourceUnavailable, nil
	}
	columns := make([]mariadbSourceColumn, 0, rows.RowNumber())
	for index := 0; index < rows.RowNumber(); index++ {
		name, _ := rows.GetString(index, 0)
		native, _ := rows.GetString(index, 1)
		dataType, _ := rows.GetString(index, 2)
		generated, _ := rows.GetString(index, 3)
		primary, _ := rows.GetInt(index, 4)
		extra, _ := rows.GetString(index, 5)
		if name == "" || native == "" || primary < 0 || primary > int64(rows.RowNumber()) {
			return nil, mariadbSourceUnavailable, nil
		}
		// GetString aliases the driver's pooled packet storage. Provenance
		// outlives this result and must own every retained metadata string.
		columns = append(columns, mariadbSourceColumn{name: strings.Clone(name), nativeType: strings.Clone(native), dataType: strings.Clone(dataType), primaryKey: int(primary), generated: generated != "", invisible: strings.Contains(strings.ToUpper(extra), "INVISIBLE")})
	}
	return columns, "", nil
}

func mariadbSourceForFields(schema, table string, fields []*wire.Field, metadata []mariadbSourceColumn) *protocol.ResultSource {
	byName := make(map[string]int, len(metadata))
	primaryCount := 0
	for index, column := range metadata {
		if column.name == "" || len(column.name) > 256 || column.nativeType == "" || len(column.nativeType) > 16_384 || !utf8.ValidString(column.name) || !utf8.ValidString(column.nativeType) {
			return mariadbReadOnlySource("The source column metadata exceeds the supported limits. Open the table from Connections.")
		}
		if _, duplicate := byName[column.name]; duplicate {
			return mariadbReadOnlySource(mariadbSourceUnavailable)
		}
		byName[column.name] = index
		if column.primaryKey > 0 {
			primaryCount++
		}
	}
	if primaryCount == 0 {
		return mariadbReadOnlySource("The source table has no primary key.")
	}
	source := &protocol.ResultSource{Schema: schema, Table: table, Columns: make([]protocol.ResultSourceColumn, 0, len(fields))}
	seen, keys := map[int]bool{}, map[int]bool{}
	needsStorage, unsupported, invisible := false, false, false
	for _, field := range fields {
		ordinal, ok := byName[string(field.OrgName)]
		if !ok || seen[ordinal] {
			return mariadbReadOnlySource("Repeated or unavailable source columns make this result ambiguous.")
		}
		seen[ordinal] = true
		column := metadata[ordinal]
		lossless := !strings.HasPrefix(mariadbWireTypeIdentity(field), "unresolved:")
		if column.primaryKey > 0 {
			if !lossless || MariaDBStorageKind(column.dataType) || !MariaDBEditableKind(column.dataType) {
				return mariadbReadOnlySource("The primary key's result representation is not lossless. Open the table from Connections.")
			}
			keys[column.primaryKey] = true
		}
		needsStorage = needsStorage || !lossless || MariaDBStorageKind(column.dataType)
		unsupported = unsupported || !MariaDBEditableKind(column.dataType)
		invisible = invisible || column.invisible
		source.Columns = append(source.Columns, protocol.ResultSourceColumn{Name: column.name, NativeType: column.nativeType, TableIndex: ordinal, PrimaryKey: column.primaryKey, Editable: !column.generated && MariaDBEditableKind(column.dataType) && lossless, Generated: column.generated})
	}
	if len(keys) != primaryCount {
		return mariadbReadOnlySource("The result does not contain the complete primary key. Include every key column to open its source row.")
	}
	for key := 1; key <= primaryCount; key++ {
		if !keys[key] {
			return mariadbReadOnlySource(mariadbSourceUnavailable)
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
	if source.ReadOnlyReason == "" {
		source.ReadOnlyReason = "SQL-result editing is deferred for MariaDB. Open the table from Connections for the supported grid Preview/Apply workflow."
	}
	for i := range source.Columns {
		source.Columns[i].Editable = false
	}

	return source
}
