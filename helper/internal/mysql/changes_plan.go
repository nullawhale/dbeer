package mysql

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type editColumn struct {
	name, nativeType, dataType, generated string
	primary                               int
	binary                                bool
	ambiguousEmptyEnum                    bool
	ambiguousEnum                         bool
	ambiguousSet                          bool
}
type editMetadata struct {
	columns   []editColumn
	primary   []int
	qualified string
}
type editPlan struct {
	kind, sql, lockSQL string
	storageToken       string
	parameters, keys   []protocol.CellValue
	original           []protocol.CellValue
}

func editFailure(category, message string) error {
	return &adapter.ConnectionError{Category: category, Message: message}
}

func (session *Session) editMetadata(request protocol.ChangesRequest) (editMetadata, error) {
	metadata := editMetadata{qualified: QuoteIdentifier(request.Schema) + "." + QuoteIdentifier(request.Table)}
	table, err := session.work.client.Execute(`SELECT TABLE_TYPE,ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA=? AND TABLE_NAME=? LIMIT 1`, request.Schema, request.Table)
	if err != nil {
		return metadata, err
	}
	if table.RowNumber() != 1 {
		table.Close()
		return metadata, editFailure("validation", "The table is unavailable. Refresh its structure.")
	}
	kind, _ := table.GetString(0, 0)
	engine, _ := table.GetString(0, 1)
	table.Close()
	if kind != "BASE TABLE" || engine != "InnoDB" {
		return metadata, editFailure("validation", "Data editing requires an InnoDB table with a primary key.")
	}
	rows, err := session.work.client.Execute(`SELECT c.COLUMN_NAME,c.COLUMN_TYPE,c.DATA_TYPE,COALESCE(c.GENERATION_EXPRESSION,''),COALESCE(k.ORDINAL_POSITION,0),c.EXTRA,c.CHARACTER_SET_NAME FROM information_schema.COLUMNS c LEFT JOIN information_schema.KEY_COLUMN_USAGE k ON k.TABLE_SCHEMA=c.TABLE_SCHEMA AND k.TABLE_NAME=c.TABLE_NAME AND k.COLUMN_NAME=c.COLUMN_NAME AND k.CONSTRAINT_NAME='PRIMARY' WHERE c.TABLE_SCHEMA=? AND c.TABLE_NAME=? ORDER BY c.ORDINAL_POSITION LIMIT 4097`, request.Schema, request.Table)
	if err != nil {
		return metadata, err
	}
	defer rows.Close()
	if rows.RowNumber() != len(request.Columns) {
		return metadata, editFailure("validation", "The table structure changed. Reload data before editing.")
	}
	for index, expected := range request.Columns {
		name, _ := rows.GetString(index, 0)
		native, _ := rows.GetString(index, 1)
		dataType, _ := rows.GetString(index, 2)
		generated, _ := rows.GetString(index, 3)
		primary, _ := rows.GetInt(index, 4)
		extra, _ := rows.GetString(index, 5)
		charset, _ := rows.GetString(index, 6)
		if name != expected.Name || expected.Engine != "mysql" || native != expected.NativeType || strings.Contains(extra, "INVISIBLE") {
			return metadata, editFailure("validation", "The table structure or native types changed. Reload data before editing.")
		}
		ambiguousEmpty := false
		ambiguousValues := false
		if dataType == "enum" || dataType == "set" {
			labels, ok := mysqlTypeLabels(native, dataType)
			if !ok {
				return metadata, editFailure("validation", "The native ENUM/SET definition is unavailable. Reload the table structure.")
			}
			for _, label := range labels {
				if label == "" {
					ambiguousEmpty = true
				}
			}
			ambiguousValues = mysqlAmbiguousChoiceLabels(dataType, labels)
		}
		metadata.columns = append(metadata.columns, editColumn{name: name, nativeType: native, dataType: dataType, generated: generated, primary: int(primary), binary: binaryType(dataType) || charset == "binary" || (dataType == "enum" || dataType == "set") && charset == "", ambiguousEmptyEnum: ambiguousEmpty && dataType == "enum", ambiguousEnum: ambiguousValues && dataType == "enum", ambiguousSet: ambiguousValues && dataType == "set"})
		if primary > 0 {
			metadata.primary = append(metadata.primary, index)
		}
	}
	if len(metadata.primary) == 0 {
		return metadata, editFailure("validation", "A primary key is required for data editing.")
	}
	sort.Slice(metadata.primary, func(a, b int) bool {
		return metadata.columns[metadata.primary[a]].primary < metadata.columns[metadata.primary[b]].primary
	})
	return metadata, nil
}

