package cassandra

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"dbeer/helper/internal/protocol"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

// Apply is one conditional operation in one partition. Multi-row updates use
// a single conditional batch; requests spanning partitions fail before writing.
// Complex/counter/duration tables remain read-only until lossless CAS binding
// and comparison are supported for their complete row snapshots.
func editScalarType(native string) bool {
	return browseScalarType(native) && native != "counter" && native != "duration"
}

func editTableReason(columns []tableColumn) string {
	for _, column := range columns {
		if !editScalarType(column.nativeType) {
			return "Cassandra grid editing requires scalar columns and keys; counters, durations and complex types require explicit CQL."
		}
	}
	return ""
}

func editColumnReason(columns []tableColumn, column tableColumn) string {
	if reason := editTableReason(columns); reason != "" {
		return reason
	}
	if column.kind != "regular" {
		return "Cassandra primary keys and static columns are read only in the grid."
	}
	return ""
}

type changePlan struct {
	sql        string
	parameters []protocol.CellValue
	partition  string
	rowKey     string
}

func planChange(request protocol.ChangesRequest, columns []tableColumn) (changePlan, string) {
	invalid := func(message string) (changePlan, string) { return changePlan{}, message }
	if !request.Valid() || len(request.Changes) != 1 || request.Changes[0].Kind != "update" {
		return invalid("Cassandra grid editing supports updates to existing rows. Insert and delete require explicit CQL.")
	}
	if reason := editTableReason(columns); reason != "" {
		return invalid(reason)
	}
	if len(request.Columns) != len(columns) {
		return invalid("The table structure changed. Reload data before editing.")
	}
	byName := make(map[string]tableColumn, len(columns))
	for _, column := range columns {
		byName[column.name] = column
	}
	// SELECT * order is defined by Cassandra, not the catalog's key-first order.
	ordered := make([]tableColumn, len(request.Columns))
	for i, snapshot := range request.Columns {
		column, ok := byName[snapshot.Name]
		if !ok || snapshot.Engine != "cassandra" || snapshot.NativeType != column.nativeType {
			return invalid("The table structure or native types changed. Reload data before editing.")
		}
		ordered[i] = column
	}
	change := request.Changes[0]
	plan := changePlan{}
	var updates, keys, conditions []string
	for _, assignment := range change.Values {
		column := byName[assignment.Column]
		if editColumnReason(columns, column) != "" || !editCellValid(assignment.Value, column) {
			return invalid("Cassandra assignments require an editable scalar value or NULL. Primary keys, static columns and DEFAULT are not editable.")
		}
		updates = append(updates, quoteIdentifier(column.name)+" = ?")
		plan.parameters = append(plan.parameters, assignment.Value)
	}
	var keyValues, originalValues []protocol.CellValue
	partitionKeys, nonNullRegular := 0, false
	for i, column := range ordered {
		value := change.Original[i]
		if !editCellValid(value, column) {
			return invalid("An original value does not match its native type. Reload data before editing.")
		}
		if column.kind == "partition_key" || column.kind == "clustering" {
			if value.Kind == "null" {
				return invalid("A complete original primary key is required. Static-only rows cannot be edited.")
			}
			if column.kind == "partition_key" {
				partitionKeys++
			}
			keys = append(keys, quoteIdentifier(column.name)+" = ?")
			keyValues = append(keyValues, value)
		} else {
			conditions = append(conditions, quoteIdentifier(column.name)+" = ?")
			originalValues = append(originalValues, value)
			nonNullRegular = nonNullRegular || column.kind == "regular" && value.Kind != "null"
		}
	}
	// A predicate whose regular values are all null also matches a deleted row.
	// Never accidentally resurrect a row that disappeared since browsing.
	if partitionKeys == 0 || !nonNullRegular {
		return invalid("Conditional editing requires a complete primary key and at least one non-NULL original regular value. Use explicit CQL for this row.")
	}
	plan.sql = "UPDATE " + qualified(request.Schema, request.Table) + " SET " + strings.Join(updates, ", ") + " WHERE " + strings.Join(keys, " AND ") + " IF " + strings.Join(conditions, " AND ")
	plan.parameters = append(plan.parameters, keyValues...)
	plan.parameters = append(plan.parameters, originalValues...)
	// Compare the actual serialized keys, not their displayed text (e.g. 01 and
	// 1 are the same int key). Length-delimited JSON byte arrays also preserve
	// the boundaries of composite key components without ambiguous concatenation.
	var partition, primary [][]byte
	original := make(map[string]protocol.CellValue, len(ordered))
	for i, column := range ordered {
		original[column.name] = change.Original[i]
	}
	for _, column := range columns {
		if column.kind != "partition_key" && column.kind != "clustering" {
			continue
		}
		value := original[column.name]
		info := gocql.NewNativeType(5, gocql.TypeCustom, column.nativeType)
		encoded, err := (textParameter{Value: *value.Value}).MarshalCQL(info)
		if err != nil {
			return invalid("An original primary-key value is invalid for its native type. Reload data before editing.")
		}
		primary = append(primary, encoded)
		if column.kind == "partition_key" {
			partition = append(partition, encoded)
		}
	}
	encodedPartition, _ := json.Marshal(partition)
	encodedPrimary, _ := json.Marshal(primary)
	plan.partition, plan.rowKey = string(encodedPartition), string(encodedPrimary)
	return plan, ""
}

