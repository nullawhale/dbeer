package mariadb

import (
	"context"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
	"encoding/json"
	"fmt"
	"reflect"
	"testing"
)

func TestMariaDBDefinitionAndSchemaSyncNative(t *testing.T) {
	owner := schemaNativeAdmin(t)
	name := fmt.Sprintf("data_definition_%d", owner.connectionID)
	schema := QuoteIdentifier(name)
	dataRun(t, owner, "CREATE DATABASE "+schema+" CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
	t.Cleanup(func() {
		owner.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
	})
	dataRun(t, owner, "CREATE TABLE "+schema+".`source`(id INT NOT NULL,n DECIMAL(65,38) DEFAULT 0.125,b VARBINARY(8) DEFAULT x'00ff',v VARCHAR(32) DEFAULT '😀',PRIMARY KEY(id),KEY ignored_native(v(7) DESC) IGNORED COMMENT 'retained native') ENGINE=InnoDB")
	dataRun(t, owner, "INSERT INTO "+schema+".`source`(id,n) VALUES(1,123456789012345678901234567.12345678901234567890123456789012345678),(2,NULL)")
	dataRun(t, owner, "CREATE SEQUENCE "+schema+".`seq_source` START WITH 9007199254741105 INCREMENT BY 7 CACHE 17 ENGINE=InnoDB")
	limits := sc.Limits{Nodes: 256, Members: 8192, Bytes: 8 << 20, Scalar: 65536}
	capture := func() sc.Capture {
		sink := sc.NewCollector(context.Background(), limits)
		if e := owner.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, sink); e != nil {
			t.Fatalf("native definition capture failed: %v", e)
		}
		return sink.Capture
	}
	before := capture()
	var source sc.Table
	for _, table := range before.Tables {
		if table.Ref.Name == "source" {
			source = table
		}
	}
	renamed := definitionNativeMappedTable(t, source, "defined")
	definition, e := RenderSchemaDefinition(context.Background(), sc.Capture{Context: before.Context, Tables: []sc.Table{renamed}}, renamed.Ref)
	if e != nil || definition.Limited || definition.SQL == "" {
		t.Fatal("complete native ordinary definition became limited")
	}
	dataRun(t, owner, definition.SQL)
	dataRun(t, owner, "INSERT INTO "+schema+".`defined` SELECT * FROM "+schema+".`source`")
	values := func(table string) [][]*string {
		return dataRun(t, owner, "SELECT id,n,HEX(b),HEX(v) FROM "+schema+"."+QuoteIdentifier(table)+" ORDER BY id").Rows
	}
	if !reflect.DeepEqual(values("source"), values("defined")) {
		t.Fatal("native definition changed exact values")
	}
	target := definitionNativeMappedTable(t, source, "synced")
	op := syncplan.SchemaOperation{Action: "create", Ref: target.Ref, Source: sc.Capture{Context: before.Context, Tables: []sc.Table{target}}, Target: sc.Capture{Context: before.Context}}
	sql, manual, e := RenderSynchronizationSchema(context.Background(), op)
	if e != nil || manual != "" || sql == "" {
		t.Fatal("guarded native table synchronization was refused")
	}
	dataRun(t, owner, sql)
	for _, constraint := range target.Constraints.Items {
		sql, manual, e = RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "create", Ref: constraint.Ref, Source: sc.Capture{Context: before.Context, Tables: []sc.Table{target}}, Target: sc.Capture{Context: before.Context}})
		if e != nil || manual != "" || sql == "" {
			t.Fatal("native primary-key synchronization refused")
		}
		dataRun(t, owner, sql)
	}
	for _, index := range target.Indexes.Items {
		if index.Ref.Name == "ignored_native" {
			index.Ref.Table = "synced"
			for i := range index.Keys.Items {
				if index.Keys.Items[i].Column.Value != nil {
					index.Keys.Items[i].Column.Value.Table = "synced"
				}
			}
			indexed := target
			indexed.Indexes = sc.Complete([]sc.Index{index})
			sql, manual, e = RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "create", Ref: index.Ref, Source: sc.Capture{Context: before.Context, Tables: []sc.Table{indexed}}, Target: sc.Capture{Context: before.Context}})
			if e != nil || manual != "" || sql == "" {
				t.Fatal("native ignored-index synchronization refused")
			}
			dataRun(t, owner, sql)
		}
	}
	after := capture()
	for _, name := range []string{"defined", "synced"} {
		expected := definitionNativeMappedTable(t, source, name)
		var actual sc.Table
		for _, table := range after.Tables {
			if table.Ref.Name == name {
				actual = table
			}
		}
		if !reflect.DeepEqual(expected.Columns, actual.Columns) || !reflect.DeepEqual(expected.Constraints, actual.Constraints) || !reflect.DeepEqual(expected.Indexes, actual.Indexes) || !reflect.DeepEqual(expected.Options, actual.Options) || !reflect.DeepEqual(expected.Storage, actual.Storage) || !reflect.DeepEqual(expected.Charset, actual.Charset) || !reflect.DeepEqual(expected.Collation, actual.Collation) {
			t.Fatal("native full definition/synchronization changed captured typed properties")
		}
	}
	dataRun(t, owner, "ALTER TABLE "+schema+".`defined` ALTER INDEX `ignored_native` NOT IGNORED")
	mutated := capture()
	var changed sc.Table
	for _, table := range mutated.Tables {
		if table.Ref.Name == "defined" {
			changed = table
		}
	}
	expected := definitionNativeMappedTable(t, source, "defined")
	if reflect.DeepEqual(expected.Indexes, changed.Indexes) {
		t.Fatal("actual changed ignored-index property escaped the native preservation check")
	}
	for i := range expected.Indexes.Items {
		if expected.Indexes.Items[i].Ref.Name == "ignored_native" {
			expected.Indexes.Items[i].Visible = sc.Known(true)
		}
	}
	if !reflect.DeepEqual(expected.Indexes, changed.Indexes) {
		t.Fatal("changed native index control affected unrelated properties")
	}
	sequence := before.Sequences[0]
	sequence.Ref.Name = "seq_defined"
	definition, e = RenderSchemaDefinition(context.Background(), sc.Capture{Context: before.Context, Sequences: []sc.Sequence{sequence}}, sequence.Ref)
	if e != nil || definition.Limited {
		t.Fatal("native sequence configuration definition unavailable")
	}
	dataRun(t, owner, definition.SQL)
	first := dataRun(t, owner, "SELECT NEXT VALUE FOR "+schema+".`seq_defined`").Rows
	if len(first) != 1 || first[0][0] == nil || *first[0][0] != "9007199254741105" {
		t.Fatal("native sequence definition lost exact start")
	}
}

