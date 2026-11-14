package mariadb

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"dbeer/helper/internal/protocol"
)

type editColumn struct {
	name, nativeType, dataType, generated  string
	primary                                int
	binary, nullable, insert, update, read bool
}

type editMetadata struct {
	columns   []editColumn
	primary   []int
	qualified string
	periods   []MariaDBPeriodColumn
}

type editPlan struct {
	kind, sql, lockSQL, storageToken string
	parameters, keys, original       []protocol.CellValue
}

// The same resolved target is opened before catalog admission. I_S cannot
// authorize a temporary table shadowing the captured permanent table.
func mariaDBBaseTable(execution *changeExecution, schema, name string) ([][]*string, error) {
	qualified := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
	definition, err := execution.query("SHOW CREATE TABLE " + qualified)
	if err != nil {
		return nil, err
	}
	ddl, ddlErr := definition.GetString(0, 1)
	permanent := definition.RowNumber() == 1 && ddlErr == nil && strings.HasPrefix(ddl, "CREATE TABLE ")
	definition.Close()
	if !permanent {
		return nil, editFailure("validation", "Row writes require a permanent base table; temporary tables and views are read-only in this workflow.")
	}
	meta, err := mariaDBMetadataRows(execution, `SELECT TABLE_TYPE,ENGINE,TABLE_COLLATION,CREATE_OPTIONS,CAST(CREATE_TIME AS CHAR) FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? LIMIT 2`, schema, name)
	if err != nil {
		return nil, err
	}
	if len(meta) != 1 || (rowText(meta[0], 0) != "BASE TABLE" && rowText(meta[0], 0) != "SYSTEM VERSIONED") || rowText(meta[0], 1) != "InnoDB" {
		return nil, editFailure("validation", "This atomic row-write workflow requires a MariaDB InnoDB base table. Nontransactional MyISAM and Aria writes need a separately reviewed workflow.")
	}
	return meta, nil
}

func (session *Session) editMetadata(execution *changeExecution, request protocol.ChangesRequest) (editMetadata, error) {
	metadata := editMetadata{qualified: QuoteIdentifier(request.Schema) + "." + QuoteIdentifier(request.Table)}
	meta, err := mariaDBBaseTable(execution, request.Schema, request.Table)
	if err != nil {
		return metadata, err
	}
	rows, err := mariaDBMetadataRows(execution, `SELECT c.COLUMN_NAME,c.COLUMN_TYPE,c.DATA_TYPE,COALESCE(c.GENERATION_EXPRESSION,''),COALESCE(k.ORDINAL_POSITION,0),c.EXTRA,c.CHARACTER_SET_NAME,c.IS_NULLABLE,c.PRIVILEGES,c.ORDINAL_POSITION FROM information_schema.COLUMNS c LEFT JOIN information_schema.KEY_COLUMN_USAGE k ON BINARY k.TABLE_SCHEMA=BINARY c.TABLE_SCHEMA AND BINARY k.TABLE_NAME=BINARY c.TABLE_NAME AND BINARY k.COLUMN_NAME=BINARY c.COLUMN_NAME AND k.CONSTRAINT_NAME='PRIMARY' WHERE BINARY c.TABLE_SCHEMA=BINARY ? AND BINARY c.TABLE_NAME=BINARY ? ORDER BY c.ORDINAL_POSITION LIMIT 4097`, request.Schema, request.Table)
	if err != nil {
		return metadata, err
	}
	if len(rows) != len(request.Columns) {
		return metadata, editFailure("validation", "The ordered table columns changed. Reload data before editing.")
	}
	for index, expected := range request.Columns {
		row := rows[index]
		name, native, kind := rowText(row, 0), rowText(row, 1), rowText(row, 2)
		primary, ok := rowInt(row, 4)
		ordinal, ordinalOK := rowInt(row, 9)
		if !ok || !ordinalOK || ordinal != index+1 || primary < 0 || primary > len(rows) || name != expected.Name || expected.Engine != "mariadb" || native != expected.NativeType {
			return metadata, editFailure("validation", "The table structure or native types changed. Reload data before editing.")
		}
		privileges := "," + strings.ToLower(rowText(row, 8)) + ","
		column := editColumn{name: name, nativeType: native, dataType: kind, generated: rowText(row, 3), primary: primary, binary: mariaDBBinaryType(kind) || rowText(row, 6) == "binary" || (kind == "enum" || kind == "set") && rowText(row, 6) == "", nullable: rowText(row, 7) == "YES", insert: strings.Contains(privileges, ",insert,"), update: strings.Contains(privileges, ",update,"), read: strings.Contains(privileges, ",select,")}
		if column.generated == "" && strings.Contains(strings.ToUpper(rowText(row, 5)), "GENERATED") {
			column.generated = "server-maintained"
		}
		if !column.read {
			return metadata, editFailure("validation", "Complete SELECT privileges are required to compare the original row before writing.")
		}
		metadata.columns = append(metadata.columns, column)
		if primary > 0 {
			metadata.primary = append(metadata.primary, index)
		}
	}
	if len(metadata.primary) == 0 {
		return metadata, editFailure("validation", "A complete native primary key is required for row editing.")
	}
	periodColumns := make([]MariaDBPeriodColumn, len(metadata.columns))
	for i, column := range metadata.columns {
		periodColumns[i] = MariaDBPeriodColumn{Name: column.name, NativeType: column.nativeType, DataType: column.dataType, Generated: column.generated}
	}
	metadata.periods, err = MariaDBSystemPeriods(execution.query, request.Schema, request.Table, rowText(meta[0], 0), periodColumns)
	if err != nil {
		return metadata, err
	}
	sort.Slice(metadata.primary, func(a, b int) bool {
		return metadata.columns[metadata.primary[a]].primary < metadata.columns[metadata.primary[b]].primary
	})
	for i, index := range metadata.primary {
		if metadata.columns[index].primary != i+1 {
			return metadata, editFailure("validation", "The native primary-key order is incomplete.")
		}
	}
	return metadata, nil
}

