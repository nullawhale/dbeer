package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5/pgconn"
)

// All queries are fixed adapter SQL. The monitor's dedicated connection is
// never used to execute or explain SQL supplied by the user.
const monitorSessionsSQL = `SELECT pid::text, usename::text, datname::text,
CASE WHEN client_addr IS NULL THEN NULL ELSE client_addr::text || ':' || client_port::text END,
application_name::text, state::text,
CASE WHEN query = '<insufficient privilege>' THEN NULL ELSE left(query,4097) END,
CASE WHEN state = 'active' AND query_start IS NOT NULL THEN
 floor(greatest(0,extract(epoch FROM (clock_timestamp()-query_start))*1000))::numeric::text END,
CASE WHEN xact_start IS NOT NULL THEN
 floor(greatest(0,extract(epoch FROM (clock_timestamp()-xact_start))*1000))::numeric::text END,
wait_event_type::text, wait_event::text
FROM pg_catalog.pg_stat_activity ORDER BY pid LIMIT 501`

// At most 500 calls to pg_blocking_pids are made. Unlike a pg_locks self-join,
// this includes soft blockers ahead in the queue and parallel-query leaders.
const monitorWaitsSQL = `SELECT DISTINCT waiting.pid::text, blocking.pid::text
FROM unnest($1::int4[]) AS waiting(pid)
CROSS JOIN LATERAL unnest(pg_catalog.pg_blocking_pids(waiting.pid)) AS blocking(pid)
ORDER BY waiting.pid::text, blocking.pid::text LIMIT 2001`

type monitorQuery func(context.Context, string, ...any) ([][]*string, error)

func (s *Session) MonitorSnapshot(ctx context.Context, command protocol.Command) protocol.Response {
	query := func(ctx context.Context, sql string, args ...any) ([][]*string, error) {
		rows, err := s.conn.Query(ctx, sql, args...)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		result := [][]*string{}
		for rows.Next() {
			values := rows.RawValues()
			row := make([]*string, len(values))
			for i, value := range values {
				if value != nil {
					text := string(value)
					row[i] = &text
				}
			}
			result = append(result, row)
		}
		return result, rows.Err()
	}
	snapshot, err := collectMonitorSnapshot(ctx, query, strconv.FormatUint(uint64(s.conn.PgConn().PID()), 10))
	if err != nil {
		response := queryError(command, ctx, s.conn, err)
		response.ErrorPosition = 0
		// Fixed monitoring reads cannot leave a write or COMMIT outcome unknown.
		response.OutcomeUnknown = false
		switch response.Category {
		case "cancelled":
			response.Message = "Monitoring was cancelled."
		case "timeout":
			response.Message = "Monitoring timed out."
		default:
			response.Message = "PostgreSQL monitoring information could not be collected."
		}
		if !response.Connected {
			response.Message += " Refresh explicitly to reconnect."
		}
		return response
	}
	return protocol.Response{Type: "monitor.result", RequestID: command.RequestID, SessionID: command.SessionID,
		QueryID: command.QueryID, Monitor: snapshot, Connected: !s.conn.IsClosed(), TransactionStatus: s.TransactionStatus()}
}

