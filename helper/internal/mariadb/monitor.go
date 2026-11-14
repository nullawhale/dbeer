package mariadb

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

// MariaDB TIME_MS measures the current COMMAND, independently of @TIMESTAMP.
// Sleep and background-command ages are not statement execution durations.
const mariaDBMonitorSessionsSQL = `SELECT CAST(ID AS CHAR), LEFT(USER,1025), LEFT(DB,1025), LEFT(HOST,1025),
COALESCE(NULLIF(LEFT(STATE,1025),''),LEFT(COMMAND,1025)), LEFT(INFO,4097),
CASE WHEN COMMAND IN ('Query','Execute') AND INFO IS NOT NULL THEN CAST(FLOOR(TIME_MS) AS CHAR) ELSE NULL END
FROM information_schema.PROCESSLIST ORDER BY ID LIMIT 501`

const mariaDBMonitorTransactionsSQL = `SELECT CAST(TRX_MYSQL_THREAD_ID AS CHAR),
CAST(TIMESTAMPDIFF(MICROSECOND,TRX_STARTED,SYSDATE(6)) DIV 1000 AS CHAR)
FROM information_schema.INNODB_TRX ORDER BY TRX_MYSQL_THREAD_ID LIMIT 501`

const mariaDBMonitorDataWaitsSQL = `SELECT CAST(requester.TRX_MYSQL_THREAD_ID AS CHAR), CAST(blocker.TRX_MYSQL_THREAD_ID AS CHAR),
LEFT(requested.LOCK_TABLE,1025), LEFT(requested.LOCK_MODE,1025)
FROM information_schema.INNODB_LOCK_WAITS AS waits
LEFT JOIN information_schema.INNODB_TRX AS requester ON requester.TRX_ID=waits.REQUESTING_TRX_ID
LEFT JOIN information_schema.INNODB_TRX AS blocker ON blocker.TRX_ID=waits.BLOCKING_TRX_ID
LEFT JOIN information_schema.INNODB_LOCKS AS requested ON requested.LOCK_ID=waits.REQUESTED_LOCK_ID
ORDER BY waits.REQUESTING_TRX_ID,waits.BLOCKING_TRX_ID,waits.REQUESTED_LOCK_ID LIMIT 2001`

type mariaDBMonitorQuery func(context.Context, string) ([][]*string, error)

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
				for column := range row {
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
		snapshot, err = collectMariaDBMonitor(ctx, query, strconv.FormatUint(uint64(s.connectionID), 10))
		return err
	})
	if response.Type == "error" {
		response.ErrorPosition, response.OutcomeUnknown = 0, false
		if ctx.Err() != nil {
			response.Category, response.Message = "cancelled", "Monitoring was cancelled."
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				response.Category, response.Message = "timeout", "Monitoring timed out."
			}
		} else if response.Category == "sql" {
			response.Message = "MariaDB monitoring information could not be collected."
		} else if response.Category == "connection" {
			response.Message = "The MariaDB monitor connection was lost. Refresh to collect a new observation."
		}
		return response
	}
	response.Type, response.Monitor, response.Connected = "monitor.result", snapshot, !s.closed.Load()
	response.Columns, response.Rows, response.ResultSets = nil, nil, nil
	return response
}

