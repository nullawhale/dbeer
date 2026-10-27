package postgres

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
	tc "dbeer/helper/internal/tablecapture"
	"encoding/json"
	"strings"
	"testing"
)

func pgSyncColumn(index int, name, kind string) tc.Column {
	u := sc.TypeUse{Kind: "builtin", Ref: sc.Ref{Kind: "type", Schema: "pg_catalog", Name: kind}, Modifiers: sc.Known(sc.TypeModifiers{}), Labels: sc.Complete[string](nil)}
	b, _ := json.Marshal(sc.Column{Type: sc.Known(u)})
	c := tc.Column{Index: index, Name: name, Definition: b, NativeType: kind}
	if kind == "bytea" {
		c.Encoding = "base64"
	}
	return c
}
func syncText(s string) *string { return &s }
func TestPostgresDataSynchronizationExactLiteralsAndFullOriginalGuards(t *testing.T) {
	d := tc.Descriptor{Engine: "postgresql", Table: tc.Table{Schema: `s";`, Name: `t";`}, Columns: []tc.Column{pgSyncColumn(0, "id", "int8"), pgSyncColumn(1, "text", "text"), pgSyncColumn(2, "number", "numeric"), pgSyncColumn(3, "bytes", "bytea"), pgSyncColumn(4, "nullable", "text")}}
	op := syncplan.DataOperation{Kind: "update", Descriptor: d, Mappings: []syncplan.DataMapping{{SourceIndex: 0, TargetIndex: 0, Key: true}, {SourceIndex: 1, TargetIndex: 1}, {SourceIndex: 2, TargetIndex: 2}, {SourceIndex: 3, TargetIndex: 3}, {SourceIndex: 4, TargetIndex: 4}}, Source: []*string{syncText("9007199254740993"), syncText("x'; DROP TABLE q;--\\"), syncText("12345678901234567890.12345678901234567890"), syncText("AP+A"), syncText("")}, Target: []*string{syncText("9007199254740993"), syncText("NULL"), syncText("1.00"), syncText(""), nil}}
	sql, e := RenderDataSynchronization(op)
	if e != nil {
		t.Fatal(e)
	}
	for _, want := range []string{`UPDATE ONLY "s"";"."t"";"`, "E'x''; DROP TABLE q;--\\\\'", "12345678901234567890.12345678901234567890", "pg_catalog.decode('00ff80', 'hex')", `"nullable" IS NULL`, `pg_catalog.numeric_send("number")`, `pg_catalog.textsend("text")`, `pg_catalog.int8send("id")`} {
		if !strings.Contains(sql, want) {
			t.Fatalf("SQL omitted safe encoding or original guard %q", want)
		}
	}
	if strings.Contains(sql, `SET "id"`) {
		t.Fatal("key was reassigned")
	}
}
func TestPostgresDataSynchronizationTypedTimestampAndIdentity(t *testing.T) {
	id := pgSyncColumn(0, "id", "int8")
	id.Identity = true
	d := tc.Descriptor{Engine: "postgresql", Table: tc.Table{Schema: "public", Name: "t"}, Columns: []tc.Column{id, pgSyncColumn(1, "time", "timestamptz")}}
	op := syncplan.DataOperation{Kind: "insert", Descriptor: d, Mappings: []syncplan.DataMapping{{SourceIndex: 0, TargetIndex: 0, Key: true}, {SourceIndex: 1, TargetIndex: 1}}, Source: []*string{syncText("42"), syncText("2026-10-27 11:22:33.123456+00")}}
	sql, e := RenderDataSynchronization(op)
	if e != nil || !strings.Contains(sql, "OVERRIDING SYSTEM VALUE") || !strings.Contains(sql, `::"pg_catalog"."timestamptz"`) {
		t.Fatal("identity/timestamp literal omitted")
	}
	op.Kind = "delete"
	op.Target = op.Source
	op.Source = nil
	sql, e = RenderDataSynchronization(op)
	if e != nil || !strings.Contains(sql, "pg_catalog.timestamptz_send") {
		t.Fatal("context-independent time guard omitted")
	}
}
func TestPostgresDataSynchronizationUnsupportedTypesAndIncompleteInserts(t *testing.T) {
	d := tc.Descriptor{Engine: "postgresql", Table: tc.Table{Schema: "public", Name: "t"}, Columns: []tc.Column{pgSyncColumn(0, "id", "int8"), pgSyncColumn(1, "value", "regclass")}}
	op := syncplan.DataOperation{Kind: "insert", Descriptor: d, Mappings: []syncplan.DataMapping{{SourceIndex: 0, TargetIndex: 0, Key: true}, {SourceIndex: 1, TargetIndex: 1}}, Source: []*string{syncText("1"), syncText("table")}}
	if _, e := RenderDataSynchronization(op); e == nil {
		t.Fatal("local type identity was guessed")
	}
	d.Columns[1] = pgSyncColumn(1, "value", "text")
	op.Descriptor = d
	op.Mappings = op.Mappings[:1]
	if _, e := RenderDataSynchronization(op); e == nil {
		t.Fatal("missing insert column was invented")
	}
	op.Mappings = append(op.Mappings, syncplan.DataMapping{SourceIndex: 1, TargetIndex: 1})
	op.Descriptor.Columns[1].Generated = true
	if _, e := RenderDataSynchronization(op); e == nil {
		t.Fatal("generated value was assumed reproducible")
	}
}
