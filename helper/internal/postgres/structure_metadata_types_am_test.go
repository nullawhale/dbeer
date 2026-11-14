package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"reflect"
	"testing"

	"github.com/jackc/pgx/v5"
)

func metadataTypesCapture(q structureReader) *schemaCapture {
	ctx := context.Background()
	limits := sc.Limits{Nodes: 128, Members: 4096, Bytes: 2 << 20, Scalar: 65536}
	return &schemaCapture{ctx: ctx, tx: pgCatalogReader(q), sink: sc.NewCollector(ctx, limits), spec: sc.CaptureSpec{Limits: limits}, skipCustomTypeFormatting: true, types: map[string]sc.TypeUse{}, loading: map[string]bool{}, sequences: map[string]bool{}}
}

func TestMetadataTypesNativeCatalogPropertiesLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE EXTENSION bloom WITH SCHEMA " + pgx.Identifier{f.schema}.Sanitize())
	defer f.exec("DROP EXTENSION IF EXISTS bloom CASCADE")
	f.exec("CREATE EXTENSION hstore WITH SCHEMA " + pgx.Identifier{f.schema}.Sanitize())
	defer f.exec("DROP EXTENSION IF EXISTS hstore CASCADE")
	f.exec("CREATE FUNCTION " + f.table("ordered_args") + "(integer,text,oid,name,bigint,smallint,boolean,real,double precision,numeric,bytea) RETURNS integer LANGUAGE sql IMMUTABLE STRICT AS 'SELECT 1'")
	f.exec("CREATE OPERATOR CLASS " + f.table("ordered_int_ops") + " FOR TYPE integer USING btree AS OPERATOR 1 pg_catalog.<(integer,integer), OPERATOR 2 pg_catalog.<=(integer,integer), OPERATOR 3 pg_catalog.=(integer,integer), OPERATOR 4 pg_catalog.>=(integer,integer), OPERATOR 5 pg_catalog.>(integer,integer), FUNCTION 1 pg_catalog.btint4cmp(integer,integer)")
	f.exec("CREATE COLLATION " + f.table("owned_c") + " FROM pg_catalog.\"C\"")
	f.exec("CREATE TYPE " + f.table("owned_range") + " AS RANGE(subtype=integer)")
	f.exec("CREATE TABLE " + f.table("guarded_indexes") + "(a integer,b text)")
	f.exec("CREATE INDEX owned_class_idx ON " + f.table("guarded_indexes") + "(a " + f.table("ordered_int_ops") + ")")
	f.exec("CREATE INDEX owned_collation_idx ON " + f.table("guarded_indexes") + "(b COLLATE " + f.table("owned_c") + ")")
	lookup := func(sql string, args ...any) string {
		t.Helper()
		var oid string
		if f.observer.QueryRow(ctx, sql, args...).Scan(&oid) != nil {
			t.Fatal("owned metadata identity unavailable")
		}
		return oid
	}
	functionID := lookup("SELECT oid::text FROM pg_catalog.pg_proc WHERE pronamespace=$1::regnamespace AND proname='ordered_args'", f.schema)
	classID := lookup("SELECT oid::text FROM pg_catalog.pg_opclass WHERE opcnamespace=$1::regnamespace AND opcname='ordered_int_ops'", f.schema)
	typeID := lookup("SELECT oid::text FROM pg_catalog.pg_type WHERE typnamespace=$1::regnamespace AND typname='hstore'", f.schema)
	rangeID := lookup("SELECT oid::text FROM pg_catalog.pg_type WHERE typnamespace=$1::regnamespace AND typname='owned_range'", f.schema)
	collationID := lookup("SELECT oid::text FROM pg_catalog.pg_collation WHERE collnamespace=$1::regnamespace AND collname='owned_c'", f.schema)
	tableID := lookup("SELECT oid::text FROM pg_catalog.pg_class WHERE relnamespace=$1::regnamespace AND relname='guarded_indexes'", f.schema)
	operatorID := lookup("SELECT 'pg_catalog.=(oid,oid)'::regoperator::oid::text")
	r := metadataTypesCapture(f.conn)
	function, err := r.typeFunction(functionID, "ordered")
	if err != nil || function == nil || len(function.Arguments) != 11 {
		t.Fatal("native function argument control unavailable")
	}
	for i, name := range []string{"int4", "text", "oid", "name", "int8", "int2", "bool", "float4", "float8", "numeric", "bytea"} {
		if function.Arguments[i].Schema != "pg_catalog" || function.Arguments[i].Name != name {
			t.Fatal("native function argument order changed")
		}
	}
	nextFunction, err := r.typeFunction(functionID, "ordered")
	if err != nil || !reflect.DeepEqual(function, nextFunction) {
		t.Fatal("function scalar properties or argument metadata changed")
	}
	class, err := r.typeOperatorClass(classID)
	if err != nil || class == nil || len(class.Operators) != 5 || len(class.Functions) != 1 {
		t.Fatal("native operator family control unavailable")
	}
	for i, op := range class.Operators {
		if op.Strategy != int64(i+1) || op.Left.Name != "int4" || op.Right.Name != "int4" || op.Purpose != "s" {
			t.Fatal("native operator family order or signatures changed")
		}
	}
	nextClass, err := r.typeOperatorClass(classID)
	if err != nil || !reflect.DeepEqual(class, nextClass) {
		t.Fatal("operator or support function properties changed")
	}
	base, err := r.baseType(typeID)
	if err != nil || base == nil || len(base.Functions) == 0 {
		t.Fatal("native base type control unavailable")
	}
	nextBase, err := r.baseType(typeID)
	if err != nil || !reflect.DeepEqual(base, nextBase) {
		t.Fatal("base type scalar properties changed")
	}
	extension, err := r.typeExtension(typeID)
	if err != nil || extension == nil || extension.Name != "hstore" || extension.Schema.Schema != f.schema {
		t.Fatal("native type extension properties changed")
	}
	r.types["23"] = sc.TypeUse{Kind: "builtin", Ref: sc.Ref{Kind: "type", Schema: "pg_catalog", Name: "int4"}}
	nativeRange, err := r.rangeType(rangeID)
	if err != nil || nativeRange == nil || nativeRange.Subtype.Ref.Name != "int4" || nativeRange.Multirange.Schema != f.schema || nativeRange.Multirange.Name != "owned_multirange" {
		t.Fatal("native range metadata changed")
	}
	operator, err := r.expressionOperator(operatorID)
	if err != nil || operator == nil || operator.Left.Name != "oid" || operator.Right.Name != "oid" || len(operator.Function.Arguments) != 2 {
		t.Fatal("native operator signature changed")
	}
	collation, err := r.typeCollation(collationID)
	if err != nil || collation == nil || len(collation.Items) == 0 {
		t.Fatal("native collation properties unavailable")
	}
	nextCollation, err := r.typeCollation(collationID)
	if err != nil || !reflect.DeepEqual(collation, nextCollation) {
		t.Fatal("collation scalar properties changed")
	}
	for _, requested := range []struct{ kind, name, method string }{{"accessMethod", "bloom", ""}, {"opclass", "ordered_int_ops", "btree"}, {"collation", "owned_c", ""}} {
		schema := f.schema
		if requested.kind == "accessMethod" {
			schema = "pg_catalog"
		}
		guard, e := resolveIndexGuard(ctx, f.conn, requested.kind, tableedit.TypeReference{Schema: schema, Name: requested.name}, requested.method)
		if e != nil || guard.Identity == "" || guard.Definition == "" {
			t.Fatal("complete native index guard unavailable")
		}
		if requested.kind == "collation" && guard.Identity != collationID {
			t.Fatal("wrong native collation identity selected")
		}
	}
	guards, err := captureIndexGuards(ctx, pgCatalogReader(f.conn), tableID)
	if err != nil || len(guards["owned_class_idx"]) != 1 || len(guards["owned_collation_idx"]) != 1 {
		t.Fatal("complete native index guard collection unavailable")
	}
}
