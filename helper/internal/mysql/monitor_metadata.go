package mysql

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"

	"dbeer/helper/internal/protocol"
)

const monitorMetadataInstrumentSQL = `SELECT ENABLED FROM performance_schema.setup_instruments
WHERE NAME='wait/lock/metadata/sql/mdl'`

const monitorMetadataLostSQL = `SELECT VARIABLE_VALUE FROM performance_schema.global_status
WHERE VARIABLE_NAME='Performance_schema_metadata_lock_lost'`

// Match object names as bytes: metadata names on a case-sensitive server must
// not be merged by a case-insensitive Performance Schema column collation.
// Pending requests with no holder are retained so unresolved waits remain
// distinguishable from a complete empty observation.
const monitorMetadataWaitsSQL = `SELECT CAST(requester.PROCESSLIST_ID AS CHAR),
CAST(holder.PROCESSLIST_ID AS CHAR), pending.OBJECT_TYPE,
LEFT(pending.OBJECT_SCHEMA,1025), LEFT(pending.OBJECT_NAME,1025),
pending.LOCK_TYPE, granted.LOCK_TYPE
FROM performance_schema.metadata_locks AS pending
LEFT JOIN performance_schema.metadata_locks AS granted
 ON granted.OBJECT_TYPE=pending.OBJECT_TYPE
 AND CAST(granted.OBJECT_SCHEMA AS BINARY) <=> CAST(pending.OBJECT_SCHEMA AS BINARY)
 AND CAST(granted.OBJECT_NAME AS BINARY) <=> CAST(pending.OBJECT_NAME AS BINARY)
 AND granted.LOCK_STATUS='GRANTED'
 AND granted.OWNER_THREAD_ID<>pending.OWNER_THREAD_ID
LEFT JOIN performance_schema.threads AS requester ON requester.THREAD_ID=pending.OWNER_THREAD_ID
LEFT JOIN performance_schema.threads AS holder ON holder.THREAD_ID=granted.OWNER_THREAD_ID
WHERE pending.LOCK_STATUS='PENDING'
ORDER BY (pending.LOCK_TYPE='EXCLUSIVE') DESC,pending.OWNER_THREAD_ID,
pending.OBJECT_INSTANCE_BEGIN,granted.OWNER_THREAD_ID LIMIT 2001`

