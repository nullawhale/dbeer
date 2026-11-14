package mariadb

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
	"strings"
	"testing"
)

func synchronizationNativeCapture() (sc.Capture, sc.Table) {
	c := definitionNativeColumn("v", "int")
	ref := sc.Ref{Kind: "table", Schema: c.Ref.Schema, Name: c.Ref.Table}
	table := sc.Table{Ref: ref, Kind: sc.Known("table"), Storage: sc.Known("InnoDB"), Charset: sc.Known("utf8mb4"), Collation: sc.Known(sc.Ref{Kind: "collation", Name: "utf8mb4_bin"}), Options: sc.Complete[sc.Option](nil), Columns: sc.Complete([]sc.Column{c}), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}
	return sc.Capture{Context: sc.CaptureContext{Engine: "mariadb", EngineContext: definitionNativeMode("")}, Tables: []sc.Table{table}}, table
}
func TestMariaDBSchemaSynchronizationGuardedColumns(t *testing.T) {
	capture, table := synchronizationNativeCapture()
	table.Options = sc.Complete([]sc.Option{{Name: "columnSystemVersioning:v", Value: "without"}})
	capture.Tables = []sc.Table{table}
	old := capture
	column := table.Columns.Items[0]
	column.Comment = sc.Known("reviewed quote's comment")
	table.Columns = sc.Complete([]sc.Column{column})
	table.Options = sc.Complete([]sc.Option{{Name: "columnSystemVersioning:v", Value: "without"}})
	capture.Tables = []sc.Table{table}
	sql, manual, e := RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "alter", Ref: column.Ref, Source: capture, Target: old})
	if e != nil || manual != "" || !strings.Contains(sql, "WITHOUT SYSTEM VERSIONING") || !strings.Contains(sql, "quote''s") {
		t.Fatal("native column synchronization lost exact selected properties")
	}
	changedPolicy := old
	oldTable := old.Tables[0]
	oldTable.Options = sc.Complete[sc.Option](nil)
	changedPolicy.Tables = []sc.Table{oldTable}
	if sql, manual, e = RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "alter", Ref: column.Ref, Source: capture, Target: changedPolicy}); e != nil || manual == "" || sql != "" {
		t.Fatal("ordinary native column change carried an unselected history policy transformation")
	}
	column.Type = sc.Unknown[sc.TypeUse]("nativeUnproven")
	table.Columns = sc.Complete([]sc.Column{column})
	capture.Tables = []sc.Table{table}
	if sql, manual, e = RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "alter", Ref: column.Ref, Source: capture, Target: old}); e != nil || manual == "" || sql != "" {
		t.Fatal("unproven native transformation returned partial executable SQL")
	}
}
func TestMariaDBSchemaSynchronizationManualBoundaries(t *testing.T) {
	capture, table := synchronizationNativeCapture()
	for _, action := range []string{"drop", "alter"} {
		if sql, manual, e := RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: action, Ref: table.Ref, Source: capture, Target: capture}); e != nil || manual == "" || sql != "" {
			t.Fatal("unsupported native replacement gained automatic authority")
		}
	}
	for _, comment := range []string{"slash\\tail", "line\nfeed"} {
		column := table.Columns.Items[0]
		column.Comment = sc.Known(comment)
		table.Columns = sc.Complete([]sc.Column{column})
		capture.Tables = []sc.Table{table}
		if sql, manual, e := RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "create", Ref: table.Ref, Source: capture, Target: capture}); e != nil || manual == "" || sql != "" {
			t.Fatal("saved native DDL silently assumed a future SQL mode")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	capture, table = synchronizationNativeCapture()
	if _, _, e := RenderSynchronizationSchema(ctx, syncplan.SchemaOperation{Action: "create", Ref: table.Ref, Source: capture, Target: capture}); e == nil {
		t.Fatal("canceled native renderer returned success")
	}
}
