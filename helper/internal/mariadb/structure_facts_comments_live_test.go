package mariadb

import (
	"context"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	"fmt"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"testing"
)

func TestMariaDBStructureFactsNativeRoutineComments(t *testing.T) {
	owner := schemaNativeAdmin(t)
	name := fmt.Sprintf("data_routine_target_%d", owner.connectionID)
	external := name + "_external"
	schema, other := QuoteIdentifier(name), QuoteIdentifier(external)
	dataRun(t, owner, "CREATE DATABASE "+schema)
	dataRun(t, owner, "CREATE DATABASE "+other)
	t.Cleanup(func() {
		owner.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + other})
		owner.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
	})
	dataRun(t, owner, "CREATE TABLE "+schema+".`target`(id INT,n VARCHAR(8)) ENGINE=InnoDB")
	dataRun(t, owner, "INSERT INTO "+schema+".`target` VALUES(1,'one'),(2,'two')")
	dataRun(t, owner, "CREATE PROCEDURE "+other+".`unrelated_dash`() BEGIN -- John's unpaired quote mentions "+name+".target in a valid comment\n SELECT 1; END")
	dataRun(t, owner, "CREATE PROCEDURE "+other+".`unrelated_hash`() BEGIN # John's unpaired quote mentions "+name+".target in a valid comment\n SELECT 1; END")
	meta := dataRun(t, owner, "SELECT ENGINE,TABLE_COLLATION,CREATE_OPTIONS,TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA='"+name+"' AND TABLE_NAME='target'").Rows
	capture := func() *tableedit.Facts {
		var facts *tableedit.Facts
		var err error
		response := owner.executeWith(context.Background(), protocol.Command{}, func(_ *collector, _ *wire.Result) error {
			facts, err = owner.readStructureFacts(tableedit.Target{Schema: name, Table: "target"}, *meta[0][0], *meta[0][1], *meta[0][2], *meta[0][3])
			return err
		})
		if err != nil || response.Type != "query.result" || facts == nil {
			t.Fatal("native routine dependency capture unavailable")
		}
		return facts
	}
	before := capture()
	if !before.Proof || len(before.Dependents[""]) != 0 {
		t.Fatalf("unrelated native inventory overblocked ordinary shape: proof=%t globalCount=%d", before.Proof, len(before.Dependents[""]))
	}
	dataRun(t, owner, "CREATE PROCEDURE "+other+".`referencing`() BEGIN -- John's quote and # are comments\n SELECT id FROM "+schema+".`target`; END")
	after := capture()
	found := false
	for _, dependent := range after.Dependents[""] {
		found = found || dependent == external+".referencing"
	}
	if !after.Proof || !found {
		t.Fatal("real external native routine dependency disappeared")
	}
	dataRun(t, owner, "DROP PROCEDURE "+other+".`referencing`")
	// A genuine referencing body beyond the declared scalar bound stays unknown.
	padding := ""
	for len(padding) < 66000 {
		padding += " native comment padding"
	}
	dataRun(t, owner, "CREATE PROCEDURE "+other+".`oversized`() BEGIN /*"+padding+"*/ SELECT id FROM "+schema+".`target`; END")
	unknown := capture()
	if unknown.Proof || len(unknown.Dependents[""]) == 0 || owner.closed.Load() {
		t.Fatal("bounded unavailable routine metadata gained complete authority or closed its owner")
	}
}