func collectMariaDBMonitor(ctx context.Context, query mariaDBMonitorQuery, ownID string) (*protocol.SessionMonitorSnapshot, error) {
	started := time.Now().UTC()
	snapshot := &protocol.SessionMonitorSnapshot{Engine: "mariadb", CollectionStartedAt: started.Format(time.RFC3339Nano),
		Sessions: []protocol.MonitoredSession{}, Waits: []protocol.MonitorWait{}, Notices: []string{
			"Sessions, transaction ages and waits are separate observations and can change during collection. InnoDB metadata can retain a cached observation.",
			"Server-wide session visibility is not verified; PROCESS privileges can hide other users. Native statement text can already be truncated.",
			"Query ages measure the current Query/Execute command. Transaction ages cover visible InnoDB transactions only; XA and unavailable durations stay blank.",
			"Metadata edges include confirmed EXCLUSIVE table-lock conflicts only. Queue-priority, other metadata modes and storage-engine waits are not inferred."}}
	read := func(sql string) ([][]*string, error) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		rows, err := query(ctx, sql)
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return rows, err
	}
	rows, err := read(mariaDBMonitorSessionsSQL)
	if err != nil {
		if !mariaDBMonitorUnavailable(err) {
			return nil, err
		}
		snapshot.Notices = append(snapshot.Notices, "Session details are unavailable with the current permissions.")
	}
	if len(rows) > protocol.MaxMonitoredSessions {
		rows = rows[:protocol.MaxMonitoredSessions]
		snapshot.Notices = append(snapshot.Notices, "Only the first 500 visible sessions are included.")
	}
	seen := map[string]int{}
	for _, row := range rows {
		if len(row) != 7 || row[0] == nil {
			return nil, errors.New("invalid native MariaDB process metadata")
		}
		if *row[0] == "0" {
			snapshot.Notices = append(snapshot.Notices, "A background thread without a physical connection identifier was omitted.")
			continue
		}
		if !mariaDBMonitorID(row[0]) {
			return nil, errors.New("invalid native MariaDB process identifier")
		}
		id := *row[0]
		if _, exists := seen[id]; exists {
			return nil, errors.New("duplicate native MariaDB process identifier")
		}
		item := protocol.MonitoredSession{ID: id, IsMonitor: id == ownID}
		for i, field := range []**string{&item.User, &item.Database, &item.Client, &item.State, &item.Query} {
			limit := protocol.MaxMonitorFieldBytes
			if i == 4 {
				limit = protocol.MaxMonitorQueryBytes
			}
			value, limited := mariaDBMonitorText(row[i+1], limit)
			*field = value
			if i == 4 {
				item.QueryTruncated = limited
			}
			if limited {
				snapshot.Notices = append(snapshot.Notices, "Some visible fields were limited or contained unavailable text.")
			}
		}
		if row[6] != nil {
			if !protocol.ValidMonitorDecimal(*row[6]) {
				return nil, errors.New("invalid native MariaDB command duration")
			}
			item.QueryAgeMs = row[6]
		}
		seen[id] = len(snapshot.Sessions)
		snapshot.Sessions = append(snapshot.Sessions, item)
	}
	if _, exists := seen[ownID]; !exists {
		snapshot.Notices = append(snapshot.Notices, "The monitor connection is absent from the visible process list.")
	}
	rows, err = read(mariaDBMonitorTransactionsSQL)
	if err != nil && !mariaDBMonitorUnavailable(err) {
		return nil, err
	}
	if err != nil {
		snapshot.Notices = append(snapshot.Notices, "InnoDB transaction ages require additional access and remain unavailable.")
	}
	if len(rows) > protocol.MaxMonitoredSessions {
		rows = rows[:protocol.MaxMonitoredSessions]
		snapshot.Notices = append(snapshot.Notices, "Only the first 500 visible InnoDB transaction ages are included.")
	}
	transactionIDs := map[string]bool{}
	for _, row := range rows {
		if len(row) != 2 || row[0] == nil {
			return nil, errors.New("invalid native MariaDB transaction metadata")
		}
		if *row[0] == "0" {
			snapshot.Notices = append(snapshot.Notices, "An internal InnoDB transaction had no physical connection identifier and was omitted.")
			continue
		}
		if !mariaDBMonitorID(row[0]) || row[1] == nil || !protocol.ValidMonitorDecimal(*row[1]) || transactionIDs[*row[0]] {
			return nil, errors.New("invalid native MariaDB transaction metadata")
		}
		transactionIDs[*row[0]] = true
		if index, exists := seen[*row[0]]; exists {
			snapshot.Sessions[index].TransactionAgeMs = row[1]
		}
	}
	rows, err = read(mariaDBMonitorDataWaitsSQL)
	if err != nil && !mariaDBMonitorUnavailable(err) {
		return nil, err
	}
	if err != nil {
		snapshot.Notices = append(snapshot.Notices, "InnoDB blocking relationships require additional access and remain unavailable.")
	}
	if len(rows) > protocol.MaxMonitorWaits {
		rows = rows[:protocol.MaxMonitorWaits]
		snapshot.Notices = append(snapshot.Notices, "Only the first 2,000 InnoDB blocking observations are included.")
	}
	for _, row := range rows {
		if len(row) != 4 {
			return nil, errors.New("invalid native MariaDB wait metadata")
		}
		if row[0] == nil || row[1] == nil || *row[0] == "0" || *row[1] == "0" {
			snapshot.Notices = append(snapshot.Notices, "A changing InnoDB wait had no visible owner and was omitted.")
			continue
		}
		if !mariaDBMonitorID(row[0]) || !mariaDBMonitorID(row[1]) || *row[0] == *row[1] {
			return nil, errors.New("invalid native MariaDB blocking identifier")
		}
		object, _ := mariaDBMonitorText(row[2], protocol.MaxMonitorFieldBytes)
		mode, _ := mariaDBMonitorText(row[3], protocol.MaxMonitorFieldBytes)
		snapshot.Waits = append(snapshot.Waits, protocol.MonitorWait{WaitingID: *row[0], BlockingID: *row[1], Kind: "data", Object: object, LockMode: mode})
		if index, exists := seen[*row[0]]; exists {
			kind, event := "data", "InnoDB lock"
			snapshot.Sessions[index].WaitType, snapshot.Sessions[index].WaitEvent = &kind, &event
		}
	}
	if err := collectMariaDBMetadataWaits(ctx, read, snapshot); err != nil {
		return nil, err
	}
	boundMariaDBMonitor(snapshot, started)
	return snapshot, nil
}

