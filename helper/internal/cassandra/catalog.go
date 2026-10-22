package cassandra

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"
	"strconv"
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type metadataCollector struct {
	columns []protocol.Column
	rows    []map[string]string
	bytes   int
}

func (c *metadataCollector) Begin(_ int, columns []protocol.Column) error {
	c.columns = columns
	return nil
}
func (c *metadataCollector) Row(_ int, row []*string) error {
	encoded, _ := json.Marshal(row)
	c.bytes += len(encoded)
	if len(c.rows) >= 16384 || c.bytes > maxBytes {
		return errors.New("Catalog metadata exceeds the supported bound")
	}
	record := map[string]string{}
	for i, value := range row {
		if value != nil {
			record[c.columns[i].Name] = *value
		}
	}
	c.rows = append(c.rows, record)
	return nil
}
func (*metadataCollector) End(int, protocol.ResultSet) error { return nil }
func (s *Session) metadata(ctx context.Context, command protocol.Command, sql string, values ...any) ([]map[string]string, *protocol.Response) {
	collector := &metadataCollector{}
	_, _, _, failure := s.query(ctx, command, sql, values, 0, collector, &displayBudget{}, true, false, nil, 0, false)
	if failure != nil {
		failure.Message = "Catalog metadata is unavailable, exceeds the supported size, or access was denied."
	}
	return collector.rows, failure
}
func stringsResult(command protocol.Command, names []string, rows [][]*string) protocol.ResultSet {
	known := false
	r := protocol.ResultSet{Columns: []protocol.Column{}, Rows: rows, CommandTag: "CATALOG", RowCount: int64(len(rows)), DisplayedRowCount: len(rows), AffectedRowCountKnown: &known}
	for i, name := range names {
		r.Columns = append(r.Columns, protocol.Column{Index: i, Name: name, Engine: "cassandra", NativeType: "text"})
	}
	return r
}
func cells(values ...string) []*string {
	r := make([]*string, len(values))
	for i, value := range values {
		v := value
		r[i] = &v
	}
	return r
}
func (s *Session) catalog(ctx context.Context, command protocol.Command, sink adapter.ResultSink) protocol.Response {
	request := command.Catalog
	if !request.Valid() {
		return s.failure(command, "protocol", "Invalid Cassandra catalog request.")
	}
	if request.Kind == "browse" {
		return s.browse(ctx, command, sink)
	}
	if request.Kind == "foreignKeys" {
		return s.failure(command, "unsupported", "Cassandra does not support foreign keys.")
	}
	if request.Kind == "select" {
		response := s.response(command)
		response.Columns = []protocol.Column{{Index: 0, Name: "sql", Engine: "cassandra", NativeType: "text"}}
		response.Rows = [][]*string{cells("SELECT * FROM " + qualified(request.Schema, request.Object) + " LIMIT 1000;")}
		response.RowCount = 1
		response.DisplayedRowCount = 1
		return response
	}
	if request.Kind == "name" {
		response := s.response(command)
		response.Columns = []protocol.Column{{Index: 0, Name: "name", Engine: "cassandra", NativeType: "text"}}
		response.Rows = [][]*string{cells(qualified(request.Schema, request.Object))}
		response.RowCount = 1
		response.DisplayedRowCount = 1
		return response
	}
	var rows [][]*string
	var names []string
	switch request.Kind {
	case "clusterNodes":
		return s.catalogResponse(command, clusterNodesResult(command, s.driver.GetHosts()), sink)
	case "schemas":
		names = []string{"name", "kind"}
		records, failure := s.metadata(ctx, command, "SELECT keyspace_name FROM system_schema.keyspaces")
		if failure != nil {
			return *failure
		}
		for _, record := range records {
			rows = append(rows, cells(record["keyspace_name"], "schema"))
		}
	case "objects", "search", "completion":
		names = []string{"name", "kind", "schema", "identity"}
		if request.Kind == "completion" {
			names = []string{"name", "kind", "schema", "columns", "foreignKeys", "signatures", "partitionKeys", "clusteringColumns", "staticColumns"}
		}
		objects, failure := s.catalogObjects(ctx, command)
		if failure != nil {
			return *failure
		}
		// Slice lightweight names before fetching any per-object column metadata.
		// Each completion page performs at most 200 object metadata reads.
		if request.Kind == "completion" {
			offset := request.Page * 200
			if offset >= len(objects) {
				objects = nil
			} else {
				objects = objects[offset:min(offset+200, len(objects))]
			}
		}
		rowBytes := 0
		for _, object := range objects {
			if request.Kind != "completion" {
				rows = append(rows, cells(object.name, object.kind, object.keyspace, ""))
				continue
			}
			var all, partition, clustering, statics []string
			if object.kind == "type" {
				fields, _, failure := s.typeFields(ctx, command, object.keyspace, object.name)
				if failure != nil {
					return *failure
				}
				all = fields
			} else {
				columns, failure := s.tableColumns(ctx, command, object.keyspace, object.name)
				if failure != nil {
					return *failure
				}
				for _, column := range columns {
					all = append(all, column.name)
					switch column.kind {
					case "partition_key":
						partition = append(partition, column.name)
					case "clustering":
						clustering = append(clustering, column.name)
					case "static":
						statics = append(statics, column.name)
					}
				}
			}
			row := cells(object.name, object.kind, object.keyspace, jsonNames(all), "[]", "[]", jsonNames(partition), jsonNames(clustering), jsonNames(statics))
			encoded, _ := json.Marshal(row)
			rowBytes += len(encoded)
			if rowBytes > maxBytes-4096 {
				return s.failure(command, "result", "Cassandra completion metadata exceeds the supported size. Restrict completion to one keyspace.")
			}
			rows = append(rows, row)
		}
	case "columns", "keys", "constraints", "indexes", "triggers", "definition":
		if request.ObjectKind == "type" {
			if request.Kind == "columns" {
				return s.typeColumns(ctx, command, sink)
			}
			if request.Kind == "definition" {
				return s.typeDefinition(ctx, command, sink)
			}
			return s.failure(command, "unsupported", "Cassandra user-defined types expose fields rather than table keys or indexes.")
		}
		columns, failure := s.tableColumns(ctx, command, request.Schema, request.Object)
		if failure != nil {
			return *failure
		}
		switch request.Kind {
		case "columns":
			names = []string{"name", "nativeType", "nullable", "default", "generated", "primaryKey", "editable", "editReason", "partitionKeyPosition", "clusteringPosition", "clusteringOrder", "static", "indexed"}
			partitionCount := 0
			for _, column := range columns {
				if column.kind == "partition_key" {
					partitionCount++
				}
			}
			for _, column := range columns {
				partition, clustering, primary := 0, 0, 0
				nullable := "true"
				switch column.kind {
				case "partition_key":
					partition = column.position + 1
					primary = partition
					nullable = "false"
				case "clustering":
					clustering = column.position + 1
					primary = partitionCount + clustering
					nullable = "false"
				}
				reason := editColumnReason(columns, column)
				row := cells(column.name, column.nativeType, nullable, "", "", strconv.Itoa(primary), strconv.FormatBool(reason == ""), reason, strconv.Itoa(partition), strconv.Itoa(clustering), column.order, strconv.FormatBool(column.kind == "static"), strconv.FormatBool(column.indexed))
				row[3] = nil
				rows = append(rows, row)
			}
		case "keys", "constraints":
			names = []string{"name", "kind", "definition"}
			parts := keyDefinition(columns)
			rows = append(rows, cells("PRIMARY KEY", "primaryKey", parts))
		case "indexes":
			names = []string{"name", "kind", "definition"}
			indexes, failure := s.metadata(ctx, command, "SELECT index_name, kind, options FROM system_schema.indexes WHERE keyspace_name = ? AND table_name = ?", request.Schema, request.Object)
			if failure != nil {
				return *failure
			}
			for _, index := range indexes {
				rows = append(rows, cells(index["index_name"], index["kind"], index["options"]))
			}
		case "triggers":
			names = []string{"name", "kind", "definition"}
		case "definition":
			names = []string{"name", "definition"}
			definition := tableDefinition(request.Schema, request.Object, columns)
			if request.ObjectKind == "view" {
				definition = "Materialized view " + qualified(request.Schema, request.Object) + ". Column and key definitions are shown in the catalog; CREATE VIEW reconstruction is unavailable."
			}
			rows = append(rows, cells(request.Object, definition))
		}
	default:
		return s.failure(command, "unsupported", "This catalog operation is unavailable for Cassandra.")
	}
	sort.SliceStable(rows, func(i, j int) bool {
		for k := 0; k < len(rows[i]) && k < len(rows[j]); k++ {
			if rows[i][k] != nil && rows[j][k] != nil && *rows[i][k] != *rows[j][k] {
				return *rows[i][k] < *rows[j][k]
			}
		}
		return false
	})
	return s.catalogResponse(command, stringsResult(command, names, rows), sink)
}
func (s *Session) catalogResponse(command protocol.Command, result protocol.ResultSet, sink adapter.ResultSink) protocol.Response {
	// Catalog rows are bounded independently of server data. The native catalog
	// uses paged completion and a maximum of 1000 visible detail rows.
	budget := 0
	kept := 0
	for _, row := range result.Rows {
		encoded, _ := json.Marshal(row)
		if kept >= maxRows || budget+len(encoded) > maxBytes {
			result.Truncated = true
			result.DisplayNotice = "Catalog display exceeds the supported size."
			break
		}
		budget += len(encoded)
		kept++
	}
	result.Rows = result.Rows[:kept]
	result.DisplayedRowCount = kept
	if sink != nil {
		if err := sink.Begin(0, result.Columns); err != nil {
			return s.failure(command, "cancelled", "Catalog delivery was stopped.")
		}
		for _, row := range result.Rows {
			if sink.Row(0, row) != nil {
				return s.failure(command, "cancelled", "Catalog delivery was stopped.")
			}
		}
		_ = sink.End(0, result)
	}
	response := s.response(command)
	response.Columns = result.Columns
	response.Rows = result.Rows
	response.RowCount = result.RowCount
	response.DisplayedRowCount = result.DisplayedRowCount
	response.Truncated = result.Truncated
	response.DisplayNotice = result.DisplayNotice
	response.NextCursor = result.NextCursor
	response.ResultSets = []protocol.ResultSet{result}
	return response
}
func jsonNames(names []string) string {
	if names == nil {
		names = []string{}
	}
	data, _ := json.Marshal(names)
	return string(data)
}

