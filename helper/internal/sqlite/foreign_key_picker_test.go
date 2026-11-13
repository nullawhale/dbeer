package sqlite_test

import (
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestSQLiteForeignKeyPickerResolvesImplicitParentPrimaryKeyInKeyOrder(t *testing.T) {
	h := newCompletionHarness(t)
	sid := h.connect(completionFile(t))
	h.run(sid, `CREATE TABLE parent(code BLOB NOT NULL,label TEXT,tenant INTEGER NOT NULL,PRIMARY KEY(tenant,code))`)
	h.run(sid, `CREATE TABLE child(id INTEGER PRIMARY KEY,source_tenant INTEGER,source_code BLOB,FOREIGN KEY(source_tenant,source_code) REFERENCES parent)`)
	rows, reply := h.catalog(sid, protocol.CatalogRequest{Kind: "foreignKeys", Schema: "main", Object: "child", ObjectKind: "table"})
	if reply.Type != "query.result" || len(rows) != 2 || rows[0]["sourceColumn"] != "source_tenant" || rows[0]["targetColumn"] != "tenant" || rows[1]["targetColumn"] != "code" {
		t.Fatal("implicit composite target was not resolved in primary-key order")
	}
	h.run(sid, `CREATE TABLE single_parent(label TEXT,parent_key INTEGER PRIMARY KEY)`)
	h.run(sid, `CREATE TABLE single_child(id INTEGER PRIMARY KEY,parent_key INTEGER REFERENCES single_parent)`)
	rows, reply = h.catalog(sid, protocol.CatalogRequest{Kind: "foreignKeys", Schema: "main", Object: "single_child", ObjectKind: "table"})
	if reply.Type != "query.result" || len(rows) != 1 || rows[0]["targetColumn"] != "parent_key" {
		t.Fatal("implicit single-column target was not resolved")
	}
}

func TestSQLiteForeignKeyPickerLeavesUnprovableImplicitTargetsUnresolved(t *testing.T) {
	h := newCompletionHarness(t)
	sid := h.connect(completionFile(t))
	h.run(sid, `CREATE TABLE parent(a INTEGER,b INTEGER,PRIMARY KEY(a,b))`)
	h.run(sid, `CREATE TABLE incomplete(id INTEGER PRIMARY KEY,parent_key INTEGER REFERENCES parent)`)
	rows, reply := h.catalog(sid, protocol.CatalogRequest{Kind: "foreignKeys", Schema: "main", Object: "incomplete", ObjectKind: "table"})
	if reply.Type != "query.result" || len(rows) != 1 || rows[0]["targetColumn"] != "" {
		t.Fatal("mismatched implicit target cardinality was invented")
	}
	h.run(sid, `CREATE TABLE keyless(value INTEGER)`)
	h.run(sid, `CREATE TABLE no_target_key(id INTEGER PRIMARY KEY,parent_key INTEGER REFERENCES keyless)`)
	rows, reply = h.catalog(sid, protocol.CatalogRequest{Kind: "foreignKeys", Schema: "main", Object: "no_target_key", ObjectKind: "table"})
	if reply.Type != "query.result" || len(rows) != 1 || rows[0]["targetColumn"] != "" {
		t.Fatal("rowid was invented as an implicit primary key")
	}
}
