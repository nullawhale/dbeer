package cassandra

import (
	"context"
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"time"

	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

type schemaCell struct {
	text, literal string
	strings       []string
	values        map[string]string
}
type schemaRecord map[string]schemaCell

// Read catalog pages explicitly, with the same no-retry and cancellation
// policy as ordinary CQL. Literal rendering quotes server strings before a
// captured option can enter a definition preview.
func (s *Session) schemaRows(ctx context.Context, limits sc.Limits, sql string, args ...any) ([]schemaRecord, error) {
	var out []schemaRecord
	var page []byte
	bytes := 0
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		iter := ConfigureQuery(s.driver.Query(sql, args...), s.keyspace).NoSkipMetadata().PageSize(pageRows).PageState(page).IterContext(ctx)
		columns := iter.Columns()
		raw := make([]rawValue, len(columns))
		dest := make([]any, len(columns))
		for i := range raw {
			dest[i] = &raw[i]
		}
		for iter.Scan(dest...) {
			if len(out) >= limits.Members {
				_ = iter.Close()
				return nil, sc.ErrLimit
			}
			record := schemaRecord{}
			for i, v := range raw {
				if v.data == nil {
					continue
				}
				text, err := cqlValue(v.info, v.data, false, 0)
				if err != nil {
					_ = iter.Close()
					return nil, err
				}
				literal, err := cqlValue(v.info, v.data, true, 0)
				if err != nil {
					_ = iter.Close()
					return nil, err
				}
				cell := schemaCell{text: text, literal: literal}
				if collection, ok := v.info.(gocql.CollectionType); ok {
					if collection.Type() == gocql.TypeList && (collection.Elem.Type() == gocql.TypeText || collection.Elem.Type() == gocql.TypeVarchar) {
						if gocql.Unmarshal(v.info, v.data, &cell.strings) != nil {
							_ = iter.Close()
							return nil, sc.ErrInvalid
						}
					}
					if collection.Type() == gocql.TypeMap && (collection.Key.Type() == gocql.TypeText || collection.Key.Type() == gocql.TypeVarchar) && (collection.Elem.Type() == gocql.TypeText || collection.Elem.Type() == gocql.TypeVarchar) {
						if gocql.Unmarshal(v.info, v.data, &cell.values) != nil {
							_ = iter.Close()
							return nil, sc.ErrInvalid
						}
					}
				}
				bytes += len(text) + len(literal)
				if len(text) > limits.Scalar || len(literal) > limits.Scalar || bytes > limits.Bytes {
					_ = iter.Close()
					return nil, sc.ErrLimit
				}
				record[columns[i].Name] = cell
			}
			out = append(out, record)
		}
		next := append([]byte(nil), iter.PageState()...)
		if err := iter.Close(); err != nil {
			return nil, err
		}
		if len(next) == 0 {
			return out, nil
		}
		page = next
	}
}

type cassandraSchemaCapture struct {
	session                *Session
	ctx                    context.Context
	spec                   sc.CaptureSpec
	sink                   sc.Sink
	types                  map[sc.Ref]sc.TypeDefinition
	issues                 map[sc.Ref]bool
	typeBytes, typeMembers int
}

func (s *Session) schemaVersion(ctx context.Context, limits sc.Limits) (version, schema string, err error) {
	rows, err := s.schemaRows(ctx, limits, "SELECT release_version,schema_version FROM system.local")
	if err != nil || len(rows) != 1 {
		if err == nil {
			err = sc.ErrInvalid
		}
		return "", "", err
	}
	return rows[0]["release_version"].text, rows[0]["schema_version"].text, nil
}

