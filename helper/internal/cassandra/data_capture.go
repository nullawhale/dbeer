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
	tc "dbeer/helper/internal/tablecapture"
)

// DescribeTable reads fresh system_schema rows instead of the driver's cached
// metadata. Only definitions reachable from the selected columns enter the
// digest, so an unrelated type change does not change a table's identity.
func (s *Session) DescribeTable(ctx context.Context, table tc.Table) (tc.Descriptor, error) {
	d := tc.Descriptor{Engine: "cassandra", Table: table, Columns: []tc.Column{}}
	if !table.Valid() {
		return d, tc.ErrInvalid
	}
	limits := sc.DefaultLimits()
	if err := s.driver.AwaitSchemaAgreement(ctx); err != nil {
		return d, err
	}
	_, before, err := s.schemaVersion(ctx, limits)
	if err != nil {
		return d, err
	}
	collector := sc.NewCollector(ctx, limits)
	r := &cassandraSchemaCapture{session: s, ctx: ctx, spec: sc.CaptureSpec{Schemas: []string{table.Schema}, Limits: limits}, sink: collector, types: map[sc.Ref]sc.TypeDefinition{}, issues: map[sc.Ref]bool{}}
	records, err := s.schemaRows(ctx, limits, "SELECT type_name,field_names,field_types FROM system_schema.types WHERE keyspace_name=?", table.Schema)
	if err != nil {
		return d, err
	}
	for _, record := range records {
		ref := sc.Ref{Kind: "type", Schema: table.Schema, Name: record["type_name"].text}
		definition, err := cassandraUDT(ref, record)
		if err != nil {
			return d, err
		}
		if err := r.addType(definition); err != nil {
			return d, err
		}
	}
	records, err = s.schemaRows(ctx, limits, "SELECT * FROM system_schema.tables WHERE keyspace_name=? AND table_name=?", table.Schema, table.Name)
	if err != nil {
		return d, err
	}
	kind := "table"
	if len(records) == 0 {
		records, err = s.schemaRows(ctx, limits, "SELECT * FROM system_schema.views WHERE keyspace_name=? AND view_name=?", table.Schema, table.Name)
		kind = "materializedView"
	}
	if err != nil {
		return d, err
	}
	if len(records) != 1 {
		return d, tc.ErrUnsupported
	}
	if err := r.table(sc.Ref{Kind: "table", Schema: table.Schema, Name: table.Name}, kind, records[0]); err != nil {
		return d, err
	}
	t := collector.Capture.Tables[0]
	definitions := make([]sc.TypeDefinition, 0, len(r.types))
	for _, definition := range r.types {
		definitions = append(definitions, definition)
	}
	primary := map[sc.Ref]int{}
	for _, constraint := range t.Constraints.Items {
		if constraint.Kind.Value != nil && *constraint.Kind.Value == "p" {
			for i, column := range constraint.Columns.Items {
				primary[column] = i + 1
			}
		}
	}
	reachable := map[sc.Ref]sc.TypeDefinition{}
	for i, column := range t.Columns.Items {
		if column.Type.Value == nil {
			return d, tc.ErrUnsupported
		}
		u := *column.Type.Value
		native, err := cassandraTypeIdentity(u, definitions)
		if err != nil {
			return d, err
		}
		var identity struct {
			Definitions []sc.TypeDefinition `json:"definitions"`
		}
		if err := json.Unmarshal([]byte(native), &identity); err != nil {
			return d, err
		}
		for _, definition := range identity.Definitions {
			reachable[definition.Ref] = definition
		}
		encoding := ""
		if u.Kind == "custom" || u.Kind == "builtin" && u.Ref.Name == "blob" {
			encoding = "base64"
		}
		definition, err := json.Marshal(column)
		if err != nil {
			return d, err
		}
		d.Columns = append(d.Columns, tc.Column{Index: i, Name: column.Ref.Name, NativeType: native, TypeLabel: cassandraDisplayType(u), Encoding: encoding, PrimaryKey: primary[column.Ref], Numeric: u.Kind == "builtin" && strings.Contains("|int|bigint|smallint|tinyint|counter|varint|decimal|float|double|", "|"+u.Ref.Name+"|"), Nullable: column.Nullable.Value != nil && *column.Nullable.Value, ValueComparison: cassandraValueComparison(u, identity.Definitions), Definition: definition})
	}
	selected := make([]sc.TypeDefinition, 0, len(reachable))
	for _, definition := range reachable {
		selected = append(selected, definition)
	}
	sort.Slice(selected, func(i, j int) bool {
		if selected[i].Ref.Schema != selected[j].Ref.Schema {
			return selected[i].Ref.Schema < selected[j].Ref.Schema
		}
		return selected[i].Ref.Name < selected[j].Ref.Name
	})
	d.Definition, err = json.Marshal(struct {
		Table sc.Table            `json:"table"`
		Types []sc.TypeDefinition `json:"types"`
	}{t, selected})
	if err != nil {
		return d, err
	}
	if err := s.driver.AwaitSchemaAgreement(ctx); err != nil {
		return d, err
	}
	_, after, err := s.schemaVersion(ctx, limits)
	if err != nil {
		return d, err
	}
	if before != after {
		return d, tc.ErrChanged
	}
	return d, d.Seal()
}

