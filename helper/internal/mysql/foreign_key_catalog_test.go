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