// Cassandra has no catalog transaction. Agreement checks and a schema-version
// fence detect changes; the context still discloses the best-effort read.
func (s *Session) ReadSchema(ctx context.Context, spec sc.CaptureSpec, sink sc.Sink) error {
	if len(spec.Schemas) == 0 || len(spec.Schemas) > 32 {
		return sc.ErrInvalid
	}
	for _, schema := range spec.Schemas {
		if !sc.ValidName(schema) {
			return sc.ErrInvalid
		}
	}
	if err := s.driver.AwaitSchemaAgreement(ctx); err != nil {
		return err
	}
	version, before, err := s.schemaVersion(ctx, spec.Limits)
	if err != nil {
		return err
	}
	capture := sc.CaptureContext{Engine: "cassandra", Version: version, Database: s.keyspace, StartedAt: time.Now().UTC().Format(time.RFC3339Nano), Consistency: "bestEffort", Visibility: "complete", EngineContext: sc.Known([]sc.Option{})}
	r := &cassandraSchemaCapture{session: s, ctx: ctx, spec: spec, sink: sink, types: map[sc.Ref]sc.TypeDefinition{}, issues: map[sc.Ref]bool{}}
	for schemaIndex, schema := range spec.Schemas {
		keyspaces, err := s.schemaRows(ctx, spec.Limits, "SELECT keyspace_name,durable_writes,replication FROM system_schema.keyspaces WHERE keyspace_name=?", schema)
		if err != nil {
			return err
		}
		inv := sc.Inventory{Schema: schema, Existence: "absent", Tables: sc.Complete[sc.Ref](nil), Types: sc.Complete[sc.Ref](nil)}
		if len(keyspaces) == 0 {
			if err := sink.Inventory(inv); err != nil {
				return err
			}
			continue
		}
		inv.Existence = "present"
		// Both captures receive schemas in mapping order, so use that ordinal
		// for keyspace settings rather than an unmappable identifier string.
		for _, name := range []string{"durable_writes", "replication"} {
			*capture.EngineContext.Value = append(*capture.EngineContext.Value, sc.Option{Name: "schema[" + strconv.Itoa(schemaIndex) + "]." + name, Value: keyspaces[0][name].literal})
		}
		types, err := s.schemaRows(ctx, spec.Limits, "SELECT type_name,field_names,field_types FROM system_schema.types WHERE keyspace_name=?", schema)
		if err != nil {
			return err
		}
		sort.Slice(types, func(i, j int) bool { return types[i]["type_name"].text < types[j]["type_name"].text })
		for _, record := range types {
			ref := sc.Ref{Kind: "type", Schema: schema, Name: record["type_name"].text}
			d, err := cassandraUDT(ref, record)
			if err != nil {
				return err
			}
			if err := r.addType(d); err != nil {
				return err
			}
			inv.Types.Items = append(inv.Types.Items, ref)
		}
		for _, ref := range inv.Types.Items {
			d := r.types[ref]
			for _, field := range d.Attributes.Items {
				if err := r.checkType(*field.Type.Value); err != nil {
					return err
				}
			}
			if err := sink.Type(d); err != nil {
				return err
			}
		}
		for _, object := range []struct{ system, field, kind string }{{"tables", "table_name", "table"}, {"views", "view_name", "materializedView"}} {
			records, err := s.schemaRows(ctx, spec.Limits, "SELECT * FROM system_schema."+object.system+" WHERE keyspace_name=?", schema)
			if err != nil {
				return err
			}
			sort.Slice(records, func(i, j int) bool { return records[i][object.field].text < records[j][object.field].text })
			for _, record := range records {
				ref := sc.Ref{Kind: "table", Schema: schema, Name: record[object.field].text}
				inv.Tables.Items = append(inv.Tables.Items, ref)
				if err := r.table(ref, object.kind, record); err != nil {
					return err
				}
			}
		}
		if err := sink.Inventory(inv); err != nil {
			return err
		}
	}
	if err := s.driver.AwaitSchemaAgreement(ctx); err != nil {
		return err
	}
	_, after, err := s.schemaVersion(ctx, spec.Limits)
	if err != nil {
		return err
	}
	if before != after {
		return sc.ErrInvalid
	}
	capture.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano)
	return sink.Context(capture)
}

