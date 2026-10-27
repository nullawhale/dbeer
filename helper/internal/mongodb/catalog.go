package mongodb

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/mongoscript"
	"dbeer/helper/internal/protocol"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

func cells(values ...string) []*string {
	row := make([]*string, len(values))
	for i := range values {
		v := values[i]
		row[i] = &v
	}
	return row
}

func (s *Session) metadata(command protocol.Command, names []string, rows [][]*string, sink adapter.ResultSink, notice string) protocol.Response {
	known := false
	r := protocol.ResultSet{Rows: [][]*string{}, CommandTag: "CATALOG", AffectedRowCountKnown: &known, DisplayNotice: notice}
	for i, name := range names {
		r.Columns = append(r.Columns, protocol.Column{Index: i, Name: name, Engine: "mongodb", NativeType: "string"})
	}
	bytes := 0
	for _, row := range rows {
		encoded, _ := json.Marshal(row)
		if len(r.Rows) == 1000 || bytes+len(encoded) > maxResultBytes {
			r.Truncated = true
			break
		}
		bytes += len(encoded)
		r.Rows = append(r.Rows, row)
	}
	r.RowCount, r.DisplayedRowCount = int64(len(r.Rows)), len(r.Rows)
	if sink != nil {
		if err := sink.Begin(0, r.Columns); err != nil {
			return s.failure(command, "cancelled", "MongoDB catalog delivery stopped.")
		}
		for _, row := range r.Rows {
			if err := sink.Row(0, row); err != nil {
				return s.failure(command, "cancelled", "MongoDB catalog delivery stopped.")
			}
		}
		if err := sink.End(0, r); err != nil {
			return s.failure(command, "cancelled", "MongoDB catalog delivery stopped.")
		}
	}
	return resultResponse(command, r)
}

