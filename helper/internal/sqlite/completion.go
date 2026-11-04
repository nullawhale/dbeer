package sqlite

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

const sqliteCompletionPageSize = 200
const sqliteCompletionPages = 50

// Completion reads only the namespaces already open in this physical session.
// A profile's independent service connection therefore cannot discover a tab's
// temporary objects or attachments, and metadata reads never open another file.
func (s *Session) completion(ctx context.Context, c protocol.Command, sink adapter.ResultSink) protocol.Response {
	r := c.Catalog
	if r == nil || r.Page >= sqliteCompletionPages {
		return s.fail(c, ctx, errors.New("SQLite completion metadata is limited to 10,000 objects."))
	}
	databases, _, err := s.query(ctx, "PRAGMA database_list")
	if err != nil {
		return s.fail(c, ctx, err)
	}
	parts := []string{}
	args := []any{}
	for _, database := range databases {
		if len(database) != 3 || database[1].Type != "text" {
			return s.fail(c, ctx, errors.New("SQLite session metadata is unavailable."))
		}
		schema := text(database[1])
		if r.Schema != "" && schema != r.Schema {
			continue
		}
		schemaOrder := integer(database[0])
		if schema == "temp" {
			schemaOrder = 0
		} else if schema == "main" {
			schemaOrder = 1
		}
		parts = append(parts, "SELECT name,type AS kind,? AS schema,? AS schemaOrder FROM "+quote(schema)+".sqlite_schema WHERE type IN ('table','view') AND substr(name,1,7) COLLATE NOCASE <> 'sqlite_' AND name NOT IN (SELECT name FROM pragma_table_list WHERE schema=? AND type='shadow')")
		args = append(args, schema, schemaOrder, schema)
	}
	if len(parts) == 0 {
		return s.fail(c, ctx, errors.New("The SQLite schema is not open in this session."))
	}
	args = append(args, sqliteCompletionPageSize+1, r.Page*sqliteCompletionPageSize)
	rows, _, err := s.query(ctx, "SELECT * FROM ("+strings.Join(parts, " UNION ALL ")+") ORDER BY schemaOrder,name COLLATE BINARY,kind COLLATE BINARY LIMIT ? OFFSET ?", args...)
	if err != nil {
		return s.fail(c, ctx, err)
	}
	limited := r.Page == sqliteCompletionPages-1 && len(rows) > sqliteCompletionPageSize
	if len(rows) > sqliteCompletionPageSize {
		rows = rows[:sqliteCompletionPageSize]
	}
	for i, row := range rows {
		columns, err := s.tableInfo(ctx, text(row[2]), text(row[0]))
		if err != nil {
			return s.fail(c, ctx, err)
		}
		names := []string{}
		types := map[string]string{}
		for _, column := range columns {
			if column.Hidden == 1 {
				continue
			}
			names = append(names, column.Name)
			types[column.Name] = column.NativeType
		}
		namesJSON, _ := json.Marshal(names)
		typesJSON, _ := json.Marshal(types)
		rows[i] = []protocol.SQLiteValue{row[0], row[1], row[2], stringValue(string(namesJSON)), stringValue("[]"), stringValue("[]"), stringValue(string(typesJSON)), row[3]}
	}
	response := s.catalogRows(ctx, c, []string{"name", "kind", "schema", "columns", "foreignKeys", "signatures", "columnTypes", "schemaOrder"}, rows, sink)
	if response.Type == "query.result" && limited {
		response.DisplayNotice = "SQLite completion metadata is limited to 10,000 objects."
	}
	return response
}
