package cassandra

import (
	"context"
	"errors"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	tc "dbeer/helper/internal/tablecapture"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

func TestCassandraCatalogTypesRetainEveryArgumentAndModifier(t *testing.T) {
	for _, name := range strings.Fields("ascii bigint blob boolean counter date decimal double duration float inet int smallint text time timestamp timeuuid tinyint uuid varint") {
		u, err := cassandraType(name, "ks")
		if err != nil || u.Kind != "builtin" || cassandraDisplayType(u) != name {
			t.Fatalf("builtin %s unavailable", name)
		}
	}
	for input, want := range map[string]string{
		"VARCHAR": "text",
		`frozen<map<text, tuple<int, frozen<"A"."Ty""pe">, vector<float, 3>>>>`: `frozen<map<text, tuple<int, frozen<"A"."Ty""pe">, vector<float, 3>>>>`,
		`map<tuple<int, text>, frozen<list<set<uuid>>>>`:                        `map<tuple<int, text>, frozen<list<set<uuid>>>>`,
		`"a.b"`:              `"ks"."a.b"`,
		`'com.example.Type'`: `'com.example.Type'`,
	} {
		u, err := cassandraType(input, "ks")
		if err != nil {
			t.Fatalf("type %s: %v", input, err)
		}
		if got := cassandraDisplayType(u); got != want {
			t.Fatalf("type %s became %s, want %s", input, got, want)
		}
		roundtrip, err := cassandraType(cassandraDisplayType(u), "ks")
		if err != nil || cassandraDisplayType(roundtrip) != want {
			t.Fatalf("type %s did not roundtrip", input)
		}
	}
	for _, input := range []string{"", "map<int>", "map<int,text,uuid>", "tuple<>", "list<int", "vector<float,0>", "vector<float,65536>", "vector<float,3.0>", "int; DROP TABLE t", `"unterminated`, "frozen<" + strings.Repeat("list<", 65) + "int" + strings.Repeat(">", 66)} {
		if _, err := cassandraType(input, "ks"); err == nil {
			t.Fatalf("invalid type accepted: %q", input)
		}
	}
}

func TestCassandraTypeIdentitiesIncludeNestedUDTDefinitionsAndArgumentOrder(t *testing.T) {
	ref := sc.Ref{Kind: "type", Schema: "ks", Name: "entry"}
	makeDefinition := func(native string) sc.TypeDefinition {
		d, err := cassandraUDT(ref, schemaRecord{"field_names": {strings: []string{"field"}}, "field_types": {strings: []string{native}}})
		if err != nil {
			t.Fatal(err)
		}
		return d
	}
	u, _ := cassandraType("frozen<map<text, frozen<entry>>>", "ks")
	a, err := cassandraTypeIdentity(u, []sc.TypeDefinition{makeDefinition("int")})
	if err != nil {
		t.Fatal(err)
	}
	b, err := cassandraTypeIdentity(u, []sc.TypeDefinition{makeDefinition("bigint")})
	if err != nil || a == b {
		t.Fatal("nested UDT field change lost from identity")
	}
	if _, err := cassandraTypeIdentity(u, nil); err == nil {
		t.Fatal("missing UDT definition accepted")
	}
	first, _ := cassandraType("tuple<int,text,int>", "ks")
	second, _ := cassandraType("tuple<int,int,text>", "ks")
	a, _ = cassandraTypeIdentity(first, nil)
	b, _ = cassandraTypeIdentity(second, nil)
	if a == b {
		t.Fatal("tuple argument order lost")
	}
}

func TestCassandraOpaqueValueComparisonPropagatesThroughUDTAndCollections(t *testing.T) {
	ref := sc.Ref{Kind: "type", Schema: "ks", Name: "entry"}
	d, err := cassandraUDT(ref, schemaRecord{"field_names": {strings: []string{"opaque"}}, "field_types": {strings: []string{"'com.example.CustomType'"}}})
	if err != nil {
		t.Fatal(err)
	}
	u, err := cassandraType("frozen<tuple<int,map<text,frozen<entry>>>>", "ks")
	if err != nil || cassandraValueComparison(u, []sc.TypeDefinition{d}) != "unresolved" {
		t.Fatal("custom UDT field was represented as semantically known")
	}
	builtin, _ := cassandraType("map<text,vector<float,3>>", "ks")
	if cassandraValueComparison(builtin, nil) != "" {
		t.Fatal("native composite value comparison unnecessarily blocked")
	}
}

func TestCassandraCatalogTypeGraphHonorsCaptureBounds(t *testing.T) {
	r := &cassandraSchemaCapture{spec: sc.CaptureSpec{Limits: sc.Limits{Nodes: 1, Members: 1, Bytes: 10000, Scalar: 1000}}, types: map[sc.Ref]sc.TypeDefinition{}}
	ref := sc.Ref{Kind: "type", Schema: "ks", Name: "entry"}
	d, err := cassandraUDT(ref, schemaRecord{"field_names": {strings: []string{"field"}}, "field_types": {strings: []string{"int"}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := r.addType(d); err != nil {
		t.Fatal(err)
	}
	d.Ref.Name = "next"
	if err := r.addType(d); !errors.Is(err, sc.ErrLimit) {
		t.Fatal("type graph exceeded capture node bound")
	}
	r.types = map[sc.Ref]sc.TypeDefinition{}
	r.typeBytes = 0
	r.typeMembers = 0
	r.spec.Limits.Bytes = 1
	if err := r.addType(d); !errors.Is(err, sc.ErrLimit) {
		t.Fatal("type graph exceeded capture byte bound")
	}
}

func TestCassandraIndexTargetsKeepIdentifiersTyped(t *testing.T) {
	for input, want := range map[string][2]string{`col`: {"col", ""}, `keys("a.b")`: {"a.b", "keys"}, `entries("a""b")`: {`a"b`, "entries"}, `FULL ( "col" )`: {"col", "full"}} {
		name, kind, err := cassandraIndexTarget(input)
		if err != nil || name != want[0] || kind != want[1] {
			t.Fatalf("target %s: %s/%s %v", input, name, kind, err)
		}
	}
	for _, input := range []string{"", "x) ON other", "function(x)", "keys(x,y)", "keys(x);"} {
		if _, _, err := cassandraIndexTarget(input); err == nil {
			t.Fatal("invalid target accepted")
		}
	}
}

func TestCassandraCustomTypesPreserveOpaqueBytesAndClassIdentity(t *testing.T) {
	info := opaqueCQLType("com.example.CustomType")
	value, err := renderValue(info, []byte{0, 255, 1}, false)
	if err != nil || value == nil || *value != "AP8B" || !binaryCQLType(info) {
		t.Fatal("custom bytes were not preserved")
	}
	if typeName(info) != "'com.example.CustomType'" {
		t.Fatal("custom type identity lost")
	}
	nested, err := cqlValue(info, []byte{}, true, 0)
	if err != nil || nested != "0x" {
		t.Fatal("empty custom value lost")
	}
	if binaryCQLType(gocql.VectorType{SubType: native(gocql.TypeFloat), Dimensions: 3}) {
		t.Fatal("vector misclassified as binary custom type")
	}
}

func TestCassandraResultIdentityIncludesUDTFieldsInsideCollections(t *testing.T) {
	first := gocql.UDTTypeInfo{Keyspace: "ks", Name: "same_name", Elements: []gocql.UDTField{{Name: "field", Type: native(gocql.TypeInt)}}}
	second := first
	second.Elements = []gocql.UDTField{{Name: "field", Type: native(gocql.TypeBigInt)}}
	a := gocql.NewNativeType(5, gocql.TypeCustom, "list<text>").(gocql.CollectionType)
	a.Elem = first
	b := a
	b.Elem = second
	if cassandraResultTypeIdentity(a) == cassandraResultTypeIdentity(b) {
		t.Fatal("same-name UDT field change was hidden in result metadata")
	}
	first.Elements[0].Type = opaqueCQLType("com.example.Type")
	if !strings.HasPrefix(cassandraResultTypeIdentity(first), "unresolved:") {
		t.Fatal("custom Java behavior was represented as known")
	}
}

func TestCassandraCustomWireResolverPreservesAliasIdentityAndVectorCodec(t *testing.T) {
	config, err := NewClusterConfig(protocol.Connection{Engine: "cassandra", Host: "localhost", Port: 9042, Database: "ks", SSLMode: "disable"})
	if err != nil || config.CustomWireTypeResolver == nil {
		t.Fatal("custom wire resolver not scoped to connection config")
	}
	info, err := config.CustomWireTypeResolver(5, "org.apache.cassandra.db.marshal.LexicalUUIDType", native(gocql.TypeUUID), nil)
	if err != nil || info.Type() != gocql.TypeCustom || typeName(info) != "'org.apache.cassandra.db.marshal.LexicalUUIDType'" || !strings.HasPrefix(cassandraResultTypeIdentity(info), "unresolved:") {
		t.Fatal("legacy alias erased custom class identity")
	}
	for _, data := range [][]byte{nil, {}, {0, 255, 1}} {
		var raw rawValue
		if err := gocql.Unmarshal(info, data, &raw); err != nil || (raw.data == nil) != (data == nil) || string(raw.data) != string(data) {
			t.Fatal("opaque wire bytes changed")
		}
	}
	vector := gocql.VectorType{SubType: native(gocql.TypeFloat), Dimensions: 3}
	resolved, err := config.CustomWireTypeResolver(5, "org.apache.cassandra.db.marshal.VectorType(FloatType,3)", vector, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := resolved.(gocql.VectorType); !ok || binaryCQLType(resolved) {
		t.Fatal("vector decoder replaced by opaque custom codec")
	}
	aliasVector := gocql.VectorType{SubType: native(gocql.TypeUUID), Dimensions: 2}
	first, _ := config.CustomWireTypeResolver(5, "org.apache.cassandra.db.marshal.VectorType(UUIDType,2)", aliasVector, nil)
	second, _ := config.CustomWireTypeResolver(5, "org.apache.cassandra.db.marshal.VectorType(LexicalUUIDType,2)", aliasVector, nil)
	if cassandraResultTypeIdentity(first) == cassandraResultTypeIdentity(second) {
		t.Fatal("legacy alias inside vector erased from result type identity")
	}
}

type tableCaptureRows struct {
	rows [][]*string
	err  error
}

func (s *tableCaptureRows) Row(row []*string) error {
	if s.err != nil {
		return s.err
	}
	s.rows = append(s.rows, row)
	return nil
}

func TestCassandraCaptureLimitsAndSinkErrorsRetainPartialEvidence(t *testing.T) {
	rows := &tableCaptureRows{}
	out := tc.Outcome{PartialReasons: []string{"nonSnapshot"}}
	s := &cassandraCaptureSink{spec: tc.Spec{Columns: []string{"id"}, ReadLimit: 1}, sink: rows, out: &out}
	if err := s.Begin(0, []protocol.Column{{Name: "id"}}); err != nil {
		t.Fatal(err)
	}
	if err := s.Row(0, cells("1")); err != nil {
		t.Fatal(err)
	}
	if err := s.Row(0, cells("2")); err != nil {
		t.Fatal(err)
	}
	if len(rows.rows) != 1 || out.StoredRows != 1 || out.ObservedAtLeast != 2 || strings.Join(out.PartialReasons, ",") != "nonSnapshot,readLimit" {
		t.Fatal("capture limit or consistency disclosure lost")
	}
	rows.err = errors.New("quota")
	s.out.StoredRows = 0
	if err := s.Row(0, cells("3")); !errors.Is(err, rows.err) || !errors.Is(s.err, rows.err) {
		t.Fatal("sink quota failure lost")
	}
	if err := s.Begin(0, []protocol.Column{{Name: "changed"}}); !errors.Is(err, tc.ErrChanged) {
		t.Fatal("changed response columns accepted")
	}
}

func TestCassandraTypedMappingsReachNestedTypesAndStaticMembership(t *testing.T) {
	makeCapture := func(schema, table, key, static string) sc.Capture {
		parent := sc.Ref{Kind: "table", Schema: schema, Name: table}
		u, _ := cassandraType("int", schema)
		typ, _ := cassandraType(`frozen<tuple<int, map<text, frozen<entry>>>>`, schema)
		c := sc.Table{Ref: parent, Kind: sc.Known("table"), Storage: sc.Known("cassandra"), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Options: sc.Complete[sc.Option](nil), Columns: sc.Complete([]sc.Column{cassandraColumn(parent, key, 0, u, false), cassandraColumn(parent, static, 1, typ, true)}), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}
		for _, pair := range []struct {
			name, kind string
			columns    []sc.Ref
		}{{"PRIMARY KEY", "p", []sc.Ref{c.Columns.Items[0].Ref}}, {"PARTITION KEY", "partitionKey", []sc.Ref{c.Columns.Items[0].Ref}}, {"STATIC COLUMNS", "staticColumns", []sc.Ref{c.Columns.Items[1].Ref}}} {
			constraint := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: schema, Table: table, Name: pair.name}, pair.kind)
			constraint.Columns = sc.Complete(pair.columns)
			c.Constraints.Items = append(c.Constraints.Items, constraint)
		}
		return sc.Capture{Context: sc.CaptureContext{Engine: "cassandra", Consistency: "bestEffort", Visibility: "complete", EngineContext: sc.Known([]sc.Option{})}, Inventories: []sc.Inventory{{Schema: schema, Existence: "present", Tables: sc.Complete([]sc.Ref{parent}), Types: sc.Complete[sc.Ref](nil)}}, Tables: []sc.Table{c}}
	}
	a, b := makeCapture("source", "original", "id", "value"), makeCapture("target", "renamed", "key", "payload")
	m := sc.Mappings{Schemas: []sc.NamePair{{Source: "source", Target: "target"}}, Tables: []sc.TablePair{{Source: sc.QualifiedName{Schema: "source", Name: "original"}, Target: sc.QualifiedName{Schema: "target", Name: "renamed"}, Columns: []sc.NamePair{{Source: "id", Target: "key"}, {Source: "value", Target: "payload"}}, Constraints: []sc.NamePair{}, Indexes: []sc.NamePair{}}}, Types: []sc.ObjectPair{}}
	r, err := sc.Build(context.Background(), t.TempDir(), a, b, m)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if !r.Report.Summary.FullEquality {
		t.Fatal("typed mappings left false Cassandra differences")
	}
	definition, err := RenderSchemaDefinition(context.Background(), a, a.Tables[0].Ref)
	if err != nil || definition.Limited || !strings.Contains(definition.SQL, `"value" frozen<tuple<int, map<text, frozen<"source"."entry">>>> STATIC`) {
		t.Fatalf("CQL lost nested type/static membership: %s", definition.SQL)
	}
}

func TestCassandraViewPredicatesResolveDependenciesAndDiscloseUnmappedText(t *testing.T) {
	ref := sc.Ref{Kind: "table", Schema: "ks", Name: "view"}
	u, _ := cassandraType("int", "ks")
	column := cassandraColumn(ref, "id", 0, u, false)
	expression := cassandraViewExpression(`"id" IS NOT NULL AND "id" > 0`, ref, []sc.Column{column})
	if !expression.Dependencies.Complete || len(expression.Dependencies.Items) != 1 || expression.Dependencies.Items[0] != column.Ref {
		t.Fatal("view column dependencies lost")
	}
	if cassandraViewExpression(`unknown(id) > 0`, ref, []sc.Column{column}).Dependencies.Complete {
		t.Fatal("unresolved view expression represented as complete")
	}
	primary := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: "ks", Table: "view", Name: "PRIMARY KEY"}, "p")
	primary.Columns = sc.Complete([]sc.Ref{column.Ref})
	partition := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: "ks", Table: "view", Name: "PARTITION KEY"}, "partitionKey")
	partition.Columns = sc.Complete([]sc.Ref{column.Ref})
	predicate := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: "ks", Table: "view", Name: "VIEW PREDICATE"}, "viewPredicate")
	predicate.Check = sc.Known(expression)
	table := sc.Table{Ref: ref, Kind: sc.Known("materializedView"), Options: sc.Complete([]sc.Option{{Name: "include_all_columns", Value: "true"}}), Columns: sc.Complete([]sc.Column{column}), Constraints: sc.Complete([]sc.Constraint{primary, partition, predicate}), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete([]sc.Dependency{{From: ref, To: sc.Ref{Kind: "table", Schema: "ks", Name: "base"}, Kind: "materializedView", State: "known"}})}
	collector := sc.NewCollector(context.Background(), sc.DefaultLimits())
	if err := collector.Table(table); err != nil {
		t.Fatal(err)
	}
	d, err := RenderSchemaDefinition(context.Background(), collector.Capture, ref)
	if err != nil || d.Limited || !strings.Contains(d.SQL, `FROM "ks"."base"`) {
		t.Fatal("declared base-table dependency or view predicate lost")
	}
	table.Columns.Items[0].Ref.Name = "key"
	table.Constraints.Items[0].Columns.Items[0].Name = "key"
	table.Constraints.Items[1].Columns.Items[0].Name = "key"
	table.Constraints.Items[2].Check.Value.Dependencies.Items[0].Name = "key"
	d, err = RenderSchemaDefinition(context.Background(), sc.Capture{Tables: []sc.Table{table}}, ref)
	if err != nil || !d.Limited || !strings.Contains(d.SQL, "cannot be rewritten") {
		t.Fatal("unmapped predicate text implied a complete mapped CQL definition")
	}
}
