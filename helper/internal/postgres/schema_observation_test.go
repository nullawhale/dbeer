package postgres

import (
	"context"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func TestPostgresSchemaObservationReviewedInstallationNotificationsAndRemoval(t *testing.T) {
	f := newChangeFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	settings := f.settings
	settings.SessionPurpose = "monitor"
	physical, err := Open(ctx, settings)
	if err != nil {
		t.Fatal("cannot open dedicated schema observer")
	}
	s := physical.(*Session)
	defer s.Close()
	if s.SetReadOnly(ctx, true) != nil {
		t.Fatal("cannot make schema observer readonly")
	}
	command := protocol.Command{Type: "monitor.schema", RequestID: "schema", SessionID: "schema", QueryID: "schema", SchemaObservation: &protocol.SchemaObservationRequest{Action: "previewInstall", Tables: []protocol.SchemaObservationTable{}}}
	r := s.ObserveSchema(ctx, command)
	if r.Type != "monitor.schema.result" || r.SchemaObservation == nil || !r.SchemaObservation.Valid() || !r.SchemaObservation.CanInstall || r.SchemaObservation.Installed {
		t.Fatal("installation preview unavailable on fresh isolated server")
	}
	// Preview is a read. Only the disposable administrative fixture executes SQL.
	var exists bool
	if f.conn.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname='dbeer_schema_watch_v1')").Scan(&exists) != nil || exists {
		t.Fatal("preview changed database objects")
	}
	if _, err := f.conn.Exec(ctx, r.SchemaObservation.SQL); err != nil {
		t.Fatal("reviewed isolated installation failed")
	}
	t.Cleanup(func() { _, _ = f.conn.Exec(context.Background(), schemaObservationRemoveSQL) })
	command.SchemaObservation = &protocol.SchemaObservationRequest{Action: "poll", Tables: []protocol.SchemaObservationTable{{Schema: f.schema, Name: "observed"}}}
	started := time.Now()
	first := s.ObserveSchema(ctx, command)
	if time.Since(started) > time.Second {
		t.Fatal("idle notification poll exceeded its bounded read budget")
	}
	if first.SchemaObservation == nil || !first.SchemaObservation.Valid() || !first.SchemaObservation.Installed || !first.SchemaObservation.Complete || s.TransactionStatus() != "idle" {
		t.Fatal("installed observer did not listen in idle readonly session")
	}
	for i := 0; i < 4; i++ {
		unchanged := s.ObserveSchema(ctx, command)
		if unchanged.SchemaObservation == nil || unchanged.SchemaObservation.Revision != first.SchemaObservation.Revision {
			t.Fatal("idle observer changed revision or lost session")
		}
	}
	f.exec("CREATE TABLE " + f.table("observed") + "(id integer)")
	next := s.ObserveSchema(ctx, command)
	if next.SchemaObservation == nil || !next.SchemaObservation.Valid() || next.SchemaObservation.Revision == first.SchemaObservation.Revision {
		t.Fatal("committed DDL notification was missed")
	}
	f.exec("BEGIN")
	f.exec("ALTER TABLE " + f.table("observed") + " ADD COLUMN rolled_back integer")
	f.exec("ROLLBACK")
	started = time.Now()
	afterRollback := s.ObserveSchema(ctx, command)
	if time.Since(started) > time.Second {
		t.Fatal("rollback/no-notification poll did not finish promptly")
	}
	if afterRollback.SchemaObservation == nil || afterRollback.SchemaObservation.Revision != next.SchemaObservation.Revision {
		t.Fatal("uncommitted DDL was reported as a committed notification")
	}
	cancelled, stop := context.WithCancel(context.Background())
	stop()
	stopped := s.ObserveSchema(cancelled, command)
	if stopped.Type != "error" || stopped.OutcomeUnknown {
		t.Fatal("cancelled readonly observation reported a write outcome")
	}
	recovered := s.ObserveSchema(ctx, command)
	if recovered.SchemaObservation == nil || !recovered.SchemaObservation.Complete || s.TransactionStatus() != "idle" {
		t.Fatal("idle observer could not continue after pre-dispatch cancellation")
	}
	// A same-name trigger with a narrower tag filter is an altered installation.
	// It must neither claim full observation nor pass the reviewed removal guard.
	f.exec("DROP EVENT TRIGGER dbeer_schema_watch_v1")
	f.exec("CREATE EVENT TRIGGER dbeer_schema_watch_v1 ON ddl_command_end WHEN TAG IN ('CREATE TABLE') EXECUTE FUNCTION dbeer_schema_watch_v1.notify()")
	filtered := s.ObserveSchema(ctx, command)
	if filtered.SchemaObservation == nil || filtered.SchemaObservation.Installed || filtered.SchemaObservation.Complete || filtered.SchemaObservation.CanRemove || len(filtered.SchemaObservation.Notices) == 0 {
		t.Fatal("filtered notification trigger was accepted as the complete owned installation")
	}
	if _, err := f.conn.Exec(ctx, schemaObservationRemoveSQL); err == nil {
		t.Fatal("reviewed removal accepted an altered filtered trigger")
	}
	var filteredStillPresent bool
	if f.conn.QueryRow(ctx, "SELECT evttags IS NOT NULL FROM pg_catalog.pg_event_trigger WHERE evtname='dbeer_schema_watch_v1'").Scan(&filteredStillPresent) != nil || !filteredStillPresent {
		t.Fatal("refused removal changed the filtered installation")
	}
	f.exec("DROP EVENT TRIGGER dbeer_schema_watch_v1")
	f.exec("CREATE EVENT TRIGGER dbeer_schema_watch_v1 ON ddl_command_end EXECUTE FUNCTION dbeer_schema_watch_v1.notify()")
	command.SchemaObservation = &protocol.SchemaObservationRequest{Action: "previewRemove", Tables: []protocol.SchemaObservationTable{}}
	remove := s.ObserveSchema(ctx, command)
	if remove.SchemaObservation == nil || !remove.SchemaObservation.CanRemove || !remove.SchemaObservation.Valid() {
		t.Fatal("owned installation removal preview unavailable")
	}
	if _, err := f.conn.Exec(ctx, remove.SchemaObservation.SQL); err != nil {
		t.Fatal("reviewed isolated removal failed")
	}
	command.SchemaObservation = &protocol.SchemaObservationRequest{Action: "poll", Tables: []protocol.SchemaObservationTable{{Schema: f.schema, Name: "observed"}}}
	missing := s.ObserveSchema(ctx, command)
	if missing.SchemaObservation == nil || missing.SchemaObservation.Installed || missing.SchemaObservation.Complete || len(missing.SchemaObservation.Notices) == 0 {
		t.Fatal("removed installation was reported current")
	}
}
