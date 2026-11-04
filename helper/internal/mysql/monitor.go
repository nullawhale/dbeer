package mysql

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

const monitorEnabledSQL = `SELECT CAST(@@performance_schema AS CHAR)`

// TIME measures time in the current process state, not query execution time.
// Do not present it as query or transaction duration.
const monitorSessionsSQL = `SELECT CAST(ID AS CHAR), LEFT(USER,1025), LEFT(DB,1025), LEFT(HOST,1025),
COALESCE(NULLIF(LEFT(STATE,1025),''),LEFT(COMMAND,1025)), LEFT(INFO,4097)
FROM performance_schema.processlist ORDER BY ID LIMIT 501`

const monitorWaitsSQL = `SELECT CAST(requester.PROCESSLIST_ID AS CHAR), CAST(blocker.PROCESSLIST_ID AS CHAR),
LEFT(CONCAT(COALESCE(requested.OBJECT_SCHEMA,''),'.',requested.OBJECT_NAME),1025), LEFT(requested.LOCK_MODE,1025)
FROM performance_schema.data_lock_waits AS waits
LEFT JOIN performance_schema.threads AS requester ON requester.THREAD_ID=waits.REQUESTING_THREAD_ID
LEFT JOIN performance_schema.threads AS blocker ON blocker.THREAD_ID=waits.BLOCKING_THREAD_ID
LEFT JOIN performance_schema.data_locks AS requested
 ON requested.ENGINE=waits.ENGINE AND requested.ENGINE_LOCK_ID=waits.REQUESTING_ENGINE_LOCK_ID
ORDER BY waits.REQUESTING_THREAD_ID,waits.BLOCKING_THREAD_ID,waits.REQUESTING_ENGINE_LOCK_ID LIMIT 2001`

type monitorQuery func(context.Context, string) ([][]*string, error)

func (s *Session) MonitorSnapshot(ctx context.Context, command protocol.Command) protocol.Response {
	var snapshot *protocol.SessionMonitorSnapshot
	response := s.executeWith(ctx, command, func(_ *collector, _ *wire.Result) error {
		query := func(ctx context.Context, sql string) ([][]*string, error) {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			result, err := s.work.client.Execute(sql)
			if err != nil {
				return nil, err
			}
			defer result.Close()
			rows := make([][]*string, 0, result.RowNumber())
			for index := 0; index < result.RowNumber(); index++ {
				row := make([]*string, result.ColumnNumber())
				for column := 0; column < result.ColumnNumber(); column++ {
					isNull, err := result.IsNull(index, column)
					if err != nil {
						return nil, err
					}
					if !isNull {
						value, err := result.GetString(index, column)
						if err != nil {
							return nil, err
						}
						copy := strings.Clone(value)
						row[column] = &copy
					}
				}
				rows = append(rows, row)
			}
			return rows, nil
		}
		var err error
		snapshot, err = collectMonitorSnapshot(ctx, query, strconv.FormatUint(uint64(s.connectionID), 10))
		return err
	})
	if response.Type == "error" {
		response.ErrorPosition = 0
		// This boundary executes fixed observation queries only. Transport loss
		// cannot create an uncertain write or commit outcome for the monitor.
		response.OutcomeUnknown = false
		if response.Category == "connection" {
			response.Message = "The MySQL monitor connection was lost. Refresh to reconnect and collect a new observation."
			response.Connected, response.TransactionStatus = !s.closed.Load(), s.TransactionStatus()
		}
		if ctx.Err() != nil {
			response.Category, response.Message = "cancelled", "Monitoring was cancelled."
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				response.Category, response.Message = "timeout", "Monitoring timed out."
			}
		} else if response.Category == "sql" {
			response.Message = "MySQL monitoring information could not be collected."
		}
		return response
	}
	response.Type, response.Monitor = "monitor.result", snapshot
	// Ordinary query results omit Connected, but monitor.result explicitly
	// promises a reusable idle physical connection across the protocol boundary.
	response.Connected = !s.closed.Load()
	response.Columns, response.Rows, response.ResultSets = nil, nil, nil
	return response
}