func cassandraValueComparison(u sc.TypeUse, definitions []sc.TypeDefinition) string {
	custom := false
	check := func(t sc.TypeUse) error { custom = custom || t.Kind == "custom"; return nil }
	_ = visitCassandraType(u, check)
	for _, definition := range definitions {
		for _, field := range definition.Attributes.Items {
			if field.Type.Value != nil {
				_ = visitCassandraType(*field.Type.Value, check)
			}
		}
	}
	if custom {
		return "unresolved"
	}
	return ""
}

func cassandraDisplayType(u sc.TypeUse) string {
	r := cassandraDefinition{w: &sc.DefinitionWriter{Context: context.Background()}}
	r.typ(u, 0)
	return r.w.Text.String()
}

func (s *Session) CaptureTable(ctx context.Context, spec tc.Spec, sink tc.Sink) (tc.Descriptor, tc.Outcome, error) {
	out := tc.Outcome{StartedAt: time.Now().UTC().Format(time.RFC3339Nano), ReadLimit: spec.ReadLimit, Consistency: "bestEffort", Rendering: "cassandraCQLv1", PartialReasons: []string{"nonSnapshot"}, Table: spec.Table, Engine: "cassandra"}
	d, err := s.DescribeTable(ctx, spec.Table)
	if err != nil {
		return d, out, err
	}
	if err := tc.Validate(d, spec); err != nil {
		return d, out, err
	}
	columns, failure := s.tableColumns(ctx, protocol.Command{}, spec.Table.Schema, spec.Table.Name)
	if failure != nil {
		return d, out, tc.ErrChanged
	}
	request := protocol.CatalogRequest{Kind: "browse", Schema: spec.Table.Schema, Object: spec.Table.Name}
	for _, filter := range spec.Filters {
		request.Filters = append(request.Filters, protocol.CatalogFilter{Column: filter.Column, Operator: filter.Operator, Value: filter.Value})
	}
	statement, args, err := browseStatement(request, columns)
	if err != nil {
		return d, out, tc.ErrUnsupported
	}
	var names []string
	for _, name := range spec.Columns {
		names = append(names, quoteIdentifier(name))
	}
	statement = strings.Replace(statement, "SELECT * FROM ", "SELECT "+strings.Join(names, ",")+" FROM ", 1) + " LIMIT " + strconv.Itoa(spec.ReadLimit+1)
	captureSink := &cassandraCaptureSink{spec: spec, sink: sink, out: &out}
	_, _, _, failure = s.query(ctx, protocol.Command{}, statement, args, 0, captureSink, &displayBudget{}, true, false, nil, 0, false)
	out.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano)
	if captureSink.err != nil {
		return d, out, captureSink.err
	}
	if failure != nil {
		if ctx.Err() != nil {
			return d, out, ctx.Err()
		}
		return d, out, tc.ErrUnsupported
	}
	fresh, err := s.DescribeTable(ctx, spec.Table)
	if err != nil {
		return d, out, err
	}
	if fresh.Digest != d.Digest {
		return d, out, tc.ErrChanged
	}
	out.DescriptorDigest = d.Digest
	return d, out, nil
}

type cassandraCaptureSink struct {
	spec tc.Spec
	sink tc.Sink
	out  *tc.Outcome
	err  error
}

func (s *cassandraCaptureSink) Begin(_ int, columns []protocol.Column) error {
	if len(columns) != len(s.spec.Columns) {
		s.err = tc.ErrChanged
		return s.err
	}
	for i, column := range columns {
		if column.Name != s.spec.Columns[i] {
			s.err = tc.ErrChanged
			return s.err
		}
	}
	return nil
}
func (s *cassandraCaptureSink) Row(_ int, row []*string) error {
	s.out.ObservedAtLeast++
	if len(row) != len(s.spec.Columns) {
		s.err = tc.ErrChanged
		return s.err
	}
	if s.out.StoredRows >= int64(s.spec.ReadLimit) {
		if len(s.out.PartialReasons) == 1 {
			s.out.PartialReasons = append(s.out.PartialReasons, "readLimit")
		}
		return nil
	}
	if err := s.sink.Row(row); err != nil {
		s.err = err
		return err
	}
	s.out.StoredRows++
	return nil
}
func (*cassandraCaptureSink) End(int, protocol.ResultSet) error { return nil }
