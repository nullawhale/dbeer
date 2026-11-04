package mysql

import (
	"errors"
	"strconv"
	"strings"

	"dbeer/helper/internal/protocol"
)

var errMonitorTiming = errors.New("invalid MySQL event timing metadata")

// Current-event tables retain completed events and can retain stale rows when
// consumers are disabled. Check the event lifecycle and its live instrumentation
// before using TIMER_WAIT. The fixed SELECT observes text and timing together.
const monitorTimedSessionsSQL = `SELECT CAST(p.ID AS CHAR), LEFT(p.USER,1025), LEFT(p.DB,1025), LEFT(p.HOST,1025),
COALESCE(NULLIF(LEFT(p.STATE,1025),''),LEFT(p.COMMAND,1025)), LEFT(p.INFO,4097), p.COMMAND,
CAST(COALESCE(t.INSTRUMENTED='YES' AND si.ENABLED='YES' AND si.TIMED='YES'
 AND consumers.global_enabled=1 AND consumers.thread_enabled=1 AND consumers.statement_enabled=1,0) AS CHAR),
CAST(statement_event.END_EVENT_ID AS CHAR), CAST(statement_event.TIMER_WAIT AS CHAR),
statement_event.NESTING_EVENT_TYPE, LEFT(statement_event.SQL_TEXT,4097),
CAST(COALESCE(t.INSTRUMENTED='YES' AND ti.ENABLED='YES' AND ti.TIMED='YES'
 AND consumers.global_enabled=1 AND consumers.thread_enabled=1 AND consumers.transaction_enabled=1,0) AS CHAR),
CAST(transaction_event.END_EVENT_ID AS CHAR), transaction_event.STATE,
CAST(transaction_event.TIMER_WAIT AS CHAR), transaction_event.XA_STATE
FROM (SELECT ID,USER,DB,HOST,STATE,COMMAND,INFO FROM performance_schema.processlist ORDER BY ID LIMIT 501) AS p
LEFT JOIN performance_schema.threads AS t ON t.PROCESSLIST_ID=p.ID
LEFT JOIN performance_schema.events_statements_current AS statement_event ON statement_event.THREAD_ID=t.THREAD_ID
LEFT JOIN performance_schema.setup_instruments AS si ON si.NAME=statement_event.EVENT_NAME
LEFT JOIN performance_schema.events_transactions_current AS transaction_event ON transaction_event.THREAD_ID=t.THREAD_ID
LEFT JOIN performance_schema.setup_instruments AS ti ON ti.NAME=transaction_event.EVENT_NAME
CROSS JOIN (SELECT
 MAX(NAME='global_instrumentation' AND ENABLED='YES') AS global_enabled,
 MAX(NAME='thread_instrumentation' AND ENABLED='YES') AS thread_enabled,
 MAX(NAME='events_statements_current' AND ENABLED='YES') AS statement_enabled,
 MAX(NAME='events_transactions_current' AND ENABLED='YES') AS transaction_enabled
 FROM performance_schema.setup_consumers
 WHERE NAME IN ('global_instrumentation','thread_instrumentation','events_statements_current','events_transactions_current')) AS consumers
ORDER BY p.ID`

// Performance Schema reports unsigned picoseconds. Integer division preserves
// exact millisecond floors even beyond the precision of binary64 numbers.
func monitorPicosecondsToMilliseconds(value *string) (*string, error) {
	if value == nil {
		return nil, nil
	}
	if !protocol.ValidMonitorDecimal(*value) {
		return nil, errMonitorTiming
	}
	ps, err := strconv.ParseUint(*value, 10, 64)
	if err != nil {
		return nil, errMonitorTiming
	}
	ms := strconv.FormatUint(ps/1_000_000_000, 10)
	return &ms, nil
}

func applyMonitorTiming(item *protocol.MonitoredSession, row []*string) error {
	item.QueryAgeMs, item.TransactionAgeMs = nil, nil
	if len(row) != 17 || row[7] == nil || row[12] == nil ||
		(*row[7] != "0" && *row[7] != "1") || (*row[12] != "0" && *row[12] != "1") {
		return errMonitorTiming
	}
	// Nested statement duration is not necessarily the duration of the outer
	// SQL shown by the process list. Completed/idle and mismatched rows stay nil.
	if *row[7] == "1" && row[8] == nil && row[6] != nil && (*row[6] == "Query" || *row[6] == "Execute") &&
		(row[10] == nil || *row[10] != "STATEMENT") && row[5] != nil && row[11] != nil && *row[11] != "" &&
		strings.HasPrefix(*row[5], *row[11]) {
		age, err := monitorPicosecondsToMilliseconds(row[9])
		if err != nil {
			return err
		}
		item.QueryAgeMs = age
	}
	// XA events can remain attached to the originating thread after a prepared
	// transaction is detached; exclude them rather than inventing a live owner.
	if *row[12] == "1" && row[13] == nil && row[14] != nil && *row[14] == "ACTIVE" && row[16] == nil {
		age, err := monitorPicosecondsToMilliseconds(row[15])
		if err != nil {
			return err
		}
		item.TransactionAgeMs = age
	}
	return nil
}