func mariaDBMonitorID(value *string) bool {
	if value == nil || !protocol.ValidMonitorDecimal(*value) || *value == "0" {
		return false
	}
	_, err := strconv.ParseUint(*value, 10, 64)
	return err == nil
}

func mariaDBMonitorUnavailable(err error) bool {
	var server *wire.MyError
	if errors.As(err, &server) {
		switch server.Code {
		case 1044, 1045, 1109, 1142, 1146, 1227, 1370:
			return true
		}
	}
	return false
}

func mariaDBMonitorText(value *string, limit int) (*string, bool) {
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

func boundMariaDBMonitor(snapshot *protocol.SessionMonitorSnapshot, started time.Time) {
	if len(snapshot.Waits) > protocol.MaxMonitorWaits {
		// Keep both collectors visible under the one shared relationship budget.
		data, metadata := []protocol.MonitorWait{}, []protocol.MonitorWait{}
		for _, wait := range snapshot.Waits {
			if wait.Kind == "data" {
				data = append(data, wait)
			} else {
				metadata = append(metadata, wait)
			}
		}
		n := min(len(data), protocol.MaxMonitorWaits/2)
		m := min(len(metadata), protocol.MaxMonitorWaits-n)
		n = min(len(data), protocol.MaxMonitorWaits-m)
		snapshot.Waits = append(data[:n], metadata[:m]...)
		snapshot.Notices = append(snapshot.Notices, "Only the first 2,000 combined InnoDB and metadata relationships are included.")
	}
	seen := map[string]bool{}
	notices := []string{}
	for _, text := range snapshot.Notices {
		if !seen[text] && len(notices) < protocol.MaxMonitorNotices-1 {
			notices = append(notices, text)
			seen[text] = true
		}
	}
	if len(seen) >= protocol.MaxMonitorNotices-1 {
		notices = append(notices, "Additional monitoring limitations were omitted from this bounded observation.")
	}
	snapshot.Notices = notices
	finished := time.Now().UTC()
	if finished.Before(started) {
		finished = started
	}
	snapshot.CollectedAt = finished.Format(time.RFC3339Nano)
	edges := map[string]bool{}
	waits := []protocol.MonitorWait{}
	for _, wait := range snapshot.Waits {
		raw, _ := json.Marshal(wait)
		if !edges[string(raw)] && len(waits) < protocol.MaxMonitorWaits {
			edges[string(raw)] = true
			waits = append(waits, wait)
		}
	}
	snapshot.Waits = waits
	for {
		raw, err := json.Marshal(snapshot)
		if err != nil || len(raw) <= protocol.MaxSessionMonitorBytes {
			return
		}
		if len(snapshot.Notices) < protocol.MaxMonitorNotices {
			snapshot.Notices = append(snapshot.Notices, "Encoded-size limits omitted some visible sessions or waits.")
		}
		if len(snapshot.Sessions) > 0 {
			snapshot.Sessions = snapshot.Sessions[:len(snapshot.Sessions)/2]
		} else if len(snapshot.Waits) > 0 {
			snapshot.Waits = snapshot.Waits[:len(snapshot.Waits)/2]
		} else {
			return
		}
	}
}
