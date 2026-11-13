package sqlite_test

import (
	"fmt"
	"reflect"
	"testing"

	"dbeer/helper/internal/protocol"
)

func relationshipSQLitePages(t *testing.T, h *completionHarness, sid string, selector protocol.CatalogRequest) ([]map[string]string, string) {
	t.Helper()
	var out []map[string]string
	cursor, capture, state := "", "", ""
	for {
		id := h.id()
		h.m.Submit(protocol.Command{Type: "catalog.page", RequestID: id, QueryID: id, SessionID: sid, CatalogMetadata: &protocol.CatalogMetadataRequest{Selectors: []protocol.CatalogRequest{selector}, Cursor: cursor, PageSize: 1}})
		if h.receive().Type != "query.started" {
			t.Fatal("relationship metadata did not start")
		}
		reply := h.receive()
		if reply.Type != "catalog.page.result" || reply.CatalogMetadata == nil || !reply.CatalogMetadata.Valid() {
			t.Fatal("relationship metadata terminal invalid")
		}
		page := reply.CatalogMetadata.Collections[0]
		if selector.Kind == "referencingTables" && page.State != "unavailable" && page.State != "stale" && (page.Target == nil || page.Target.Schema != "main" || !page.Target.Valid()) {
			t.Fatal("SQLite canonical target proof is missing")
		}
		if capture != "" && capture != page.CaptureID {
			t.Fatal("relationship capture identity changed")
		}
		capture, state = page.CaptureID, page.State
		for _, row := range page.Rows {
			record := map[string]string{}
			for i, value := range row {
				if value != nil {
					record[page.Columns[i].Name] = *value
				}
			}
			out = append(out, record)
		}
		cursor = page.NextCursor
		if cursor == "" {
			break
		}
	}
	id := h.id()
	h.m.Submit(protocol.Command{Type: "catalog.close", RequestID: id, QueryID: id, SessionID: sid, CatalogMetadata: &protocol.CatalogMetadataRequest{CaptureIDs: []string{capture}}})
	if h.receive().Type != "query.started" || h.receive().Type != "catalog.close.result" {
		t.Fatal("relationship capture did not close")
	}
	return out, state
}

func TestSQLiteRelationshipDiscoveryCanonicalCompositeSelfAndSeparateSources(t *testing.T) {
	h := newCompletionHarness(t)
	sid := h.connect(completionFile(t))
	h.run(sid, `CREATE TABLE "Parent"("Tenant" INTEGER NOT NULL,"Key" BLOB NOT NULL,"ParentTenant" INTEGER,"ParentKey" BLOB,PRIMARY KEY("Tenant","Key"),FOREIGN KEY("parenttenant","parentkey") REFERENCES "PARENT"("tenant","key"))`)
	h.run(sid, `CREATE TABLE "ChildA"("Id" INTEGER PRIMARY KEY,"TenantRef" INTEGER,"KeyRef" BLOB,"OtherTenant" INTEGER,"OtherKey" BLOB,FOREIGN KEY("tenantref","keyref") REFERENCES "parent"("TENANT","KEY"),FOREIGN KEY("othertenant","otherkey") REFERENCES "PARENT")`)
	h.run(sid, `CREATE TABLE "ChildB"("Id" INTEGER PRIMARY KEY,"TenantRef" INTEGER,"KeyRef" BLOB,FOREIGN KEY("TENANTREF","KEYREF") REFERENCES "pArEnT"("tenant","key"))`)
	h.run(sid, `CREATE TABLE unrelated(id INTEGER PRIMARY KEY)`)
	h.run(sid, `INSERT INTO "Parent"("Tenant","Key") VALUES(9223372036854775807,X'00ff80'),(9223372036854775806,X'00ff80'),(9223372036854775807,X'00ff81')`)
	h.run(sid, `INSERT INTO "ChildA"("Id","TenantRef","KeyRef") VALUES(1,9223372036854775807,X'00ff80'),(2,9223372036854775806,X'00ff80'),(3,9223372036854775807,X'00ff81'),(4,NULL,NULL)`)
	incoming := protocol.CatalogRequest{Kind: "referencingTables", Schema: "main", Object: "Parent", ObjectKind: "table"}
	expected := []map[string]string{{"schema": "main", "name": "ChildA", "kind": "table"}, {"schema": "main", "name": "ChildB", "kind": "table"}, {"schema": "main", "name": "Parent", "kind": "table"}}
	normal, reply := h.catalog(sid, incoming)
	if reply.Type != "query.result" || !reflect.DeepEqual(normal, expected) {
		t.Fatal("incoming sources lost canonical names, self-reference, deduplication, or scope")
	}
	paged, state := relationshipSQLitePages(t, h, sid, incoming)
	if state != "complete" || !reflect.DeepEqual(paged, expected) {
		t.Fatal("paged incoming sources diverged from regular catalog")
	}
	for _, source := range []string{"ChildA", "ChildB", "Parent"} {
		selector := protocol.CatalogRequest{Kind: "foreignKeys", Schema: "main", Object: source, ObjectKind: "table"}
		normal, reply = h.catalog(sid, selector)
		paged, state = relationshipSQLitePages(t, h, sid, selector)
		if reply.Type != "query.result" || state != "complete" || !reflect.DeepEqual(normal, paged) {
			t.Fatal("paged foreign-key column mapping diverged")
		}
		for _, row := range normal {
			if row["targetTable"] != "Parent" || row["targetSchema"] != "main" || (row["targetColumn"] != "Tenant" && row["targetColumn"] != "Key") {
				t.Fatal("foreign-key target spelling was not resolved to catalog spelling")
			}
			if row["sourceColumn"] == "tenantref" || row["sourceColumn"] == "TENANTREF" || row["sourceColumn"] == "parenttenant" {
				t.Fatal("foreign-key source spelling was not resolved to actual column")
			}
		}
	}

}