func planChanges(request protocol.ChangesRequest, columns []tableColumn) ([]changePlan, string) {
	if !request.Valid() {
		return nil, "Invalid Cassandra changes request."
	}
	plans := make([]changePlan, 0, len(request.Changes))
	seen := make(map[string]bool)
	parameters := 0
	for _, change := range request.Changes {
		one := request
		one.Changes = []protocol.RowChange{change}
		plan, reason := planChange(one, columns)
		if reason != "" {
			return nil, reason
		}
		if len(plans) > 0 && plans[0].partition != plan.partition {
			return nil, "Atomic Cassandra Apply requires every edited row to have the same complete partition key. Rows from different partitions cannot be saved together. No changes were applied."
		}
		if seen[plan.rowKey] {
			return nil, "The same primary key occurs more than once. Reload data before applying changes."
		}
		seen[plan.rowKey] = true
		parameters += len(plan.parameters)
		if parameters > 65535 {
			return nil, "The atomic batch exceeds the parameter limit. Apply fewer rows. No changes were applied."
		}
		plans = append(plans, plan)
	}
	return plans, ""
}

func atomicChangePlan(plans []changePlan) changePlan {
	if len(plans) == 1 {
		return plans[0]
	}
	plan := changePlan{}
	var sql strings.Builder
	sql.WriteString("BEGIN BATCH\n")
	for _, row := range plans {
		sql.WriteString(row.sql)
		sql.WriteString(";\n")
		plan.parameters = append(plan.parameters, row.parameters...)
	}
	sql.WriteString("APPLY BATCH")
	plan.sql = sql.String()
	return plan
}

func editCellValid(value protocol.CellValue, column tableColumn) bool {
	if !value.Valid(false) {
		return false
	}
	return value.Kind == "null" || value.Kind == "binary" && column.nativeType == "blob" || value.Kind == "text" && column.nativeType != "blob"
}

func (s *Session) changes(ctx context.Context, command protocol.Command) protocol.Response {
	if command.Type != "changes.preview" && command.Type != "changes.apply" {
		return s.failure(command, "protocol", "Invalid Cassandra changes operation.")
	}
	request := *command.Changes
	if !request.Valid() {
		return s.failure(command, "validation", "Invalid Cassandra changes request.")
	}
	// system_schema.columns also describes views. Check the base table separately
	// on every preview/apply; client metadata is never authoritative.
	tables, failure := s.metadata(ctx, command, "SELECT table_name FROM system_schema.tables WHERE keyspace_name = ? AND table_name = ?", request.Schema, request.Table)
	if failure != nil {
		return *failure
	}
	if len(tables) != 1 {
		return s.failure(command, "validation", "Cassandra grid editing requires an available base table. Views are read only.")
	}
	columns, failure := s.tableColumns(ctx, command, request.Schema, request.Table)
	if failure != nil {
		return *failure
	}
	plans, reason := planChanges(request, columns)
	if reason != "" {
		return s.failure(command, "validation", reason)
	}
	// Preview and execute the exact same conditional batch, never a sequence of
	// independently committed updates. Bound the entire preview before writing.
	plan := atomicChangePlan(plans)
	preview := s.response(command)
	preview.Columns = stringsResult(command, []string{"operation", "sql", "parameters"}, nil).Columns
	encoded, _ := json.Marshal(plan.parameters)
	preview.Rows = [][]*string{cells("atomic update", plan.sql, string(encoded))}
	preview.CommandTag = "PREVIEW"
	preview.RowCount, preview.DisplayedRowCount = 1, 1
	data, _ := json.Marshal(preview)
	if len(data) > maxBytes {
		return s.failure(command, "validation", "The preview exceeds the display limit. Reduce the edited values or row count.")
	}
	if command.Type == "changes.preview" {
		return preview
	}
	return executeAtomicChangePlans(plans, func(plan changePlan) protocol.Response {
		values := make([]any, len(plan.parameters))
		for i, value := range plan.parameters {
			if value.Kind != "null" {
				values[i] = textParameter{Value: *value.Value}
			}
		}
		if ctx.Err() != nil {
			return safeError(command, ctx, ctx.Err(), true, false)
		}
		observer := &attemptObserver{}
		query := ConfigureQuery(s.driver.Query(plan.sql, values...), s.keyspace).NoSkipMetadata().Observer(observer)
		applied, err := query.MapScanCASContext(ctx, make(map[string]any))
		// Never retry an uncertain conditional batch. A lost acknowledgement
		// concerns the entire batch; there is no confirmed prefix to resubmit.
		s.cursors = make(map[string]browseCursor)
		if err != nil {
			return safeError(command, ctx, err, true, observer.sent.Load())
		}
		if !applied {
			return s.failure(command, "conflict", "At least one row changed or was deleted since it was loaded. The entire atomic Apply was rejected; no row changes were applied. Review the data before editing again.")
		}
		return s.response(command)
	})
}

// Execute once: a known rejection applies zero rows, a confirmed success
// applies all rows, and a lost result leaves the whole batch outcome unknown.
func executeAtomicChangePlans(plans []changePlan, execute func(changePlan) protocol.Response) protocol.Response {
	response := execute(atomicChangePlan(plans))
	if response.Type == "error" {
		if !response.OutcomeUnknown {
			zero := 0
			response.AppliedChangeCount = &zero
		}
		return response
	}
	count := len(plans)
	response.AppliedChangeCount = &count
	known := true
	response.AffectedRowCountKnown = &known
	response.CommandTag, response.RowCount = fmt.Sprintf("APPLY %d", count), int64(count)
	return response
}
