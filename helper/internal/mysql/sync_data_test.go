package mysql

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
	tc "dbeer/helper/internal/tablecapture"
	"encoding/json"
	"strings"
	"testing"
)

func mySyncColumn(index int, name, kind string) tc.Column {
	u := sc.TypeUse{Kind: "builtin", Ref: sc.Ref{Kind: "type", Name: kind}, Modifiers: sc.Known(sc.TypeModifiers{}), Labels: sc.Complete[string](nil)}
	b, _ := json.Marshal(struct {
		Type               sc.TypeUse
		Charset, Collation string
	}{Type: u})
	definition, _ := json.Marshal([]any{name, "1", kind, kind, "YES", nil, ""})
	c := tc.Column{Index: index, Name: name, NativeType: string(b), Definition: definition, Numeric: kind == "bigint" || kind == "decimal"}
	if binaryType(kind) {
		c.Encoding = "base64"
	}
	return c
}
func mySyncText(s string) *string { return &s }
func TestMySQLDataSynchronizationExactLiteralsAndBinaryGuards(t *testing.T) {
	d := tc.Descriptor{Engine: "mysql", Table: tc.Table{Schema: "s`;", Name: "t`;"}, Columns: []tc.Column{mySyncColumn(0, "id", "bigint"), mySyncColumn(1, "text", "text"), mySyncColumn(2, "number", "decimal"), mySyncColumn(3, "bytes", "varbinary"), mySyncColumn(4, "nullable", "text")}}
	op := syncplan.DataOperation{Kind: "update", Descriptor: d, Mappings: []syncplan.DataMapping{{SourceIndex: 0, TargetIndex: 0, Key: true}, {SourceIndex: 1, TargetIndex: 1}, {SourceIndex: 2, TargetIndex: 2}, {SourceIndex: 3, TargetIndex: 3}, {SourceIndex: 4, TargetIndex: 4}}, Source: []*string{mySyncText("9007199254740993"), mySyncText("x';--\\\x00"), mySyncText("12345678901234567890.12345678901234567890"), mySyncText("AP+A"), mySyncText("")}, Target: []*string{mySyncText("9007199254740993"), mySyncText("NULL"), mySyncText("1.00"), mySyncText(""), nil}}
	sql, e := RenderDataSynchronization(op)
	if e != nil {
		t.Fatal(e)
	}
	for _, want := range []string{"UPDATE `s``;`.`t``;`", "CONVERT(X'78273b2d2d5c00' USING utf8mb4)", "X'00ff80'", "AS DECIMAL(65,19)", "`nullable` IS NULL", "CAST(CAST(`text` AS CHAR CHARACTER SET utf8mb4) AS BINARY) <=> X'4e554c4c'", "LIMIT 1;"} {
		if !strings.Contains(sql, want) {
			t.Fatalf("missing safe literal/guard %q", want)
		}
	}
	if strings.Contains(sql, "12345678901234567000") || strings.Contains(sql, "x';--") {
		t.Fatal("coercion or raw literal")
	}
}
func TestMySQLDataSynchronizationUnsupportedStoredTypesAndIdentityZero(t *testing.T) {
	for _, kind := range []string{"enum", "set", "float", "double", "timestamp", "char", "geometry", "vector"} {
		d := tc.Descriptor{Engine: "mysql", Table: tc.Table{Schema: "db", Name: "t"}, Columns: []tc.Column{mySyncColumn(0, "value", kind)}}
		if _, e := RenderDataSynchronization(syncplan.DataOperation{Kind: "insert", Descriptor: d, Mappings: []syncplan.DataMapping{{SourceIndex: 0, TargetIndex: 0}}, Source: []*string{mySyncText("1")}}); e == nil {
			t.Fatalf("%s guessed", kind)
		}
	}
	id := mySyncColumn(0, "id", "bigint")
	id.Identity = true
	d := tc.Descriptor{Engine: "mysql", Table: tc.Table{Schema: "db", Name: "t"}, Columns: []tc.Column{id}}
	op := syncplan.DataOperation{Kind: "insert", Descriptor: d, Mappings: []syncplan.DataMapping{{SourceIndex: 0, TargetIndex: 0}}, Source: []*string{mySyncText("0")}}
	if _, e := RenderDataSynchronization(op); e == nil {
		t.Fatal("zero auto increment depends on SQL mode")
	}
	op.Source[0] = mySyncText("9007199254740993")
	if sql, e := RenderDataSynchronization(op); e != nil || !strings.Contains(sql, "DECIMAL(65,0)") {
		t.Fatal("exact identity insert unsupported")
	}
}

func TestMySQLDataSynchronizationRejectsAutomaticOnUpdateColumns(t *testing.T) {
	d := tc.Descriptor{Engine: "mysql", Table: tc.Table{Schema: "db", Name: "t"}, Columns: []tc.Column{mySyncColumn(0, "id", "bigint"), mySyncColumn(1, "note", "text"), mySyncColumn(2, "modified", "datetime")}}
	d.Columns[2].Definition = json.RawMessage(`["modified","3","datetime","datetime","NO",null,"DEFAULT_GENERATED on update CURRENT_TIMESTAMP",null]`)
	op := syncplan.DataOperation{Kind: "update", Descriptor: d, Mappings: []syncplan.DataMapping{{SourceIndex: 0, TargetIndex: 0, Key: true}, {SourceIndex: 1, TargetIndex: 1}}, Source: []*string{mySyncText("1"), mySyncText("new")}, Target: []*string{mySyncText("1"), mySyncText("old"), mySyncText("2026-10-27 12:00:00")}}
	if _, e := RenderDataSynchronization(op); e == nil {
		t.Fatal("excluded ON UPDATE column was allowed to mutate")
	}
}

func TestMySQLDataSynchronizationRequiresKnownUpdateMetadata(t *testing.T) {
	for _, definition := range []json.RawMessage{nil, json.RawMessage(`null`), json.RawMessage(`[]`), json.RawMessage(`{}`), json.RawMessage(`broken`), json.RawMessage(`["note","2","text","text","YES",null,null]`)} {
		d := tc.Descriptor{Engine: "mysql", Table: tc.Table{Schema: "db", Name: "t"}, Columns: []tc.Column{mySyncColumn(0, "id", "bigint"), mySyncColumn(1, "note", "text")}}
		d.Columns[1].Definition = definition
		op := syncplan.DataOperation{Kind: "update", Descriptor: d, Mappings: []syncplan.DataMapping{{SourceIndex: 0, TargetIndex: 0, Key: true}, {SourceIndex: 1, TargetIndex: 1}}, Source: []*string{mySyncText("1"), mySyncText("new")}, Target: []*string{mySyncText("1"), mySyncText("old")}}
		if _, err := RenderDataSynchronization(op); err == nil {
			t.Fatal("missing or malformed ON UPDATE metadata was treated as no side effects")
		}
	}
}
