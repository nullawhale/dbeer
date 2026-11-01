package mysql

import (
	"context"
	"fmt"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMySQLForeignKeyCatalogCompositeOrderAndUnavailableTarget(t *testing.T) {
	session := integrationSession(t)
	schema := integrationSettings(t).Database
	base := fmt.Sprintf("dbeer_fk_%x_", session.connectionID)
	source, target, constraint := base+`child "Ω`, base+"parent `quoted'", base+"foreign `key"
	qualified := func(name string) string { return QuoteIdentifier(schema) + "." + QuoteIdentifier(name) }
	column := QuoteIdentifier
	t.Cleanup(func() {
		for _, sql := range []string{"SET FOREIGN_KEY_CHECKS=1", "DROP TABLE IF EXISTS " + qualified(source), "DROP TABLE IF EXISTS " + qualified(target)} {
			session.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: sql})
		}
	})
	run(t, session, "CREATE TABLE "+qualified(target)+" ("+column("key z")+" BIGINT, "+column("key a")+" VARCHAR(30), PRIMARY KEY ("+column("key a")+","+column("key z")+")) ENGINE=InnoDB")
	run(t, session, "CREATE TABLE "+qualified(source)+" ("+column("child z")+" BIGINT, "+column("child a")+" VARCHAR(30), CONSTRAINT "+column(constraint)+" FOREIGN KEY ("+column("child a")+","+column("child z")+") REFERENCES "+qualified(target)+" ("+column("key a")+","+column("key z")+")) ENGINE=InnoDB")
	request := protocol.CatalogRequest{Kind: "foreignKeys", Schema: schema, Object: source, ObjectKind: "table"}
	assertPairs := func(response protocol.Response) {
		t.Helper()
		if response.Truncated || len(response.Columns) != 6 || len(response.Rows) != 2 {
			t.Fatal("composite foreign key metadata was unavailable")
		}
		for index, pair := range [][2]string{{"child a", "key a"}, {"child z", "key z"}} {
			row := response.Rows[index]
			want := []string{constraint, schema, target, pair[0], pair[1], fmt.Sprint(index + 1)}
			if len(row) != len(want) {
				t.Fatal("foreign key catalog row lost a field")
			}
			for field, expected := range want {
				if row[field] == nil || *row[field] != expected {
					t.Fatal("foreign key lost paired identifiers or constraint order")
				}
			}
		}
	}
	assertPairs(catalogRequest(t, session, request))
	// A dropped target remains a known relationship while foreign-key checks are
	// disabled. Browsing it must fail explicitly rather than return empty rows.
	run(t, session, "SET FOREIGN_KEY_CHECKS=0")
	run(t, session, "DROP TABLE "+qualified(target))
	assertPairs(catalogRequest(t, session, request))
	missing := session.Execute(context.Background(), protocol.Command{Type: "catalog", RequestID: "missing-target", SessionID: "catalog", QueryID: "missing-target",
		Catalog: &protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: target, ObjectKind: "table"}})
	if missing.Type != "error" || !missing.Connected || missing.SQLState != "42S02" {
		t.Fatal("unavailable foreign key target did not fail explicitly")
	}
	missing = session.Execute(context.Background(), protocol.Command{Type: "catalog", RequestID: "missing-source", SessionID: "catalog", QueryID: "missing-source",
		Catalog: &protocol.CatalogRequest{Kind: "foreignKeys", Schema: schema, Object: base + "missing", ObjectKind: "table"}})
	if missing.Type != "error" || !missing.Connected || missing.SQLState != "42S02" {
		t.Fatal("unavailable source metadata was silently presented as no foreign keys")
	}
	assertPairs(catalogRequest(t, session, request))
}

func TestMySQLERDiagramCatalogSelfParallelKeysAndPhysicalPKOrder(t *testing.T) {
	session := integrationSession(t)
	schema := integrationSettings(t).Database
	base := fmt.Sprintf("dbeer_er_%x_", session.connectionID)
	parent, child := base+"parent.with.dots", base+"child.with.dots"
	q := func(name string) string { return QuoteIdentifier(schema) + "." + QuoteIdentifier(name) }
	t.Cleanup(func() {
		for _, name := range []string{child, parent} {
			session.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: "DROP TABLE IF EXISTS " + q(name)})
		}
	})
	run(t, session, "CREATE TABLE "+q(parent)+" (second INT, first INT, alternate INT UNIQUE, PRIMARY KEY(first,second)) ENGINE=InnoDB")
	run(t, session, "CREATE TABLE "+q(child)+" (id INT PRIMARY KEY, a INT, b INT, alt INT, parent INT, CONSTRAINT "+QuoteIdentifier(base+"ordered")+" FOREIGN KEY(a,b) REFERENCES "+q(parent)+"(first,second), CONSTRAINT "+QuoteIdentifier(base+"parallel")+" FOREIGN KEY(a,b) REFERENCES "+q(parent)+"(first,second), CONSTRAINT "+QuoteIdentifier(base+"non_primary")+" FOREIGN KEY(alt) REFERENCES "+q(parent)+"(alternate), CONSTRAINT "+QuoteIdentifier(base+"self")+" FOREIGN KEY(parent) REFERENCES "+q(child)+"(id)) ENGINE=InnoDB")
	columns := catalogRequest(t, session, protocol.CatalogRequest{Kind: "columns", Schema: schema, Object: parent, ObjectKind: "table"})
	if len(columns.Rows) != 3 {
		t.Fatal("ER column metadata is incomplete")
	}
	for i, want := range []string{"2", "1", "0"} {
		found := false
		for j, column := range columns.Columns {
			if column.Name == "primaryKey" && columns.Rows[i][j] != nil && *columns.Rows[i][j] == want {
				found = true
			}
		}
		if !found {
			t.Fatal("ER column metadata lost physical order or primary-key ordinals")
		}
	}
	keys := catalogRequest(t, session, protocol.CatalogRequest{Kind: "foreignKeys", Schema: schema, Object: child, ObjectKind: "table"})
	if keys.Truncated || len(keys.Rows) != 6 {
		t.Fatal("ER self/parallel relationships were merged or truncated")
	}
	counts := map[string]int{}
	for _, row := range keys.Rows {
		if len(row) != 6 || row[0] == nil || row[1] == nil || *row[1] != schema || row[2] == nil {
			t.Fatal("ER target identity was unavailable")
		}
		counts[*row[0]]++
		if *row[0] == base+"self" && *row[2] != child {
			t.Fatal("ER self-reference retargeted")
		}
	}
	if counts[base+"ordered"] != 2 || counts[base+"parallel"] != 2 || counts[base+"self"] != 1 || counts[base+"non_primary"] != 1 {
		t.Fatal("ER constraints lost atomic identity")
	}
}