func definitionNativeMappedTable(t *testing.T, source sc.Table, name string) sc.Table {
	t.Helper()
	raw, e := json.Marshal(source)
	if e != nil {
		t.Fatal("native mapped fixture encoding failed")
	}
	var cloned sc.Table
	if json.Unmarshal(raw, &cloned) != nil {
		t.Fatal("native mapped fixture decoding failed")
	}
	refType := reflect.TypeOf(sc.Ref{})
	var visit func(reflect.Value)
	visit = func(v reflect.Value) {
		if !v.IsValid() {
			return
		}
		if v.Type() == refType {
			r := v.Interface().(sc.Ref)
			if r.Schema == source.Ref.Schema {
				if r.Table == source.Ref.Name {
					r.Table = name
				}
				if r.Kind == "table" && r.Name == source.Ref.Name {
					r.Name = name
				}
			}
			v.Set(reflect.ValueOf(r))
			return
		}
		switch v.Kind() {
		case reflect.Pointer:
			if !v.IsNil() {
				visit(v.Elem())
			}
		case reflect.Struct:
			for i := 0; i < v.NumField(); i++ {
				visit(v.Field(i))
			}
		case reflect.Slice:
			for i := 0; i < v.Len(); i++ {
				visit(v.Index(i))
			}
		}
	}
	visit(reflect.ValueOf(&cloned).Elem())
	return cloned
}

func TestMariaDBDefinitionNativeSystemPeriods(t *testing.T) {
	for _, explicit := range []bool{false, true} {
		mode := "implicit"
		if explicit {
			mode = "explicit"
		}
		t.Run(mode, func(t *testing.T) {
			owner := schemaNativeAdmin(t)
			name := fmt.Sprintf("data_period_definition_%d", owner.connectionID)
			schema := QuoteIdentifier(name)
			dataRun(t, owner, "CREATE DATABASE "+schema+" CHARACTER SET utf8mb4")
			t.Cleanup(func() {
				owner.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
			})
			columns := "id INT PRIMARY KEY,v VARCHAR(8) WITHOUT SYSTEM VERSIONING"
			if explicit {
				columns += ",rs TIMESTAMP(6) GENERATED ALWAYS AS ROW START,re TIMESTAMP(6) GENERATED ALWAYS AS ROW END,PERIOD FOR SYSTEM_TIME(rs,re)"
			}
			dataRun(t, owner, "CREATE TABLE "+schema+".`source`("+columns+") ENGINE=InnoDB WITH SYSTEM VERSIONING")
			dataRun(t, owner, "INSERT INTO "+schema+".`source`(id,v) VALUES(1,'before')")
			dataRun(t, owner, "UPDATE "+schema+".`source` SET v='after' WHERE id=1")
			limits := sc.Limits{Nodes: 256, Members: 8192, Bytes: 8 << 20, Scalar: 65536}
			sink := sc.NewCollector(context.Background(), limits)
			if e := owner.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, sink); e != nil {
				t.Fatalf("native period definition capture unavailable: %v", e)
			}
			mapped := definitionNativeMappedTable(t, sink.Capture.Tables[0], "clone")
			definition, e := RenderSchemaDefinition(context.Background(), sc.Capture{Context: sink.Capture.Context, Tables: []sc.Table{mapped}}, mapped.Ref)
			if e != nil || definition.Limited {
				t.Fatal("proven native period definition became incomplete")
			}
			dataRun(t, owner, definition.SQL)
			dataRun(t, owner, "INSERT INTO "+schema+".`clone`(id,v) VALUES(1,'before')")
			dataRun(t, owner, "UPDATE "+schema+".`clone` SET v='after' WHERE id=1")
			after := sc.NewCollector(context.Background(), limits)
			if e := owner.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, after); e != nil {
				t.Fatal("native cloned period metadata unavailable")
			}
			var cloned sc.Table
			for _, table := range after.Capture.Tables {
				if table.Ref.Name == "clone" {
					cloned = table
				}
			}
			if !reflect.DeepEqual(mapped.Columns, cloned.Columns) || !reflect.DeepEqual(mapped.Options, cloned.Options) || !reflect.DeepEqual(mapped.Kind, cloned.Kind) || !reflect.DeepEqual(mapped.Constraints, cloned.Constraints) {
				t.Fatal("native period declaration/excluded-column policy changed")
			}
			rows := dataRun(t, owner, "SELECT id,v FROM "+schema+".`clone` FOR SYSTEM_TIME ALL").Rows
			if len(rows) != 1 || rows[0][1] == nil || *rows[0][1] != "after" {
				t.Fatal("native WITHOUT SYSTEM VERSIONING column lost its actual exclusion behavior")
			}
		})
	}
}