func collectMonitorSnapshot(ctx context.Context, query monitorQuery, ownID string) (*protocol.SessionMonitorSnapshot, error) {
	started := time.Now().UTC()
	snapshot := &protocol.SessionMonitorSnapshot{Engine: "postgresql", CollectionStartedAt: started.Format(time.RFC3339Nano),
		Sessions: []protocol.MonitoredSession{}, Waits: []protocol.MonitorWait{}, SessionsComplete: true, WaitsComplete: true,
		Notices: []string{"Sessions and waits are sampled separately and can change during collection.",
			"Visibility follows PostgreSQL permissions. Other users' details may require pg_read_all_stats.",
			"PostgreSQL can truncate query text at track_activity_query_size; complete SQL text is not guaranteed."}}
	finish := func() *protocol.SessionMonitorSnapshot {
		boundMonitorSnapshot(snapshot, started)
		return snapshot
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	rows, err := query(ctx, monitorSessionsSQL)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err != nil {
		if !monitorPermissionError(err) {
			return nil, err
		}
		snapshot.SessionsComplete, snapshot.WaitsComplete = false, false
		snapshot.Notices = append(snapshot.Notices, "Session activity and blocking relationships are unavailable with the current permissions.")
		return finish(), nil
	}
	if len(rows) > protocol.MaxMonitoredSessions {
		rows = rows[:protocol.MaxMonitoredSessions]
		snapshot.SessionsComplete, snapshot.WaitsComplete = false, false
		snapshot.Notices = append(snapshot.Notices, "Only the first 500 sessions and waits originating from those sessions are included.")
	}
	ids := make([]int32, 0, len(rows))
	seen := map[string]bool{}
	for _, row := range rows {
		item, limited, err := decodeMonitorSession(row, ownID)
		if err != nil || seen[item.ID] {
			return nil, errors.New("invalid PostgreSQL monitoring metadata")
		}
		seen[item.ID] = true
		id, _ := strconv.ParseInt(item.ID, 10, 32)
		ids = append(ids, int32(id))
		if item.State == nil || limited {
			snapshot.SessionsComplete = false
		}
		snapshot.Sessions = append(snapshot.Sessions, item)
	}
	if !snapshot.SessionsComplete {
		snapshot.Notices = append(snapshot.Notices, "Some session fields are hidden, truncated or limited; missing details are not inferred.")
	}
	if len(ids) == 0 {
		return finish(), nil
	}
	rows, err = query(ctx, monitorWaitsSQL, ids)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err != nil {
		if !monitorPermissionError(err) {
			return nil, err
		}
		snapshot.WaitsComplete = false
		snapshot.Notices = append(snapshot.Notices, "Blocking relationships are unavailable with the current permissions.")
		return finish(), nil
	}
	if len(rows) > protocol.MaxMonitorWaits {
		rows = rows[:protocol.MaxMonitorWaits]
		snapshot.WaitsComplete = false
		snapshot.Notices = append(snapshot.Notices, "Only the first 2,000 blocking relationships are included.")
	}
	seenWaits := map[[2]string]bool{}
	prepared := false
	for _, row := range rows {
		if len(row) != 2 || row[0] == nil || row[1] == nil || !protocol.ValidMonitorDecimal(*row[0]) || !protocol.ValidMonitorDecimal(*row[1]) {
			return nil, errors.New("invalid PostgreSQL blocking metadata")
		}
		key := [2]string{*row[0], *row[1]}
		if !seenWaits[key] {
			snapshot.Waits = append(snapshot.Waits, protocol.MonitorWait{WaitingID: key[0], BlockingID: key[1], Kind: "lock"})
			seenWaits[key] = true
		}
		prepared = prepared || key[1] == "0"
	}
	if prepared {
		snapshot.Notices = append(snapshot.Notices, "Blocking session 0 represents a prepared transaction, not a live backend.")
	}
	return finish(), nil
}

func decodeMonitorSession(row []*string, ownID string) (protocol.MonitoredSession, bool, error) {
	if len(row) != 11 || row[0] == nil || !protocol.ValidMonitorDecimal(*row[0]) {
		return protocol.MonitoredSession{}, false, errors.New("invalid session")
	}
	id, err := strconv.ParseInt(*row[0], 10, 32)
	if err != nil || id <= 0 {
		return protocol.MonitoredSession{}, false, errors.New("invalid backend")
	}
	for _, index := range []int{7, 8} {
		if row[index] != nil && !protocol.ValidMonitorDecimal(*row[index]) {
			return protocol.MonitoredSession{}, false, errors.New("invalid age")
		}
	}
	item := protocol.MonitoredSession{ID: *row[0], QueryAgeMs: row[7], TransactionAgeMs: row[8], IsMonitor: *row[0] == ownID}
	fields := []**string{&item.User, &item.Database, &item.Client, &item.Application, &item.State, &item.Query, &item.WaitType, &item.WaitEvent}
	limited := false
	for i, index := range []int{1, 2, 3, 4, 5, 6, 9, 10} {
		limit := protocol.MaxMonitorFieldBytes
		if index == 6 {
			limit = protocol.MaxMonitorQueryBytes
		}
		value, truncated := monitorText(row[index], limit)
		*fields[i] = value
		limited = limited || truncated
		if index == 6 {
			item.QueryTruncated = truncated
		}
	}
	if item.Query != nil && *item.Query == "<insufficient privilege>" {
		item.Query = nil
		limited = true
	}
	if item.State == nil || *item.State != "active" {
		item.QueryAgeMs = nil
	}
	return item, limited, nil
}

func monitorText(value *string, limit int) (*string, bool) {
	if value == nil {
		return nil, false
	}
	text := strings.ReplaceAll(strings.ToValidUTF8(*value, "�"), "\x00", "�")
	limited := text != *value || len(text) > limit
	if len(text) > limit {
		text = text[:limit]
		for !utf8.ValidString(text) {
			text = text[:len(text)-1]
		}
	}
	return &text, limited
}

func monitorPermissionError(err error) bool {
	var server *pgconn.PgError
	return errors.As(err, &server) && server.Code == "42501"
}

func boundMonitorSnapshot(snapshot *protocol.SessionMonitorSnapshot, started time.Time) {
	finished := time.Now().UTC()
	if finished.Before(started) {
		finished = started
	}
	snapshot.CollectedAt = finished.Format(time.RFC3339Nano)
	limited := false
	for {
		data, err := json.Marshal(snapshot)
		if err != nil || len(data) <= protocol.MaxSessionMonitorBytes {
			return
		}
		if !limited {
			snapshot.Notices = append(snapshot.Notices, "The snapshot exceeded its encoded size limit; some sessions or blocking relationships were omitted.")
			limited = true
		}
		if len(snapshot.Sessions) > 0 {
			snapshot.Sessions = snapshot.Sessions[:len(snapshot.Sessions)/2]
			snapshot.SessionsComplete = false
		} else if len(snapshot.Waits) > 0 {
			snapshot.Waits = snapshot.Waits[:len(snapshot.Waits)/2]
			snapshot.WaitsComplete = false
		} else {
			return
		}
	}
}