func collectMonitorSnapshot(ctx context.Context, query monitorQuery, ownID string) (*protocol.SessionMonitorSnapshot, error) {
	started := time.Now().UTC()
	snapshot := &protocol.SessionMonitorSnapshot{Engine: "mysql", CollectionStartedAt: started.Format(time.RFC3339Nano),
		Sessions: []protocol.MonitoredSession{}, Waits: []protocol.MonitorWait{}, SessionsComplete: false, WaitsComplete: true,
		Notices: []string{"Sessions and waits are sampled separately and can change during collection.",
			"Server-wide session coverage is not verified. Visibility follows PROCESS privileges and Performance Schema thread instrumentation; other users may be hidden.",
			"Durations use active, timed Performance Schema events. Disabled, nested, detached XA or unavailable events remain blank; process state time is never used.",
			"MySQL can truncate statement text before collection; complete SQL text is not guaranteed."}}
	finish := func() *protocol.SessionMonitorSnapshot {
		boundMonitorSnapshot(snapshot, started)
		return snapshot
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	rows, err := query(ctx, monitorEnabledSQL)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err != nil {
		return nil, err
	}
	if len(rows) != 1 || len(rows[0]) != 1 || rows[0][0] == nil || (*rows[0][0] != "0" && *rows[0][0] != "1") {
		return nil, errors.New("invalid Performance Schema state")
	}
	if *rows[0][0] == "0" {
		snapshot.SessionsComplete, snapshot.WaitsComplete = false, false
		snapshot.Notices = append(snapshot.Notices, "Performance Schema is disabled; sessions and waits are unavailable.")
		return finish(), nil
	}
	rows, err = query(ctx, monitorTimedSessionsSQL)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	timed := err == nil
	if monitorUnavailableError(err) {
		snapshot.Notices = append(snapshot.Notices, "Event timing is unavailable with the current permissions or Performance Schema configuration. Basic session details are collected separately.")
		rows, err = query(ctx, monitorSessionsSQL)
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
	if err != nil {
		if !monitorUnavailableError(err) {
			return nil, err
		}
		snapshot.SessionsComplete = false
		snapshot.Notices = append(snapshot.Notices, "Session activity is unavailable with this server's permissions or Performance Schema configuration.")
		rows = nil
	}
	if len(rows) > protocol.MaxMonitoredSessions {
		rows = rows[:protocol.MaxMonitoredSessions]
		snapshot.SessionsComplete = false
		snapshot.Notices = append(snapshot.Notices, "Only the first 500 visible sessions are included.")
	}
	seen := map[string]bool{}
	ownSeen, limited := false, false
	for _, row := range rows {
		base := row
		if timed {
			if len(row) != 17 {
				return nil, errMonitorTiming
			}
			base = row[:6]
		}
		item, truncated, err := decodeMonitorSession(base, ownID)
		if err != nil || seen[item.ID] {
			return nil, errors.New("invalid MySQL monitoring metadata")
		}
		if timed {
			if err = applyMonitorTiming(&item, row); err != nil {
				return nil, err
			}
		}
		seen[item.ID] = true
		ownSeen = ownSeen || item.IsMonitor
		limited = limited || truncated
		snapshot.Sessions = append(snapshot.Sessions, item)
	}
	if !ownSeen {
		snapshot.SessionsComplete = false
		snapshot.Notices = append(snapshot.Notices, "The monitor connection is absent from the visible process list. Thread instrumentation, visibility or the session limit may omit connections.")
	}
	if limited {
		snapshot.SessionsComplete = false
		snapshot.Notices = append(snapshot.Notices, "Some session fields were truncated or contained unavailable text.")
	}
	dataWaits, dataComplete, dataNotices, err := collectMonitorDataWaits(ctx, query)
	if err != nil {
		return nil, err
	}
	snapshot.WaitsComplete = dataComplete
	snapshot.Notices = append(snapshot.Notices, dataNotices...)
	metadataWaits, pendingMetadata, metadataComplete, metadataNotices, err := collectMonitorMetadataWaits(ctx, query)
	if err != nil {
		return nil, err
	}
	snapshot.WaitsComplete = snapshot.WaitsComplete && metadataComplete
	snapshot.Notices = append(snapshot.Notices, metadataNotices...)
	if len(dataWaits)+len(metadataWaits) > protocol.MaxMonitorWaits {
		// Neither collector may consume the whole shared budget while the other
		// has evidence. Spare capacity is returned to the larger collection.
		dataCount := min(len(dataWaits), protocol.MaxMonitorWaits/2)
		metadataCount := min(len(metadataWaits), protocol.MaxMonitorWaits-dataCount)
		dataCount = min(len(dataWaits), protocol.MaxMonitorWaits-metadataCount)
		dataWaits, metadataWaits = dataWaits[:dataCount], metadataWaits[:metadataCount]
		snapshot.WaitsComplete = false
		snapshot.Notices = append(snapshot.Notices, "Only the first 2,000 combined data and metadata blocking relationships are included.")
	}
	snapshot.Waits = append(snapshot.Waits, dataWaits...)
	snapshot.Waits = append(snapshot.Waits, metadataWaits...)
	for index := range snapshot.Sessions {
		item := &snapshot.Sessions[index]
		state := ""
		if item.State != nil {
			state = strings.ToLower(*item.State)
		}
		if pendingMetadata[item.ID] || strings.HasPrefix(state, "waiting for ") && strings.Contains(state, "metadata lock") {
			kind, event := "metadata", "Metadata lock"
			item.WaitType, item.WaitEvent = &kind, &event
		}
	}
	return finish(), nil
}

func collectMonitorDataWaits(ctx context.Context, query monitorQuery) ([]protocol.MonitorWait, bool, []string, error) {
	waits, notices, complete := []protocol.MonitorWait{}, []string{}, true
	rows, err := query(ctx, monitorWaitsSQL)
	if ctx.Err() != nil {
		return nil, false, nil, ctx.Err()
	}
	if err != nil {
		if !monitorUnavailableError(err) {
			return nil, false, nil, err
		}
		return waits, false, []string{"InnoDB blocking relationships are unavailable. SELECT access to Performance Schema data_lock_waits, data_locks and threads is required."}, nil
	}
	if len(rows) > protocol.MaxMonitorWaits {
		rows = rows[:protocol.MaxMonitorWaits]
		complete = false
		notices = append(notices, "Only the first 2,000 InnoDB blocking relationships are included.")
	}
	missing, textLimited := false, false
	seenWaits := map[string]bool{}
	for _, row := range rows {
		if len(row) != 4 {
			return nil, false, nil, errors.New("invalid MySQL blocking metadata")
		}
		if row[0] == nil || row[1] == nil || *row[0] == "0" || *row[1] == "0" {
			missing = true
			continue
		}
		if !protocol.ValidMonitorDecimal(*row[0]) || !protocol.ValidMonitorDecimal(*row[1]) {
			return nil, false, nil, errors.New("invalid MySQL blocking identifier")
		}
		object, objectTruncated := monitorText(row[2], protocol.MaxMonitorFieldBytes)
		mode, modeTruncated := monitorText(row[3], protocol.MaxMonitorFieldBytes)
		textLimited = textLimited || objectTruncated || modeTruncated
		wait := protocol.MonitorWait{WaitingID: *row[0], BlockingID: *row[1], Kind: "data", Object: object, LockMode: mode}
		encoded, _ := json.Marshal(wait)
		if !seenWaits[string(encoded)] {
			waits = append(waits, wait)
			seenWaits[string(encoded)] = true
		}
	}
	if missing {
		complete = false
		notices = append(notices, "Some wait endpoints had no live connection identifier and were omitted; sessions may have ended during collection.")
	}
	if textLimited {
		complete = false
		notices = append(notices, "Some blocking object or lock-mode labels were truncated or contained unavailable text.")
	}
	return waits, complete, notices, nil
}

func decodeMonitorSession(row []*string, ownID string) (protocol.MonitoredSession, bool, error) {
	if len(row) != 6 || row[0] == nil || !protocol.ValidMonitorDecimal(*row[0]) || *row[0] == "0" {
		return protocol.MonitoredSession{}, false, errors.New("invalid session")
	}
	item := protocol.MonitoredSession{ID: *row[0], IsMonitor: *row[0] == ownID}
	fields := []**string{&item.User, &item.Database, &item.Client, &item.State, &item.Query}
	limited := false
	for i := 1; i < len(row); i++ {
		limit := protocol.MaxMonitorFieldBytes
		if i == 5 {
			limit = protocol.MaxMonitorQueryBytes
		}
		value, truncated := monitorText(row[i], limit)
		*fields[i-1] = value
		limited = limited || truncated
		if i == 5 {
			item.QueryTruncated = truncated
		}
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

func monitorUnavailableError(err error) bool {
	var server *wire.MyError
	if !errors.As(err, &server) {
		return false
	}
	switch server.Code {
	case 1044, 1045, 1142, 1146, 1227, 1370:
		return true
	}
	return false
}

func boundMonitorSnapshot(snapshot *protocol.SessionMonitorSnapshot, started time.Time) {
	seenNotices := map[string]bool{}
	notices := []string{}
	for _, notice := range snapshot.Notices {
		if !seenNotices[notice] {
			notices = append(notices, notice)
			seenNotices[notice] = true
		}
	}
	snapshot.Notices = notices
	// Keep a disclosure when multiple unavailable collectors exhaust the notice
	// budget, rather than dropping all data through protocol validation failure.
	if len(snapshot.Notices) > protocol.MaxMonitorNotices-1 {
		snapshot.Notices = append(snapshot.Notices[:protocol.MaxMonitorNotices-2], "Additional monitoring limitations were omitted from this bounded observation.")
	}
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
