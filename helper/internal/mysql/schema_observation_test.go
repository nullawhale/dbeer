package mysql

import (
	"context"
	"fmt"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func TestMySQLSchemaObservationFingerprintsAndLimits(t *testing.T) {
	s := integrationSession(t)
	name := fmt.Sprintf("schema_observation_%d", time.Now().UnixNano())
	run(t, s, "CREATE TABLE "+QuoteIdentifier(name)+"(id INT PRIMARY KEY, first_item INT, second_item INT, INDEX pair_index(first_item,second_item)) ENGINE=InnoDB")
	t.Cleanup(func() {
		s.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + QuoteIdentifier(name)})
	})
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	command := protocol.Command{Type: "monitor.schema", RequestID: "schema", SessionID: "schema", QueryID: "schema", SchemaObservation: &protocol.SchemaObservationRequest{Action: "poll", Tables: []protocol.SchemaObservationTable{{Schema: integrationSettings(t).Database, Name: name}}}}
	first := s.ObserveSchema(ctx, command)
	if first.SchemaObservation == nil || !first.SchemaObservation.Valid() || !first.SchemaObservation.Complete {
		t.Fatal("initial MySQL fingerprint unavailable")
	}
	same := s.ObserveSchema(ctx, command)
	if same.SchemaObservation == nil || same.SchemaObservation.Revision != first.SchemaObservation.Revision {
		t.Fatal("unchanged schema fingerprint is unstable")
	}
	run(t, s, "ALTER TABLE "+QuoteIdentifier(name)+" ADD COLUMN new_value TEXT")
	altered := s.ObserveSchema(ctx, command)
	if altered.SchemaObservation == nil || !altered.SchemaObservation.Complete || altered.SchemaObservation.Revision == first.SchemaObservation.Revision {
		t.Fatal("MySQL schema change not reflected in fingerprint")
	}
	run(t, s, "SET SESSION group_concat_max_len=4")
	warning := s.ObserveSchema(ctx, command)
	if warning.SchemaObservation == nil || warning.SchemaObservation.Complete || warning.SchemaObservation.Revision != "" || len(warning.SchemaObservation.Notices) < 2 {
		t.Fatal("limited metadata was reported as a complete fingerprint")
	}
	run(t, s, "SET SESSION group_concat_max_len=1024")
	command.SchemaObservation.Action = "previewInstall"
	command.SchemaObservation.Tables = []protocol.SchemaObservationTable{}
	if r := s.ObserveSchema(ctx, command); r.Type != "error" || r.Category != "capability" {
		t.Fatal("MySQL offered notification installation SQL")
	}
}