func (r *cassandraSchemaCapture) addType(d sc.TypeDefinition) error {
	if len(r.types) >= r.spec.Limits.Nodes {
		return sc.ErrLimit
	}
	encoded, err := json.Marshal(d)
	if err != nil {
		return err
	}
	r.typeBytes += len(encoded)
	r.typeMembers += len(d.Attributes.Items)
	if r.typeBytes > r.spec.Limits.Bytes || r.typeMembers > r.spec.Limits.Members {
		return sc.ErrLimit
	}
	r.types[d.Ref] = d
	return nil
}

func cassandraUDT(ref sc.Ref, record schemaRecord) (sc.TypeDefinition, error) {
	d := sc.TypeDefinition{Ref: ref, Kind: sc.Known("udt"), Labels: sc.Complete[string](nil), Base: sc.Absent[sc.TypeUse](), Default: sc.Known(sc.Default{Kind: "none"}), Nullable: sc.Known(true), Checks: sc.Complete[sc.Constraint](nil), Attributes: sc.Complete[sc.Column](nil)}
	fields, native := record["field_names"].strings, record["field_types"].strings
	if len(fields) == 0 || len(fields) != len(native) {
		return d, sc.ErrInvalid
	}
	seen := map[string]bool{}
	for i, field := range fields {
		if !sc.ValidName(field) || seen[field] {
			return d, sc.ErrInvalid
		}
		seen[field] = true
		u, err := cassandraType(native[i], ref.Schema)
		if err != nil {
			return d, err
		}
		d.Attributes.Items = append(d.Attributes.Items, cassandraColumn(ref, field, i, u, true))
	}
	return d, nil
}

func cassandraColumn(parent sc.Ref, name string, ordinal int, u sc.TypeUse, nullable bool) sc.Column {
	return sc.Column{Ref: sc.Ref{Kind: "column", Schema: parent.Schema, Table: parent.Name, Name: name}, Ordinal: sc.Known(ordinal + 1), Type: sc.Known(u), Nullable: sc.Known(nullable), Default: sc.Known(sc.Default{Kind: "none"}), Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(true), Comment: sc.Absent[string](), OnUpdate: sc.Absent[sc.Expression]()}
}

func (r *cassandraSchemaCapture) checkType(u sc.TypeUse) error {
	return visitCassandraType(u, func(t sc.TypeUse) error {
		if t.Kind == "udt" && !r.issues[t.Ref] {
			if _, present := r.types[t.Ref]; !present {
				r.issues[t.Ref] = true
				return r.sink.Issue(sc.Issue{Ref: &t.Ref, Property: "type", Code: "missingTypeDefinition", Message: "A referenced Cassandra user-defined type is unavailable in the captured catalog.", BlocksEquality: true, Planning: "manual"})
			}
		}
		if t.Kind == "custom" && !r.issues[t.Ref] {
			r.issues[t.Ref] = true
			return r.sink.Issue(sc.Issue{Ref: &t.Ref, Property: "type", Code: "customTypeBehavior", Message: "The custom Java type class and binary values are captured; server-side class implementation equivalence requires manual review.", BlocksEquality: true, Planning: "manual"})
		}
		return nil
	})
}

