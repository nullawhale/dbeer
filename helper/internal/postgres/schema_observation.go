package postgres

import (
	"context"
	"strconv"
	"time"

	"dbeer/helper/internal/protocol"
)

const schemaObservationBody = "BEGIN PERFORM pg_catalog.pg_notify('dbeer_schema_watch_v1', ''); END;"
const schemaObservationIdentitySQL = `SELECT
 EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname='dbeer_schema_watch_v1'),
 EXISTS (SELECT 1 FROM pg_catalog.pg_event_trigger e
 JOIN pg_catalog.pg_proc p ON p.oid=e.evtfoid
 JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
 WHERE e.evtname='dbeer_schema_watch_v1' AND e.evtevent='ddl_command_end' AND e.evtenabled IN ('O','A') AND e.evttags IS NULL
 AND n.nspname='dbeer_schema_watch_v1' AND p.proname='notify' AND p.pronargs=0
 AND p.prorettype='pg_catalog.event_trigger'::pg_catalog.regtype AND NOT p.prosecdef
 AND p.prosrc=$1::text AND pg_catalog.obj_description(n.oid,'pg_namespace')='DBeer schema observation v1'),
 (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname=current_user)`

// Installation is transactional and refuses existing names. The application
// opens this exact text in an ordinary SQL editor for explicit review and Run.
const schemaObservationInstallSQL = `BEGIN;
CREATE SCHEMA dbeer_schema_watch_v1;
COMMENT ON SCHEMA dbeer_schema_watch_v1 IS 'DBeer schema observation v1';
CREATE FUNCTION dbeer_schema_watch_v1.notify() RETURNS event_trigger LANGUAGE plpgsql AS $dbeer$BEGIN PERFORM pg_catalog.pg_notify('dbeer_schema_watch_v1', ''); END;$dbeer$;
CREATE EVENT TRIGGER dbeer_schema_watch_v1 ON ddl_command_end EXECUTE FUNCTION dbeer_schema_watch_v1.notify();
COMMIT;`

const schemaObservationRemoveSQL = `DO $dbeer$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_event_trigger e
 JOIN pg_catalog.pg_proc p ON p.oid=e.evtfoid JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
 WHERE e.evtname='dbeer_schema_watch_v1' AND e.evtevent='ddl_command_end' AND e.evttags IS NULL
 AND n.nspname='dbeer_schema_watch_v1' AND p.proname='notify' AND p.pronargs=0
 AND p.prorettype='pg_catalog.event_trigger'::pg_catalog.regtype AND NOT p.prosecdef
 AND p.prosrc='BEGIN PERFORM pg_catalog.pg_notify(''dbeer_schema_watch_v1'', ''''); END;'
 AND pg_catalog.obj_description(n.oid,'pg_namespace')='DBeer schema observation v1')
 THEN RAISE EXCEPTION 'The DBeer schema observation installation changed. Inspect it before removal.'; END IF;
 DROP EVENT TRIGGER dbeer_schema_watch_v1;
 DROP FUNCTION dbeer_schema_watch_v1.notify();
 DROP SCHEMA dbeer_schema_watch_v1;
END$dbeer$;`

func (s *Session) ObserveSchema(ctx context.Context, command protocol.Command) protocol.Response {
	if s.schemaObservationRevision == nil {
		r := protocol.ErrorResponse(command, "policy", "Open a dedicated monitor connection before observing schema changes.")
		r.Connected, r.TransactionStatus = !s.conn.IsClosed(), s.TransactionStatus()
		return r
	}
	r := protocol.SchemaObservation{Engine: "postgresql", Action: command.SchemaObservation.Action, Tables: command.SchemaObservation.Tables, Mode: "notifications", ObservedAt: time.Now().UTC().Format(time.RFC3339Nano), Complete: true, Notices: []string{}}
	var exists, owned, superuser bool
	if err := s.conn.QueryRow(ctx, schemaObservationIdentitySQL, schemaObservationBody).Scan(&exists, &owned, &superuser); err != nil {
		return schemaObservationError(command, ctx, s, err)
	}
	r.Installed, r.CanInstall, r.CanRemove = owned, superuser && !exists, superuser && owned
	if r.Action == "previewInstall" {
		r.SQL = schemaObservationInstallSQL
		return schemaObservationReply(command, r, !s.conn.IsClosed(), s.TransactionStatus())
	}
	if r.Action == "previewRemove" {
		r.SQL = schemaObservationRemoveSQL
		return schemaObservationReply(command, r, !s.conn.IsClosed(), s.TransactionStatus())
	}
	if !owned {
		r.Complete = false
		r.Notices = append(r.Notices, "Install the reviewed PostgreSQL notification objects before enabling observation. Installation requires a superuser.")
		if exists {
			r.Notices = append(r.Notices, "The observation schema already exists but its expected installation could not be verified. Inspect it explicitly.")
		}
	} else {
		if !s.schemaObservationListening {
			if _, err := s.conn.Exec(ctx, "LISTEN dbeer_schema_watch_v1"); err != nil {
				return schemaObservationError(command, ctx, s, err)
			}
			s.schemaObservationListening = true
		}
		// The fixed metadata query above drains notifications through pgx's
		// callback before ReadyForQuery. Idle polls never wait on the socket.

	}
	r.Revision = strconv.FormatUint(s.schemaObservationRevision.Load(), 10)
	r.ObservedAt = time.Now().UTC().Format(time.RFC3339Nano)
	return schemaObservationReply(command, r, !s.conn.IsClosed(), s.TransactionStatus())
}

func schemaObservationReply(c protocol.Command, r protocol.SchemaObservation, connected bool, tx string) protocol.Response {
	return protocol.Response{Type: "monitor.schema.result", RequestID: c.RequestID, SessionID: c.SessionID, QueryID: c.QueryID, SchemaObservation: &r, Connected: connected, TransactionStatus: tx}
}
func schemaObservationError(c protocol.Command, ctx context.Context, s *Session, err error) protocol.Response {
	r := queryError(c, ctx, s.conn, err)
	r.Message = "PostgreSQL schema observation failed. Enable it explicitly after checking connection and permissions."
	r.ErrorPosition = 0
	r.OutcomeUnknown = false
	return r
}