func editableType(kind string) bool {
	switch kind {
	case "tinyint", "smallint", "mediumint", "int", "bigint", "decimal", "numeric", "float", "double", "bit", "char", "varchar", "tinytext", "text", "mediumtext", "longtext", "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob", "date", "datetime", "timestamp", "time", "year", "json", "enum", "set", "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection", "geomcollection", "vector":
		return true
	}
	return false
}

func binaryType(kind string) bool {
	switch kind {
	case "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob", "bit", "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection", "geomcollection", "vector", "enumBinary", "setBinary":
		return true
	}
	return false
}

func planChanges(metadata editMetadata, request protocol.ChangesRequest) ([]editPlan, error) {
	indices := map[string]int{}
	var quoted []string
	for index, column := range metadata.columns {
		indices[column.name] = index
		quoted = append(quoted, QuoteIdentifier(column.name))
	}
	quoted = append(quoted, mysqlStorageProjections(mysqlStorageColumns(metadata), mysqlStorageKinds(metadata))...)
	plans := make([]editPlan, 0, len(request.Changes))
	for _, change := range request.Changes {
		plan := editPlan{kind: change.Kind, original: change.Original, storageToken: change.StorageToken}
		var columns, expressions, updates, predicates []string
		for _, assignment := range change.Values {
			column := metadata.columns[indices[assignment.Column]]
			if column.generated != "" || !editableType(column.dataType) {
				return nil, editFailure("validation", "Generated columns and unsupported native types are read-only.")
			}
			value := assignment.Value
			binary := column.binary || binaryType(column.dataType)
			if value.Kind == "text" && binary || value.Kind == "binary" && !binary {
				return nil, editFailure("validation", "The assignment value does not match the column's native type.")
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
			plan.lockSQL = "SELECT " + strings.Join(quoted, ", ") + " FROM " + metadata.qualified + " WHERE " + strings.Join(predicates, " AND ") + " FOR UPDATE"
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
		}
		plans = append(plans, plan)
	}
	return plans, nil
}

func bindCells(values []protocol.CellValue) ([]any, error) {
	args := make([]any, len(values))
	for index, value := range values {
		switch value.Kind {
		case "null":
			args[index] = nil
		case "text":
			args[index] = *value.Value
		case "binary":
			data, err := base64.StdEncoding.DecodeString(*value.Value)
			if err != nil {
				return nil, editFailure("validation", "Invalid binary assignment.")
			}
			args[index] = data
		default:
			return nil, editFailure("validation", "Invalid bound value.")
		}
	}
	return args, nil
}

func previewChanges(command protocol.Command, plans []editPlan) protocol.Response {
	response := protocol.Response{Type: "query.result", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID, TransactionStatus: "idle", CommandTag: "PREVIEW", Columns: []protocol.Column{{Index: 0, Name: "operation"}, {Index: 1, Name: "sql"}, {Index: 2, Name: "parameters"}}, Rows: [][]*string{}}
	for _, plan := range plans {
		encoded, _ := json.Marshal(plan.parameters)
		if plan.parameters == nil {
			encoded = []byte("[]")
		}
		response.Rows = append(response.Rows, []*string{text(plan.kind), text(plan.sql), text(string(encoded))})
	}
	response.RowCount = int64(len(plans))
	response.DisplayedRowCount = len(plans)
	encoded, _ := json.Marshal(response)
	if len(encoded) > MaxResultBytes {
		failure := protocol.ErrorResponse(command, "validation", "The preview exceeds the display limit. Apply a smaller batch.")
		failure.Connected = true
		failure.TransactionStatus = "idle"
		return failure
	}
	return response
}

func applySuccess(command protocol.Command, count int) protocol.Response {
	return protocol.Response{Type: "query.result", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID, TransactionStatus: "idle", CommandTag: fmt.Sprintf("APPLY %d", count), RowCount: int64(count), Rows: [][]*string{}, Columns: []protocol.Column{}}
}