func (r *cassandraSchemaCapture) table(ref sc.Ref, kind string, record schemaRecord) error {
	t := sc.Table{Ref: ref, Kind: sc.Known(kind), Storage: sc.Known("cassandra"), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Options: sc.Complete[sc.Option](nil), Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}
	names := make([]string, 0, len(record))
	for name := range record {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		switch name {
		case "keyspace_name", "table_name", "view_name", "id", "base_table_id", "base_table_name", "where_clause":
			continue
		}
		t.Options.Items = append(t.Options.Items, sc.Option{Name: name, Value: record[name].literal})
	}
	if kind == "materializedView" {
		t.Dependencies.Items = append(t.Dependencies.Items, sc.Dependency{From: ref, To: sc.Ref{Kind: "table", Schema: ref.Schema, Name: record["base_table_name"].text}, Kind: "materializedView", State: "known"})
	}
	columns, failure := r.session.tableColumns(r.ctx, protocol.Command{}, ref.Schema, ref.Name)
	if failure != nil {
		return sc.ErrInvalid
	}
	if len(columns) == 0 {
		return sc.ErrInvalid
	}
	partition := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: ref.Schema, Table: ref.Name, Name: "PARTITION KEY"}, "partitionKey")
	primary := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: ref.Schema, Table: ref.Name, Name: "PRIMARY KEY"}, "p")
	static := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: ref.Schema, Table: ref.Name, Name: "STATIC COLUMNS"}, "staticColumns")
	clustering := sc.Index{Ref: sc.Ref{Kind: "clusteringOrder", Schema: ref.Schema, Table: ref.Name, Name: "CLUSTERING ORDER"}, Method: sc.Known("clustering"), Unique: sc.Known(false), NullsDistinct: sc.Absent[bool](), Keys: sc.Complete[sc.IndexKey](nil), Includes: sc.Complete[sc.Ref](nil), Predicate: sc.Absent[sc.Expression](), Options: sc.Complete[sc.Option](nil), Visible: sc.Known(true), Valid: sc.Known(true), Ready: sc.Known(true), Constraint: sc.Known(primary.Ref)}
	for i, column := range columns {
		u, err := cassandraType(column.nativeType, ref.Schema)
		if err != nil {
			return err
		}
		if err := r.checkType(u); err != nil {
			return err
		}
		c := cassandraColumn(ref, column.name, i, u, column.kind != "partition_key" && column.kind != "clustering")
		t.Columns.Items = append(t.Columns.Items, c)
		switch column.kind {
		case "partition_key":
			partition.Columns.Items = append(partition.Columns.Items, c.Ref)
			primary.Columns.Items = append(primary.Columns.Items, c.Ref)
		case "clustering":
			primary.Columns.Items = append(primary.Columns.Items, c.Ref)
			clustering.Keys.Items = append(clustering.Keys.Items, sc.IndexKey{Column: sc.Known(c.Ref), Expression: sc.Absent[sc.Expression](), Opclass: sc.Absent[sc.Ref](), Collation: sc.Absent[sc.Ref](), Descending: sc.Known(column.order == "desc"), NullsFirst: sc.Absent[bool](), PrefixLength: sc.Absent[int64](), Options: sc.Complete[sc.Option](nil)})
		case "static":
			static.Columns.Items = append(static.Columns.Items, c.Ref)
		}
	}
	t.Constraints.Items = append(t.Constraints.Items, primary, partition, static)
	if kind == "materializedView" {
		predicate := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: ref.Schema, Table: ref.Name, Name: "VIEW PREDICATE"}, "viewPredicate")
		expression := cassandraViewExpression(record["where_clause"].text, ref, t.Columns.Items)
		predicate.Check = sc.Known(expression)
		t.Constraints.Items = append(t.Constraints.Items, predicate)
		if !expression.Dependencies.Complete {
			if err := r.sink.Issue(sc.Issue{Ref: &ref, Property: "predicate", Code: "viewPredicateDependencies", Message: "Materialized-view predicate dependencies could not be resolved completely; identifier mapping requires manual review.", BlocksEquality: true, Planning: "manual"}); err != nil {
				return err
			}
		}
	}
	if len(clustering.Keys.Items) > 0 {
		t.Indexes.Items = append(t.Indexes.Items, clustering)
	}
	indexes, err := r.session.schemaRows(r.ctx, r.spec.Limits, "SELECT index_name,kind,options FROM system_schema.indexes WHERE keyspace_name=? AND table_name=?", ref.Schema, ref.Name)
	if err != nil {
		return err
	}
	sort.Slice(indexes, func(i, j int) bool { return indexes[i]["index_name"].text < indexes[j]["index_name"].text })
	for _, index := range indexes {
		i := sc.Index{Ref: sc.Ref{Kind: "index", Schema: ref.Schema, Table: ref.Name, Name: index["index_name"].text}, Method: sc.Known(index["kind"].text), Unique: sc.Known(false), NullsDistinct: sc.Absent[bool](), Keys: sc.Complete[sc.IndexKey](nil), Includes: sc.Complete[sc.Ref](nil), Predicate: sc.Absent[sc.Expression](), Options: sc.Complete[sc.Option](nil), Visible: sc.Known(true), Valid: sc.Known(true), Ready: sc.Known(true), Constraint: sc.Absent[sc.Ref]()}
		options := index["options"].values
		column, targetKind, err := cassandraIndexTarget(options["target"])
		if err != nil {
			return err
		}
		i.Keys.Items = append(i.Keys.Items, sc.IndexKey{Column: sc.Known(sc.Ref{Kind: "column", Schema: ref.Schema, Table: ref.Name, Name: column}), Expression: sc.Absent[sc.Expression](), Opclass: sc.Absent[sc.Ref](), Collation: sc.Absent[sc.Ref](), Descending: sc.Known(false), NullsFirst: sc.Absent[bool](), PrefixLength: sc.Absent[int64](), Options: sc.Complete([]sc.Option{{Name: "targetKind", Value: targetKind}})})
		var names []string
		for name := range options {
			if name != "target" {
				names = append(names, name)
			}
		}
		sort.Strings(names)
		for _, name := range names {
			i.Options.Items = append(i.Options.Items, sc.Option{Name: name, Value: options[name]})
		}
		t.Indexes.Items = append(t.Indexes.Items, i)
	}
	return r.sink.Table(t)
}