func mariaDBBinaryType(kind string) bool {
	switch kind {
	case "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob", "bit", "enumBinary", "setBinary", "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection":
		return true
	}
	return false
}

func storageKinds(metadata editMetadata) map[string]string {
	kinds := map[string]string{}
	for _, column := range metadata.columns {
		kinds[column.name] = column.dataType
	}
	for _, period := range metadata.periods {
		if period.Implicit {
			kinds[period.Name] = period.DataType
		}
	}
	return kinds
}

func planChanges(metadata editMetadata, request protocol.ChangesRequest, scope mariaDBWriteScope) ([]editPlan, error) {
	indices := map[string]int{}
	quoted := []string{}
	for i, column := range metadata.columns {
		indices[column.name] = i
		quoted = append(quoted, MariaDBStableProjection(column.name, column.dataType))
	}
	kinds := storageKinds(metadata)
	storageColumns := MariaDBStorageColumns(kinds)
	quoted = append(quoted, MariaDBStorageProjections(storageColumns, kinds)...)
	plans := make([]editPlan, 0, len(request.Changes))
	for _, change := range request.Changes {
		plan := editPlan{kind: change.Kind, original: change.Original, storageToken: change.StorageToken}
		if change.Kind != "insert" && len(storageColumns) > 0 && !validMariaDBStorageToken(change.StorageToken) {
			return nil, editFailure("validation", "Reload this row with complete native storage evidence before editing it.")
		}
		var columns, expressions, updates, predicates []string
		for _, assignment := range change.Values {
			index, exists := indices[assignment.Column]
			if !exists {
				return nil, editFailure("validation", "An assignment column is unavailable.")
			}
			column := metadata.columns[index]
			if column.generated != "" || !MariaDBEditableKind(column.dataType) {
				return nil, editFailure("validation", "Generated columns and native types not implemented by this row writer are read-only.")
			}
			if change.Kind == "insert" && !column.insert || change.Kind == "update" && !column.update {
				return nil, editFailure("validation", "The required native column write privilege is unavailable.")
			}
			value := assignment.Value
			if value.Kind == "text" && column.binary || value.Kind == "binary" && !column.binary || value.Kind == "null" && !column.nullable {
				return nil, editFailure("validation", "The assignment does not match the column's native type or nullability.")
			}
			columns = append(columns, QuoteIdentifier(column.name))
			expression := "?"
			if value.Kind == "default" {
				expression = "DEFAULT"
			} else {
				plan.parameters = append(plan.parameters, value)
			}
			expressions = append(expressions, expression)
			updates = append(updates, QuoteIdentifier(column.name)+" = "+expression)
		}
		if change.Kind != "insert" {
			for _, index := range metadata.primary {
				value := change.Original[index]
				if value.Kind == "null" {
					return nil, editFailure("validation", "The original primary key is missing. Reload data.")
				}
				predicates = append(predicates, QuoteIdentifier(metadata.columns[index].name)+" = ?")
				plan.keys = append(plan.keys, value)
			}
			plan.lockSQL = scope.wrap("SELECT " + strings.Join(quoted, ", ") + " FROM " + metadata.qualified + " WHERE " + strings.Join(predicates, " AND ") + " FOR UPDATE")
		}
		switch change.Kind {
		case "insert":
			plan.sql = "INSERT INTO " + metadata.qualified + " (" + strings.Join(columns, ", ") + ") VALUES (" + strings.Join(expressions, ", ") + ")"
		case "update":
			plan.sql = "UPDATE " + metadata.qualified + " SET " + strings.Join(updates, ", ") + " WHERE " + strings.Join(predicates, " AND ")
			plan.parameters = append(plan.parameters, plan.keys...)
		case "delete":
			plan.sql = "DELETE FROM " + metadata.qualified + " WHERE " + strings.Join(predicates, " AND ")
			plan.parameters = append(plan.parameters, plan.keys...)
		default:
			return nil, editFailure("validation", "Invalid row operation.")
		}
		plan.sql = scope.wrap(plan.sql)
		plans = append(plans, plan)
	}
	return plans, nil
}