func TestSQLiteRelationshipDiscoveryDoesNotFoldUnicodeOrInventMissingTargets(t *testing.T) {
	h := newCompletionHarness(t)
	sid := h.connect(completionFile(t))
	for i, name := range []string{"Ä", "ä", "é", "e\u0301"} {
		h.run(sid, fmt.Sprintf(`CREATE TABLE "%s"("Ö" INTEGER PRIMARY KEY)`, name))
		h.run(sid, fmt.Sprintf(`CREATE TABLE child_%d(id INTEGER PRIMARY KEY,source_key INTEGER REFERENCES "%s"("Ö"))`, i, name))
	}
	h.run(sid, `CREATE TABLE missing(id INTEGER PRIMARY KEY,source_key INTEGER REFERENCES "Absent"("X"))`)
	for i, name := range []string{"Ä", "ä", "é", "e\u0301"} {
		selector := protocol.CatalogRequest{Kind: "referencingTables", Schema: "main", Object: name, ObjectKind: "table"}
		rows, reply := h.catalog(sid, selector)
		paged, state := relationshipSQLitePages(t, h, sid, selector)
		if reply.Type != "query.result" || len(rows) != 1 || rows[0]["name"] != fmt.Sprintf("child_%d", i) || state != "complete" || !reflect.DeepEqual(rows, paged) {
			t.Fatal("distinct Unicode identifiers were folded or normalized")
		}
	}
	rows, reply := h.catalog(sid, protocol.CatalogRequest{Kind: "foreignKeys", Schema: "main", Object: "missing", ObjectKind: "table"})
	if reply.Type != "query.result" || len(rows) != 1 || rows[0]["targetTable"] != "Absent" || rows[0]["targetColumn"] != "X" {
		t.Fatal("unresolved declared target was silently replaced")
	}
	pagedMissing, missingState := relationshipSQLitePages(t, h, sid, protocol.CatalogRequest{Kind: "foreignKeys", Schema: "main", Object: "missing", ObjectKind: "table"})
	if missingState != "complete" || !reflect.DeepEqual(rows, pagedMissing) {
		t.Fatal("fully declared orphan mapping was discarded or rewritten")
	}
	_, unavailableTarget := h.catalog(sid, protocol.CatalogRequest{Kind: "columns", Schema: "main", Object: "Absent", ObjectKind: "table"})
	if unavailableTarget.Type != "error" {
		t.Fatal("missing target availability was assumed from its declared mapping")
	}
	h.run(sid, `CREATE TABLE unicode_column(id INTEGER PRIMARY KEY,source_key INTEGER REFERENCES "Ä"("ö"))`)
	rows, reply = h.catalog(sid, protocol.CatalogRequest{Kind: "foreignKeys", Schema: "main", Object: "unicode_column", ObjectKind: "table"})
	if reply.Type != "query.result" || len(rows) != 1 || rows[0]["targetColumn"] != "ö" {
		t.Fatal("a Unicode target column was incorrectly case folded")
	}
	pagedColumn, columnState := relationshipSQLitePages(t, h, sid, protocol.CatalogRequest{Kind: "foreignKeys", Schema: "main", Object: "unicode_column", ObjectKind: "table"})
	if columnState != "complete" || !reflect.DeepEqual(rows, pagedColumn) {
		t.Fatal("fully declared Unicode column mapping was discarded or rewritten")
	}
	h.run(sid, `CREATE TABLE implicit_missing(id INTEGER PRIMARY KEY,source_key INTEGER REFERENCES "Absent")`)
	_, implicitState := relationshipSQLitePages(t, h, sid, protocol.CatalogRequest{Kind: "foreignKeys", Schema: "main", Object: "implicit_missing", ObjectKind: "table"})
	if implicitState != "partial" {
		t.Fatal("an unresolved implicit primary-key mapping became complete")
	}
	_, reply = h.catalog(sid, protocol.CatalogRequest{Kind: "referencingTables", Schema: "main", Object: "Absent", ObjectKind: "table"})
	_, state := relationshipSQLitePages(t, h, sid, protocol.CatalogRequest{Kind: "referencingTables", Schema: "main", Object: "Absent", ObjectKind: "table"})
	if reply.Type != "error" || state != "unavailable" {
		t.Fatal("missing target became a complete empty incoming observation")
	}
}