func (s *Session) catalog(ctx context.Context, command protocol.Command, sink adapter.ResultSink) protocol.Response {
	r := *command.Catalog
	if r.Kind == "browse" {
		return s.browse(ctx, command, sink)
	}
	var rows [][]*string
	switch r.Kind {
	case "schemas":
		names, err := s.client.ListDatabaseNames(ctx, bson.D{}, options.ListDatabases().SetAuthorizedDatabases(true))
		if err != nil {
			return safeError(command, ctx, err, false, nil)
		}
		sort.Strings(names)
		for _, name := range names {
			rows = append(rows, cells(name, "schema"))
		}
		return s.metadata(command, []string{"name", "kind"}, rows, sink, "")
	case "objects", "search", "completion":
		databases := []string{r.Schema}
		if r.Schema == "" {
			databases = []string{s.database}
			if s.database == "" {
				var err error
				databases, err = s.client.ListDatabaseNames(ctx, bson.D{}, options.ListDatabases().SetAuthorizedDatabases(true))
				if err != nil {
					return safeError(command, ctx, err, false, nil)
				}
			}
		}
		sort.Strings(databases)
		offset, seen, truncated := r.Page*200, 0, false
		for _, database := range databases {
			cursor, err := s.client.Database(database).ListCollections(ctx, bson.D{}, options.ListCollections().SetNameOnly(true).SetAuthorizedCollections(true).SetBatchSize(200))
			if err != nil {
				return safeError(command, ctx, err, false, nil)
			}
			for cursor.Next(ctx) {
				name, _ := cursor.Current.Lookup("name").StringValueOK()
				// Internal namespaces such as system.views are not user
				// collections. Sampling them can require separate privileges.
				if strings.HasPrefix(name, "system.") {
					continue
				}
				kind, _ := cursor.Current.Lookup("type").StringValueOK()
				if kind == "" {
					kind = "collection"
				}
				if r.Kind == "objects" && r.ObjectKind != "table" && r.ObjectKind != "view" {
					continue
				}
				if r.Kind == "objects" && (r.ObjectKind == "view") != (kind == "view") {
					continue
				}
				if r.Kind == "search" && !strings.Contains(strings.ToLower(name), strings.ToLower(r.Search)) {
					continue
				}
				if r.Kind == "completion" {
					seen++
					if seen <= offset {
						continue
					}
					if len(rows) == 200 {
						truncated = true
						break
					}
					fields, err := s.sampleFields(ctx, database, name)
					if err != nil {
						var server mongo.CommandError
						if !errors.As(err, &server) || server.Code != 13 {
							closeCursor(cursor)
							return safeError(command, ctx, err, false, nil)
						}
						// Listing permission does not imply document read access.
						// Preserve the authorized name without guessing its fields.
						fields = nil
					}
					names := make([]string, 0, len(fields))
					for name := range fields {
						names = append(names, name)
					}
					sort.Strings(names)
					encoded, _ := json.Marshal(names)
					rows = append(rows, cells(name, mapKind(kind), database, string(encoded), "[]", "[]"))
				} else {
					rows = append(rows, cells(name, mapKind(kind), database, ""))
					if len(rows) > 1000 {
						truncated = true
						break
					}
				}
			}
			err = cursor.Err()
			closeCursor(cursor)
			if err != nil {
				return safeError(command, ctx, err, false, nil)
			}
			if truncated {
				break
			}
		}
		names := []string{"name", "kind", "schema", "identity"}
		if r.Kind == "completion" {
			names = []string{"name", "kind", "schema", "columns", "foreignKeys", "signatures"}
		}
		response := s.metadata(command, names, rows, sink, "MongoDB field suggestions are sampled; collections may contain additional fields and types.")
		if truncated && r.Kind != "completion" {
			response.Truncated = true
			response.ResultSets[0].Truncated = true
		}
		return response
	case "columns":
		fields, err := s.sampleFields(ctx, r.Schema, r.Object)
		if err != nil {
			return safeError(command, ctx, err, false, nil)
		}
		names := make([]string, 0, len(fields))
		for name := range fields {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			types := make([]string, 0, len(fields[name]))
			for t := range fields[name] {
				types = append(types, t)
			}
			sort.Strings(types)
			rows = append(rows, cells(name, strings.Join(types, " | "), "sampled"))
		}
		return s.metadata(command, []string{"name", "nativeType", "evidence"}, rows, sink, "Types observed in at most 32 documents; this is not a schema or a required-field declaration.")
	case "indexes":
		cursor, err := s.client.Database(r.Schema).Collection(r.Object).Indexes().List(ctx)
		if err != nil {
			return safeError(command, ctx, err, false, nil)
		}
		defer closeCursor(cursor)
		for cursor.Next(ctx) {
			text, err := CanonicalDocument(cursor.Current)
			if err != nil {
				return safeError(command, ctx, err, false, nil)
			}
			rows = append(rows, cells(cursor.Current.Lookup("name").StringValue(), text))
			if len(rows) > 1000 {
				break
			}
		}
		if err := cursor.Err(); err != nil {
			return safeError(command, ctx, err, false, nil)
		}
		return s.metadata(command, []string{"name", "definition"}, rows, sink, "")
	case "select", "definition", "name":
		name := "definition"
		if r.Kind == "select" {
			name = "sql"
		}
		var text string
		if r.Kind == "name" {
			name = "name"
			encoded, _ := json.Marshal([]string{r.Schema, r.Object})
			text = string(encoded)
		} else {
			encoded, _ := json.Marshal(map[string]any{"database": r.Schema, "collection": r.Object, "find": map[string]any{}})
			text = string(encoded)
		}
		return s.metadata(command, []string{name}, [][]*string{cells(text)}, sink, "")
	default:
		return s.failure(command, "unsupported", "This catalog operation is not supported for MongoDB.")
	}
}

func mapKind(kind string) string {
	if kind == "view" {
		return "view"
	}
	return "table"
}

func (s *Session) sampleFields(ctx context.Context, database, collection string) (map[string]map[string]bool, error) {
	cursor, err := s.client.Database(database).Collection(collection).Find(ctx, bson.D{}, options.Find().SetLimit(32).SetBatchSize(32))
	if err != nil {
		return nil, err
	}
	defer closeCursor(cursor)
	fields := map[string]map[string]bool{}
	bytes := 0
	for cursor.Next(ctx) {
		bytes += len(cursor.Current)
		if bytes > 1<<20 {
			break
		}
		collectFields(cursor.Current, "", fields, 0)
	}
	return fields, cursor.Err()
}

func collectFields(raw bson.Raw, prefix string, fields map[string]map[string]bool, depth int) {
	if depth > 8 || len(fields) >= 512 {
		return
	}
	elements, err := raw.Elements()
	if err != nil {
		return
	}
	for _, e := range elements {
		if len(fields) >= 512 {
			return
		}
		name := prefix + e.Key()
		if !mongoscript.ValidName(name) {
			continue
		}
		if fields[name] == nil {
			fields[name] = map[string]bool{}
		}
		fields[name][e.Value().Type.String()] = true
		if nested, ok := e.Value().DocumentOK(); ok {
			collectFields(nested, name+".", fields, depth+1)
		}
	}
}