type tableColumn struct {
	name, nativeType, kind, order string
	position                      int
	indexed                       bool
}

func (s *Session) tableColumns(ctx context.Context, command protocol.Command, keyspace, table string) ([]tableColumn, *protocol.Response) {
	records, failure := s.metadata(ctx, command, "SELECT column_name, type, kind, position, clustering_order FROM system_schema.columns WHERE keyspace_name = ? AND table_name = ?", keyspace, table)
	if failure != nil {
		return nil, failure
	}
	indexes, failure := s.metadata(ctx, command, "SELECT index_name, options FROM system_schema.indexes WHERE keyspace_name = ? AND table_name = ?", keyspace, table)
	if failure != nil {
		return nil, failure
	}
	var columns []tableColumn
	for _, record := range records {
		position, _ := strconv.Atoi(record["position"])
		column := tableColumn{name: record["column_name"], nativeType: record["type"], kind: record["kind"], position: position, order: record["clustering_order"]}
		for _, index := range indexes {
			options := index["options"]
			target := "'target': " + quoteText(column.name)
			quotedTarget := "'target': " + quoteText(quoteIdentifier(column.name))
			if strings.Contains(options, target) || strings.Contains(options, quotedTarget) {
				column.indexed = true
			}
		}
		columns = append(columns, column)
	}
	sort.Slice(columns, func(i, j int) bool {
		priority := map[string]int{"partition_key": 0, "clustering": 1, "static": 2, "regular": 3}
		if priority[columns[i].kind] != priority[columns[j].kind] {
			return priority[columns[i].kind] < priority[columns[j].kind]
		}
		if columns[i].position != columns[j].position {
			return columns[i].position < columns[j].position
		}
		return columns[i].name < columns[j].name
	})
	return columns, nil
}
func keyDefinition(columns []tableColumn) string {
	var partition, clustering []string
	for _, column := range columns {
		switch column.kind {
		case "partition_key":
			partition = append(partition, quoteIdentifier(column.name))
		case "clustering":
			clustering = append(clustering, quoteIdentifier(column.name))
		}
	}
	key := strings.Join(partition, ", ")
	if len(partition) > 1 {
		key = "(" + key + ")"
	}
	if len(clustering) > 0 {
		key += ", " + strings.Join(clustering, ", ")
	}
	return "PRIMARY KEY (" + key + ")"
}
func schemaFingerprint(columns []tableColumn) string {
	var signature []string
	for _, column := range columns {
		signature = append(signature, column.name, column.nativeType, column.kind, column.order, strconv.Itoa(column.position), strconv.FormatBool(column.indexed))
	}
	data, _ := json.Marshal(signature)
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

type catalogObject struct{ keyspace, name, kind string }

func (s *Session) catalogObjects(ctx context.Context, command protocol.Command) ([]catalogObject, *protocol.Response) {
	request := command.Catalog
	schemas := []string{request.Schema}
	if request.Schema == "" {
		records, failure := s.metadata(ctx, command, "SELECT keyspace_name FROM system_schema.keyspaces")
		if failure != nil {
			return nil, failure
		}
		schemas = nil
		for _, record := range records {
			keyspace := record["keyspace_name"]
			if request.Kind == "completion" && strings.HasPrefix(keyspace, "system") {
				continue
			}
			schemas = append(schemas, keyspace)
		}
	}
	var objects []catalogObject
	bytes := 0
	for _, keyspace := range schemas {
		for _, object := range []struct{ table, column, kind string }{{"tables", "table_name", "table"}, {"views", "view_name", "view"}, {"types", "type_name", "type"}} {
			if request.Kind == "objects" && request.ObjectKind != object.kind {
				continue
			}
			records, failure := s.metadata(ctx, command, "SELECT "+object.column+" FROM system_schema."+object.table+" WHERE keyspace_name = ?", keyspace)
			if failure != nil {
				return nil, failure
			}
			for _, record := range records {
				name := record[object.column]
				if request.Kind == "search" && !strings.Contains(strings.ToLower(name), strings.ToLower(request.Search)) {
					continue
				}
				bytes += len(keyspace) + len(name) + len(object.kind) + 128
				if bytes > maxBytes || len(objects) >= 16384 {
					failure := s.failure(command, "result", "Cassandra catalog metadata exceeds the supported size. Restrict the request to one keyspace.")
					return nil, &failure
				}
				objects = append(objects, catalogObject{keyspace: keyspace, name: name, kind: object.kind})
			}
		}
	}
	sort.Slice(objects, func(i, j int) bool {
		if objects[i].keyspace != objects[j].keyspace {
			return objects[i].keyspace < objects[j].keyspace
		}
		if objects[i].name != objects[j].name {
			return objects[i].name < objects[j].name
		}
		return objects[i].kind < objects[j].kind
	})
	return objects, nil
}
func (s *Session) typeFields(ctx context.Context, command protocol.Command, keyspace, name string) ([]string, []string, *protocol.Response) {
	var fields, types []string
	query := ConfigureQuery(s.driver.Query("SELECT field_names, field_types FROM system_schema.types WHERE keyspace_name = ? AND type_name = ?", keyspace, name), s.keyspace)
	if err := query.ScanContext(ctx, &fields, &types); err != nil {
		failure := safeError(command, ctx, err, false, false)
		return nil, nil, &failure
	}
	if len(fields) != len(types) {
		failure := s.failure(command, "result", "Cassandra type metadata could not be decoded.")
		return nil, nil, &failure
	}
	return fields, types, nil
}
func (s *Session) typeDefinition(ctx context.Context, command protocol.Command, sink adapter.ResultSink) protocol.Response {
	fields, types, failure := s.typeFields(ctx, command, command.Catalog.Schema, command.Catalog.Object)
	if failure != nil {
		return *failure
	}
	var parts []string
	for i, field := range fields {
		parts = append(parts, "  "+quoteIdentifier(field)+" "+types[i])
	}
	definition := "CREATE TYPE " + qualified(command.Catalog.Schema, command.Catalog.Object) + " (\n" + strings.Join(parts, ",\n") + "\n);"
	return s.catalogResponse(command, stringsResult(command, []string{"name", "definition"}, [][]*string{cells(command.Catalog.Object, definition)}), sink)
}

// Table options (including default_time_to_live), indexes and grants are not
// reconstructed. The warning is included in copied text, not only UI chrome.
func tableDefinition(keyspace, table string, columns []tableColumn) string {
	definition := "-- Partial table definition: columns, primary key, and clustering order only.\n-- Table options (including default_time_to_live), indexes, and grants are omitted.\n-- This is not a complete schema recreation script.\nCREATE TABLE " + qualified(keyspace, table) + " (\n"
	var parts, order []string
	for _, column := range columns {
		text := "  " + quoteIdentifier(column.name) + " " + column.nativeType
		if column.kind == "static" {
			text += " STATIC"
		}
		parts = append(parts, text)
		if column.kind == "clustering" {
			direction := strings.ToUpper(column.order)
			if direction != "DESC" {
				direction = "ASC"
			}
			order = append(order, quoteIdentifier(column.name)+" "+direction)
		}
	}
	parts = append(parts, "  "+keyDefinition(columns))
	definition += strings.Join(parts, ",\n") + "\n)"
	if len(order) > 0 {
		definition += " WITH CLUSTERING ORDER BY (" + strings.Join(order, ", ") + ")"
	}
	return definition + ";"
}

func (s *Session) typeColumns(ctx context.Context, command protocol.Command, sink adapter.ResultSink) protocol.Response {
	fields, types, failure := s.typeFields(ctx, command, command.Catalog.Schema, command.Catalog.Object)
	if failure != nil {
		return *failure
	}
	rows := make([][]*string, 0, len(fields))
	for i, field := range fields {
		rows = append(rows, cells(field, types[i], strconv.Itoa(i+1), "true", "false", "Cassandra user-defined type fields are not editable in the grid."))
	}
	return s.catalogResponse(command, stringsResult(command, []string{"name", "nativeType", "position", "nullable", "editable", "editReason"}, rows), sink)
}