func TestSQLiteRelationshipDiscoveryKeepsImplicitCardinalityProofInPages(t *testing.T) {
	h := newCompletionHarness(t)
	sid := h.connect(completionFile(t))
	h.run(sid, `CREATE TABLE "Parent"("Second" BLOB NOT NULL,"First" INTEGER NOT NULL,PRIMARY KEY("First","Second"))`)
	h.run(sid, `CREATE TABLE implicit_good(id INTEGER PRIMARY KEY,one INTEGER,two BLOB,FOREIGN KEY(one,two) REFERENCES "PARENT")`)
	h.run(sid, `CREATE TABLE implicit_bad(id INTEGER PRIMARY KEY,one INTEGER REFERENCES "PARENT")`)
	for _, source := range []string{"implicit_good", "implicit_bad"} {
		selector := protocol.CatalogRequest{Kind: "foreignKeys", Schema: "main", Object: source, ObjectKind: "table"}
		rows, state := relationshipSQLitePages(t, h, sid, selector)
		if source == "implicit_good" && state != "complete" {
			t.Fatal("provable implicit target metadata capture was not complete")
		}
		if source == "implicit_good" && (len(rows) != 2 || rows[0]["targetColumn"] != "First" || rows[1]["targetColumn"] != "Second") {
			t.Fatal("implicit composite target order was lost")
		}
		if source == "implicit_bad" && (state != "partial" || len(rows) != 0) {
			t.Fatal("incomplete implicit mapping became a complete capture or retained an unusable group")
		}
	}
}

func TestSQLiteRelationshipDiscoveryEmptyCaseAliasStillResolvesTarget(t *testing.T) {
	h := newCompletionHarness(t)
	sid := h.connect(completionFile(t))
	h.run(sid, `CREATE TABLE "EmptyParent"(id INTEGER PRIMARY KEY)`)
	selector := protocol.CatalogRequest{Kind: "referencingTables", Schema: "main", Object: "EMPTYPARENT", ObjectKind: "table"}
	id := h.id()
	h.m.Submit(protocol.Command{Type: "catalog.page", RequestID: id, QueryID: id, SessionID: sid, CatalogMetadata: &protocol.CatalogMetadataRequest{Selectors: []protocol.CatalogRequest{selector}}})
	if h.receive().Type != "query.started" {
		t.Fatal("canonical target metadata did not start")
	}
	reply := h.receive()
	if reply.CatalogMetadata == nil || !reply.CatalogMetadata.Valid() {
		t.Fatal("empty canonical target observation invalid")
	}
	page := reply.CatalogMetadata.Collections[0]
	if page.State != "complete" || len(page.Rows) != 0 || page.Target == nil || page.Target.Name != "EmptyParent" {
		t.Fatal("empty incoming list lost the canonical alias proof")
	}
}