func validMariaDBStorageToken(value string) bool {
	const prefix = "mariadb.storage.v1:"
	if !strings.HasPrefix(value, prefix) || len(value) != len(prefix)+64 {
		return false
	}
	for _, c := range value[len(prefix):] {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func bindCells(values []protocol.CellValue) ([]any, error) {
	args := make([]any, len(values))
	for i, value := range values {
		switch value.Kind {
		case "null":
			args[i] = nil
		case "text":
			if value.Value == nil {
				return nil, editFailure("validation", "Invalid text assignment.")
			}
			args[i] = *value.Value
		case "binary":
			if value.Value == nil {
				return nil, editFailure("validation", "Invalid binary assignment.")
			}
			data, err := base64.StdEncoding.DecodeString(*value.Value)
			if err != nil {
				return nil, editFailure("validation", "Invalid binary assignment.")
			}
			args[i] = data
		default:
			return nil, editFailure("validation", "Invalid bound value.")
		}
	}
	return args, nil
}

func previewChanges(command protocol.Command, plans []editPlan) protocol.Response {
	response := protocol.Response{Type: "query.result", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID, TransactionStatus: "idle", Connected: true, CommandTag: "PREVIEW", Columns: []protocol.Column{{Index: 0, Name: "operation"}, {Index: 1, Name: "sql"}, {Index: 2, Name: "parameters"}}, Rows: [][]*string{}}
	for _, plan := range plans {
		parameters := plan.parameters
		if parameters == nil {
			parameters = []protocol.CellValue{}
		}
		encoded, err := json.Marshal(parameters)
		if err != nil {
			return protocol.ErrorResponse(command, "validation", "The row preview cannot be encoded.")
		}
		response.Rows = append(response.Rows, []*string{text(plan.kind), text(plan.sql), text(string(encoded))})
	}
	response.RowCount = int64(len(plans))
	response.DisplayedRowCount = len(plans)
	encoded, err := json.Marshal(response)
	if err != nil || len(encoded) > MaxResultBytes {
		return protocol.ErrorResponse(command, "validation", "The preview exceeds the display limit. Apply a smaller batch.")
	}
	return response
}

func applySuccess(command protocol.Command, count int) protocol.Response {
	return protocol.Response{Type: "query.result", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID, Connected: true, TransactionStatus: "idle", CommandTag: fmt.Sprintf("APPLY %d", count), RowCount: int64(count), Rows: [][]*string{}, Columns: []protocol.Column{}}
}
