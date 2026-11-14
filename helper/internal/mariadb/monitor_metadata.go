package mariadb

import (
	"context"
	"errors"

	"dbeer/helper/internal/protocol"
)

const mariaDBMonitorMetadataSQL = `SELECT CAST(requester.PROCESSLIST_ID AS CHAR), CAST(holder.PROCESSLIST_ID AS CHAR),
pending.OBJECT_TYPE, LEFT(pending.OBJECT_SCHEMA,1025), LEFT(pending.OBJECT_NAME,1025), pending.LOCK_TYPE, granted.LOCK_TYPE
FROM performance_schema.metadata_locks AS pending
LEFT JOIN performance_schema.metadata_locks AS granted
 ON granted.OBJECT_TYPE=pending.OBJECT_TYPE
 AND CAST(granted.OBJECT_SCHEMA AS BINARY) <=> CAST(pending.OBJECT_SCHEMA AS BINARY)
 AND CAST(granted.OBJECT_NAME AS BINARY) <=> CAST(pending.OBJECT_NAME AS BINARY)
 AND granted.LOCK_STATUS='GRANTED' AND granted.OWNER_THREAD_ID<>pending.OWNER_THREAD_ID
LEFT JOIN performance_schema.threads AS requester ON requester.THREAD_ID=pending.OWNER_THREAD_ID
LEFT JOIN performance_schema.threads AS holder ON holder.THREAD_ID=granted.OWNER_THREAD_ID
WHERE pending.LOCK_STATUS='PENDING'
ORDER BY pending.OWNER_THREAD_ID,pending.OBJECT_INSTANCE_BEGIN,granted.OWNER_THREAD_ID LIMIT 2001`

func collectMariaDBMetadataWaits(ctx context.Context, read func(string) ([][]*string, error), snapshot *protocol.SessionMonitorSnapshot) error {
	rows, err := read(`SELECT CAST(@@performance_schema AS CHAR)`)
	if err != nil {
		return err
	}
	if len(rows) != 1 || len(rows[0]) != 1 || rows[0][0] == nil {
		return errors.New("invalid native MariaDB instrumentation state")
	}
	state := *rows[0][0]
	if state != "0" && state != "1" && state != "OFF" && state != "ON" {
		return errors.New("invalid native MariaDB instrumentation state")
	}
	if state == "0" || state == "OFF" {
		snapshot.Notices = append(snapshot.Notices, "Performance Schema is disabled; metadata-lock observation is unavailable. InnoDB and process observations are independent.")
		return nil
	}
	rows, err = read(`SELECT ENABLED FROM performance_schema.setup_instruments WHERE NAME='wait/lock/metadata/sql/mdl'`)
	if err != nil && !mariaDBMonitorUnavailable(err) {
		return err
	}
	if err != nil || len(rows) == 0 {
		snapshot.Notices = append(snapshot.Notices, "Metadata-lock instrumentation could not be verified with the current access.")
		return nil
	}
	if len(rows) != 1 || len(rows[0]) != 1 || rows[0][0] == nil || *rows[0][0] != "YES" && *rows[0][0] != "NO" {
		return errors.New("invalid native MariaDB metadata instrumentation")
	}
	if *rows[0][0] == "NO" {
		snapshot.Notices = append(snapshot.Notices, "Metadata-lock instrumentation is disabled.")
		return nil
	}
	rows, err = read(mariaDBMonitorMetadataSQL)
	if err != nil && !mariaDBMonitorUnavailable(err) {
		return err
	}
	if err != nil {
		snapshot.Notices = append(snapshot.Notices, "Metadata lock/thread observation requires additional access.")
		return nil
	}
	if len(rows) > protocol.MaxMonitorWaits {
		rows = rows[:protocol.MaxMonitorWaits]
		snapshot.Notices = append(snapshot.Notices, "Only the first 2,000 metadata observations are included.")
	}
	for _, row := range rows {
		if err := ctx.Err(); err != nil {
			return err
		}
		if len(row) != 7 || row[2] == nil || row[5] == nil {
			return errors.New("invalid native MariaDB metadata-lock record")
		}
		if mariaDBMonitorID(row[0]) {
			for index := range snapshot.Sessions {
				if snapshot.Sessions[index].ID == *row[0] {
					kind, event := "metadata", "Metadata lock"
					snapshot.Sessions[index].WaitType, snapshot.Sessions[index].WaitEvent = &kind, &event
				}
			}
		}
		// MariaDB sql/mdl.cc's object-lock matrix proves EXCLUSIVE conflicts
		// with these granted table modes. Queue priority is not a pairwise edge.
		if *row[2] != "TABLE" || row[6] == nil || !mariaDBMetadataTableMode(*row[5]) || !mariaDBMetadataTableMode(*row[6]) || *row[5] != "EXCLUSIVE" && *row[6] != "EXCLUSIVE" || row[3] == nil || row[4] == nil {
			continue
		}
		if row[0] == nil || row[1] == nil || *row[0] == "0" || *row[1] == "0" {
			snapshot.Notices = append(snapshot.Notices, "A metadata owner had no visible physical connection identifier.")
			continue
		}
		if !mariaDBMonitorID(row[0]) || !mariaDBMonitorID(row[1]) {
			return errors.New("invalid native MariaDB metadata owner")
		}
		if *row[0] == *row[1] {
			continue
		}
		label := QuoteIdentifier(*row[3]) + "." + QuoteIdentifier(*row[4])
		object, _ := mariaDBMonitorText(&label, protocol.MaxMonitorFieldBytes)
		mode := *row[5] + " / " + *row[6]
		snapshot.Waits = append(snapshot.Waits, protocol.MonitorWait{WaitingID: *row[0], BlockingID: *row[1], Kind: "metadata", Object: object, LockMode: &mode})
	}
	return nil
}

func mariaDBMetadataTableMode(mode string) bool {
	switch mode {
	case "SHARED", "SHARED_HIGH_PRIO", "SHARED_READ", "SHARED_WRITE", "SHARED_UPGRADABLE", "SHARED_READ_ONLY", "SHARED_NO_WRITE", "SHARED_NO_READ_WRITE", "EXCLUSIVE":
		return true
	}
	return false
}