// Performance Schema exposes metadata requests and holders, but not the lock
// manager's queue-priority state. Do not label every same-object holder a
// blocker. For supported MySQL 8.0/8.4 TABLE modes, EXCLUSIVE conflicts with
// every other mode. Collect only those proven granted-holder relationships.
// See the granted-lock compatibility facts in mysql/mysql-server sql/mdl.cc.
func collectMonitorMetadataWaits(ctx context.Context, query monitorQuery) ([]protocol.MonitorWait, map[string]bool, bool, []string, error) {
	waits := []protocol.MonitorWait{}
	pending := map[string]bool{}
	complete := true
	notices := []string{"Metadata relationships include confirmed EXCLUSIVE table-lock conflicts only; queue-priority dependencies are not inferred."}
	limitations := []string{}
	mark := func(reason string) {
		complete = false
		for _, existing := range limitations {
			if existing == reason {
				return
			}
		}
		limitations = append(limitations, reason)
	}
	finish := func() ([]protocol.MonitorWait, map[string]bool, bool, []string, error) {
		if len(limitations) > 0 {
			notices = append(notices, "Metadata observation is partial: "+strings.Join(limitations, "; ")+".")
		}
		return waits, pending, complete, notices, nil
	}
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
	rows, err := read(monitorMetadataInstrumentSQL)
	if err != nil {
		if !monitorUnavailableError(err) {
			return nil, nil, false, nil, err
		}
		mark("instrumentation could not be verified")
	} else if len(rows) == 0 {
		mark("instrumentation is unavailable")
	} else if len(rows) != 1 || len(rows[0]) != 1 || rows[0][0] == nil || (*rows[0][0] != "YES" && *rows[0][0] != "NO") {
		return nil, nil, false, nil, errors.New("invalid metadata instrumentation state")
	} else if *rows[0][0] == "NO" {
		mark("metadata-lock instrumentation is disabled")
		return finish()
	}
	rows, err = read(monitorMetadataLostSQL)
	if err != nil {
		if !monitorUnavailableError(err) {
			return nil, nil, false, nil, err
		}
		mark("lost-lock accounting could not be verified")
	} else if len(rows) == 0 {
		mark("lost-lock accounting is unavailable")
	} else if len(rows) != 1 || len(rows[0]) != 1 || rows[0][0] == nil || !protocol.ValidMonitorDecimal(*rows[0][0]) {
		return nil, nil, false, nil, errors.New("invalid metadata lost-lock accounting")
	} else if lost, parseErr := strconv.ParseUint(*rows[0][0], 10, 64); parseErr != nil {
		return nil, nil, false, nil, errors.New("invalid metadata lost-lock accounting")
	} else if lost > 0 {
		mark("the server reports lost metadata-lock records")
	}
	rows, err = read(monitorMetadataWaitsSQL)
	if err != nil {
		if !monitorUnavailableError(err) {
			return nil, nil, false, nil, err
		}
		mark("SELECT access to metadata_locks and threads is unavailable")
		return finish()
	}
	if len(rows) > protocol.MaxMonitorWaits {
		rows = rows[:protocol.MaxMonitorWaits]
		mark("only the first 2,000 metadata observations are included")
	}
	if len(rows) > 0 {
		mark("queue-priority blockers are unavailable")
	}
	seen := map[string]bool{}
	for _, row := range rows {
		if len(row) != 7 || row[2] == nil || row[5] == nil {
			return nil, nil, false, nil, errors.New("invalid metadata-lock observation")
		}
		if row[0] == nil || *row[0] == "0" {
			mark("some waiting requests have no visible connection identifier")
		} else if !protocol.ValidMonitorDecimal(*row[0]) {
			return nil, nil, false, nil, errors.New("invalid metadata connection identifier")
		} else {
			pending[*row[0]] = true
		}
		if *row[2] != "TABLE" {
			mark("non-table metadata requests are not resolved")
			continue
		}
		if row[6] == nil || !monitorMetadataTableMode(*row[5]) || !monitorMetadataTableMode(*row[6]) {
			mark("some requests have no supported granted holder")
			continue
		}
		if *row[5] != "EXCLUSIVE" && *row[6] != "EXCLUSIVE" {
			mark("other lock-mode conflicts are not resolved")
			continue
		}
		if row[0] == nil || row[1] == nil || *row[0] == "0" || *row[1] == "0" {
			mark("some lock owners have no visible connection identifier")
			continue
		}
		if !protocol.ValidMonitorDecimal(*row[0]) || !protocol.ValidMonitorDecimal(*row[1]) {
			return nil, nil, false, nil, errors.New("invalid metadata connection identifier")
		}
		if *row[0] == *row[1] {
			mark("an inconsistent same-session observation was omitted")
			continue
		}
		if row[3] == nil || row[4] == nil {
			mark("some table names are unavailable")
			continue
		}
		label := QuoteIdentifier(*row[3]) + "." + QuoteIdentifier(*row[4])
		object, limited := monitorText(&label, protocol.MaxMonitorFieldBytes)
		if limited {
			mark("some object labels were limited")
		}
		mode := *row[5] + " / " + *row[6]
		wait := protocol.MonitorWait{WaitingID: *row[0], BlockingID: *row[1], Kind: "metadata", Object: object, LockMode: &mode}
		encoded, _ := json.Marshal(wait)
		if !seen[string(encoded)] {
			waits = append(waits, wait)
			seen[string(encoded)] = true
		}
	}
	return finish()
}

func monitorMetadataTableMode(mode string) bool {
	switch mode {
	case "SHARED", "SHARED_HIGH_PRIO", "SHARED_READ", "SHARED_WRITE", "SHARED_WRITE_LOW_PRIO", "SHARED_UPGRADABLE", "SHARED_READ_ONLY", "SHARED_NO_WRITE", "SHARED_NO_READ_WRITE", "EXCLUSIVE":
		return true
	}
	return false
}