func cassandraIndexTarget(target string) (column, kind string, err error) {
	p := cqlTypeParser{text: strings.TrimSpace(target)}
	name, quoted, err := p.name('"')
	if err != nil {
		return "", "", err
	}
	if !quoted && p.token('(') {
		if name != "keys" && name != "values" && name != "entries" && name != "full" {
			return "", "", sc.ErrInvalid
		}
		kind = name
		name, _, err = p.name('"')
		if err != nil || !p.token(')') {
			return "", "", sc.ErrInvalid
		}
	}
	p.space()
	if p.offset != len(p.text) || !sc.ValidName(name) {
		return "", "", sc.ErrInvalid
	}
	return name, kind, nil
}

// Ensure options retain their captured literal spelling while identities and
// ordinals remain typed. These helpers are shared by data descriptors.
func cassandraTypeIdentity(u sc.TypeUse, definitions []sc.TypeDefinition) (string, error) {
	return structuralCassandraType(u, definitions)
}

func structuralCassandraType(u sc.TypeUse, definitions []sc.TypeDefinition) (string, error) {
	refs := map[sc.Ref]bool{}
	byRef := map[sc.Ref]sc.TypeDefinition{}
	for _, d := range definitions {
		byRef[d.Ref] = d
	}
	var visit func(sc.TypeUse) error
	visit = func(t sc.TypeUse) error {
		return visitCassandraType(t, func(child sc.TypeUse) error {
			if child.Kind != "udt" || refs[child.Ref] {
				return nil
			}
			refs[child.Ref] = true
			d, ok := byRef[child.Ref]
			if !ok {
				return sc.ErrInvalid
			}
			for _, field := range d.Attributes.Items {
				if field.Type.Value == nil {
					return sc.ErrInvalid
				}
				if err := visit(*field.Type.Value); err != nil {
					return err
				}
			}
			return nil
		})
	}
	if err := visit(u); err != nil {
		return "", err
	}
	selected := []sc.TypeDefinition{}
	for _, d := range definitions {
		if refs[d.Ref] {
			selected = append(selected, d)
		}
	}
	sort.Slice(selected, func(i, j int) bool {
		if selected[i].Ref.Schema != selected[j].Ref.Schema {
			return selected[i].Ref.Schema < selected[j].Ref.Schema
		}
		return selected[i].Ref.Name < selected[j].Ref.Name
	})
	b, err := json.Marshal(struct {
		Type        sc.TypeUse          `json:"type"`
		Definitions []sc.TypeDefinition `json:"definitions"`
	}{u, selected})
	return string(b), err
}
