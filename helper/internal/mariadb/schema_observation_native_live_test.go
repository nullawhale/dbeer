package mariadb

import (
	"context"
	"dbeer/helper/internal/protocol"
	"fmt"
	"testing"
)

func TestMariaDBSchemaObservationNativeSelectedMetadata(t *testing.T) {
	owner, editor := schemaNativeAdmin(t), schemaNativeAdmin(t)
	name := fmt.Sprintf("data_observe_%d", owner.connectionID)
	schema := QuoteIdentifier(name)
	table := schema + ".`t`"
	dataRun(t, editor, "CREATE DATABASE "+schema+" CHARACTER SET utf8mb4")
	t.Cleanup(func() {
		editor.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
	})
	dataRun(t, editor, "CREATE TABLE "+table+"(id BIGINT AUTO_INCREMENT PRIMARY KEY,n DECIMAL(65,38),v VARCHAR(32) DEFAULT '😀',b VARBINARY(8) DEFAULT x'00ff') ENGINE=InnoDB")
	dataRun(t, editor, "INSERT INTO "+table+"(n) VALUES(1),(2)")
	probe := protocol.Command{Type: "monitor.schema", SchemaObservation: &protocol.SchemaObservationRequest{Action: "poll", Tables: []protocol.SchemaObservationTable{{Schema: name, Name: "t"}}}}
	if response := owner.ObserveSchema(context.Background(), probe); response.Type != "error" || owner.closed.Load() || owner.TransactionStatus() != "idle" {
		t.Fatal("writable service context gained observation authority or was reset")
	}
	if e := owner.SetReadOnly(context.Background(), true); e != nil {
		t.Fatal("readonly observation service unavailable")
	}
	command := protocol.Command{Type: "monitor.schema", SchemaObservation: &protocol.SchemaObservationRequest{Action: "poll", Tables: []protocol.SchemaObservationTable{{Schema: name, Name: "t"}}}}
	poll := func() protocol.SchemaObservation {
		response := owner.ObserveSchema(context.Background(), command)
		if response.Type != "monitor.schema.result" || response.SchemaObservation == nil || !response.Connected || response.TransactionStatus != "idle" {
			t.Fatal("native selected metadata observation failed")
		}
		return *response.SchemaObservation
	}
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	if response := owner.ObserveSchema(canceled, command); response.Type != "error" || owner.closed.Load() || owner.TransactionStatus() != "idle" {
		t.Fatal("canceled metadata observation changed owner state")
	}
	initial := poll()
	if !initial.Complete || len(initial.Revision) != 64 || initial.Engine != "mariadb" || !initial.Valid() {
		t.Fatal("native observation completeness/identity absent")
	}
	if again := poll(); again.Revision != initial.Revision {
		t.Fatal("stable native metadata produced a changing revision")
	}
	dataRun(t, editor, "INSERT INTO "+table+"(n) VALUES(3)")
	if again := poll(); again.Revision != initial.Revision {
		t.Fatal("native data-only counter movement became schema change")
	}
	dataRun(t, editor, "ALTER TABLE "+table+" ALTER COLUMN b SET DEFAULT x'00fe'")
	changed := poll()
	if !changed.Complete || changed.Revision == initial.Revision {
		t.Fatal("exact native stored default change escaped observation")
	}
	dataRun(t, editor, "ALTER TABLE "+table+" ADD COLUMN e ENUM(x'ff',x'fe') CHARACTER SET binary")
	incomplete := poll()
	if incomplete.Complete || incomplete.Revision != "" || len(incomplete.Notices) == 0 {
		t.Fatal("unproven native label domain gained complete observation")
	}
	dataRun(t, owner, "BEGIN")
	response := owner.ObserveSchema(context.Background(), command)
	if response.Type != "error" || owner.TransactionStatus() != "transaction" || owner.closed.Load() {
		t.Fatal("observation reset an active service transaction")
	}
	dataRun(t, owner, "ROLLBACK")
	state := dataRun(t, owner, "SELECT @@SESSION.tx_read_only").Rows
	if len(state) != 1 || state[0][0] == nil || *state[0][0] != "1" {
		t.Fatal("observation changed service read-only mode")
	}
	if editor.connectionID == owner.connectionID || *dataRun(t, editor, "SELECT COUNT(*) FROM "+table).Rows[0][0] != "3" {
		t.Fatal("independent writer or rows changed")
	}
	if response := owner.ObserveSchema(context.Background(), protocol.Command{SchemaObservation: &protocol.SchemaObservationRequest{Action: "previewInstall", Tables: []protocol.SchemaObservationTable{}}}); response.Type != "error" {
		t.Fatal("fingerprint observer granted installation authority")
	}
}
