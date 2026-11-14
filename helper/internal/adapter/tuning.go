package adapter

import (
	"context"
	"dbeer/helper/internal/protocol"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
)

// Fixed PostgreSQL tuning SQL is kept at the adapter boundary. Callers must
// retain current-owner policy and exact review before executing the SET preview.
func PostgresTuningSettingPreview(r protocol.TuningSettingRequest) *protocol.TuningSettingPreview {
	return &protocol.TuningSettingPreview{SQL: fmt.Sprintf("SET LOCAL work_mem = '%dkB'", r.ValueKiB), RestoreSQL: fmt.Sprintf("SET LOCAL work_mem = '%dkB'", r.ExpectedValueKiB), Scope: "currentTransaction", Risks: []string{"Applies only in the current existing transaction; COMMIT/ROLLBACK ends it and rollback to an earlier savepoint may revert it.", "work_mem is per sort/hash operation and worker, not a query memory cap. Higher values can increase total memory use.", "Restore is a separate exact reviewed operation. A lost acknowledgement is unknown; no automatic restore or replay occurs."}}
}
func ReadPostgresTuningWorkMem(ctx context.Context, physical Session, c protocol.Command) (int, error) {
	c.Type = "execute"
	c.SQL = "SHOW work_mem"
	c.Parameters = nil
	c.Authorization = ""
	c.Explain = nil
	c.TuningInspect = nil
	c.TuningValidation = nil
	c.TuningSetting = nil
	c.TuningSettingObservation = nil
	r := physical.Execute(ctx, c)
	if r.Type != "query.result" || len(r.Rows) != 1 || len(r.Rows[0]) != 1 || r.Rows[0][0] == nil {
		return 0, errors.New("Current work_mem could not be read.")
	}
	m := regexp.MustCompile(`^([0-9]+)(kB|MB|GB)$`).FindStringSubmatch(*r.Rows[0][0])
	if m == nil {
		return 0, errors.New("Current work_mem unit is unsupported.")
	}
	n, e := strconv.Atoi(m[1])
	if e != nil {
		return 0, e
	}
	if m[2] == "MB" {
		n *= 1024
	}
	if m[2] == "GB" {
		n *= 1024 * 1024
	}
	if n < 64 || n > 1048576 {
		return 0, errors.New("Current work_mem is outside supported tuning bounds.")
	}
	return n, nil
}

func PostgresTuningSearchPathSafe(ctx context.Context, physical Session, c protocol.Command) bool {
	c = protocol.Command{Type: "execute", RequestID: c.RequestID, SessionID: c.SessionID, QueryID: c.QueryID, SQL: "SELECT pg_catalog.array_to_json(pg_catalog.current_schemas(true))::pg_catalog.text"}
	r := physical.Execute(ctx, c)
	if r.Type != "query.result" || len(r.Rows) != 1 || len(r.Rows[0]) != 1 || r.Rows[0][0] == nil {
		return false
	}
	var schemas []string
	return json.Unmarshal([]byte(*r.Rows[0][0]), &schemas) == nil && len(schemas) > 0 && schemas[0] == "pg_catalog"
}

// Tuning metadata inherits E2's minimum version, not the older Explain floor.
func TuningEngineSupported(s protocol.ExplainSupport) bool {
	return s.Valid() && len(s.Modes) > 0 && (s.Engine == "postgresql" || s.Engine == "mariadb" && mariaDBTuningVersion(s.ServerVersion) || s.Engine == "mysql" && oracleExplainVersion.MatchString(s.ServerVersion) && mysqlVersionAtLeast(s.ServerVersion, 8, 0, 30))
}

func mariaDBTuningVersion(version string) bool {
	match := regexp.MustCompile(`^(10\.11|11\.4)\.([0-9]+)-MariaDB(?:[-+].*)?$`).FindStringSubmatch(version)
	if match == nil {
		return false
	}
	patch, err := strconv.Atoi(match[2])
	if err != nil {
		return false
	}
	return match[1] == "10.11" && patch >= 9 || match[1] == "11.4" && patch >= 3
}
