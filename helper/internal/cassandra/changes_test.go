package cassandra

import (
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func changeFixture() (protocol.ChangesRequest, []tableColumn) {
	columns := []tableColumn{{name: "pk", nativeType: "text", kind: "partition_key"}, {name: "ck", nativeType: "int", kind: "clustering"},
		{name: "label", nativeType: "text", kind: "regular"}, {name: "binary", nativeType: "blob", kind: "regular"}, {name: "absent", nativeType: "text", kind: "regular"}}
	value := func(kind, text string) protocol.CellValue { return protocol.CellValue{Kind: kind, Value: &text} }
	request := protocol.ChangesRequest{Schema: `work"space`, Table: "items", Changes: []protocol.RowChange{{Kind: "update",
		Original: []protocol.CellValue{value("text", "tenant"), value("text", "1"), value("text", "original"), value("binary", "AAH/"), {Kind: "null"}},
		Values:   []protocol.ColumnAssignment{{Column: "label", Value: value("text", "'; DROP TABLE items; --")}}}}}
	for _, column := range columns {
		request.Columns = append(request.Columns, protocol.SnapshotColumn{Name: column.name, NativeType: column.nativeType, Engine: "cassandra"})
	}
	return request, columns
}

func TestCassandraChangePlanBindsValuesAndChecksFullOriginal(t *testing.T) {
	request, columns := changeFixture()
	// Snapshot order need not match key-first catalog order.
	request.Columns[0], request.Columns[4] = request.Columns[4], request.Columns[0]
	request.Changes[0].Original[0], request.Changes[0].Original[4] = request.Changes[0].Original[4], request.Changes[0].Original[0]
	plan, reason := planChange(request, columns)
	if reason != "" {
		t.Fatal(reason)
	}
	want := `UPDATE "work""space"."items" SET "label" = ? WHERE "ck" = ? AND "pk" = ? IF "absent" = ? AND "label" = ? AND "binary" = ?`
	if plan.sql != want || len(plan.parameters) != 6 || plan.parameters[0] != request.Changes[0].Values[0].Value || plan.parameters[3].Kind != "null" || plan.parameters[5].Kind != "binary" {
		t.Fatal("conditional plan lost quoting, binding, snapshot order or typed values")
	}
}

func TestCassandraChangePlanRejectsUnsafeRequests(t *testing.T) {
	for name, mutate := range map[string]func(*protocol.ChangesRequest, *[]tableColumn){
		"multiple rows": func(r *protocol.ChangesRequest, _ *[]tableColumn) { r.Changes = append(r.Changes, r.Changes[0]) },
		"insert": func(r *protocol.ChangesRequest, _ *[]tableColumn) {
			r.Changes[0].Kind = "insert"
			r.Changes[0].Original = nil
		},
		"delete": func(r *protocol.ChangesRequest, _ *[]tableColumn) {
			r.Changes[0].Kind = "delete"
			r.Changes[0].Values = nil
		},
		"key assignment":    func(r *protocol.ChangesRequest, _ *[]tableColumn) { r.Changes[0].Values[0].Column = "pk" },
		"static assignment": func(_ *protocol.ChangesRequest, c *[]tableColumn) { (*c)[2].kind = "static" },
		"default": func(r *protocol.ChangesRequest, _ *[]tableColumn) {
			r.Changes[0].Values[0].Value = protocol.CellValue{Kind: "default"}
		},
		"missing key": func(r *protocol.ChangesRequest, _ *[]tableColumn) {
			r.Changes[0].Original[1] = protocol.CellValue{Kind: "null"}
		},
		"null-only row": func(r *protocol.ChangesRequest, _ *[]tableColumn) {
			for i := 2; i < 5; i++ {
				r.Changes[0].Original[i] = protocol.CellValue{Kind: "null"}
			}
		},
		"stale columns":      func(r *protocol.ChangesRequest, _ *[]tableColumn) { r.Columns = r.Columns[:4] },
		"stale type":         func(r *protocol.ChangesRequest, _ *[]tableColumn) { r.Columns[2].NativeType = "int" },
		"other engine":       func(r *protocol.ChangesRequest, _ *[]tableColumn) { r.Columns[0].Engine = "postgresql" },
		"blob as text":       func(r *protocol.ChangesRequest, _ *[]tableColumn) { r.Changes[0].Original[3].Kind = "text" },
		"text as blob":       func(r *protocol.ChangesRequest, _ *[]tableColumn) { r.Changes[0].Original[2].Kind = "binary" },
		"unknown assignment": func(r *protocol.ChangesRequest, _ *[]tableColumn) { r.Changes[0].Values[0].Column = "missing" },
		"complex type":       func(_ *protocol.ChangesRequest, c *[]tableColumn) { (*c)[3].nativeType = "list<int>" },
		"counter":            func(_ *protocol.ChangesRequest, c *[]tableColumn) { (*c)[3].nativeType = "counter" },
		"duration":           func(_ *protocol.ChangesRequest, c *[]tableColumn) { (*c)[3].nativeType = "duration" },
	} {
		t.Run(name, func(t *testing.T) {
			request, columns := changeFixture()
			mutate(&request, &columns)
			if _, reason := planChange(request, columns); reason == "" {
				t.Fatal("unsafe changes accepted")
			}
		})
	}
}

func TestCassandraEditableColumnsHaveSpecificReasons(t *testing.T) {
	_, columns := changeFixture()
	for _, column := range columns {
		reason := editColumnReason(columns, column)
		if (reason == "") != (column.kind == "regular") {
			t.Fatal("keys became editable or scalar values became read only")
		}
	}
	columns[2].nativeType = "frozen<map<text, int>>"
	for _, column := range columns {
		if !strings.Contains(editColumnReason(columns, column), "scalar") {
			t.Fatal("unsupported snapshot type lacks a reason")
		}
	}
}

func TestCassandraAtomicPlansValidateEveryRowAndPartition(t *testing.T) {
	request, columns := changeFixture()
	second := request.Changes[0]
	second.Original = append([]protocol.CellValue(nil), second.Original...)
	clustering := "2"
	second.Original[1] = protocol.CellValue{Kind: "text", Value: &clustering}
	request.Changes = append(request.Changes, second)
	plans, reason := planChanges(request, columns)
	if reason != "" || len(plans) != 2 {
		t.Fatal("same-partition rows were not planned together")
	}
	batch := atomicChangePlan(plans)
	if !strings.HasPrefix(batch.sql, "BEGIN BATCH\n") || !strings.HasSuffix(batch.sql, "APPLY BATCH") || strings.Count(batch.sql, "UPDATE ") != 2 || len(batch.parameters) != 12 {
		t.Fatal("preview did not contain the complete conditional batch")
	}
	other := "other-partition"
	request.Changes[1].Original[0] = protocol.CellValue{Kind: "text", Value: &other}
	if plans, reason := planChanges(request, columns); plans != nil || !strings.Contains(reason, "partition") {
		t.Fatal("cross-partition atomic Apply was allowed")
	}
	request.Changes[1].Original[0] = request.Changes[0].Original[0]
	request.Changes[1].Original[1] = protocol.CellValue{Kind: "null"}
	if plans, reason := planChanges(request, columns); plans != nil || reason == "" {
		t.Fatal("a valid prefix escaped validation when a later row was invalid")
	}
}

func TestCassandraAtomicKeysUseNativeSerializationAndRejectDuplicateRows(t *testing.T) {
	request, columns := changeFixture()
	columns[0].nativeType, request.Columns[0].NativeType = "int", "int"
	one, padded, two := "1", "01", "2"
	request.Changes[0].Original[0] = protocol.CellValue{Kind: "text", Value: &one}
	second := request.Changes[0]
	second.Original = append([]protocol.CellValue(nil), second.Original...)
	second.Original[0] = protocol.CellValue{Kind: "text", Value: &padded}
	second.Original[1] = protocol.CellValue{Kind: "text", Value: &two}
	request.Changes = append(request.Changes, second)
	if plans, reason := planChanges(request, columns); reason != "" || len(plans) != 2 {
		t.Fatal("equivalent native partition keys were treated as different partitions")
	}
	request.Changes[1].Original[1] = protocol.CellValue{Kind: "text", Value: &padded}
	if plans, reason := planChanges(request, columns); plans != nil || !strings.Contains(reason, "more than once") {
		t.Fatal("duplicate serialized primary keys were allowed")
	}
}

func TestCassandraAtomicCompositeKeysPreserveEveryComponentBoundary(t *testing.T) {
	request, columns := changeFixture()
	columns = append(columns, tableColumn{name: "bucket", nativeType: "text", kind: "partition_key", position: 1})
	request.Columns = append(request.Columns, protocol.SnapshotColumn{Name: "bucket", NativeType: "text", Engine: "cassandra"})
	ab, c, a, bc, two := "ab", "c", "a", "bc", "2"
	request.Changes[0].Original[0] = protocol.CellValue{Kind: "text", Value: &ab}
	request.Changes[0].Original = append(request.Changes[0].Original, protocol.CellValue{Kind: "text", Value: &c})
	second := request.Changes[0]
	second.Original = append([]protocol.CellValue(nil), second.Original...)
	second.Original[0] = protocol.CellValue{Kind: "text", Value: &a}
	second.Original[1] = protocol.CellValue{Kind: "text", Value: &two}
	second.Original[5] = protocol.CellValue{Kind: "text", Value: &bc}
	request.Changes = append(request.Changes, second)
	if plans, reason := planChanges(request, columns); plans != nil || !strings.Contains(reason, "partition") {
		t.Fatal("composite key component boundaries were ignored")
	}
	request.Changes[1].Original[0] = request.Changes[0].Original[0]
	if plans, reason := planChanges(request, columns); plans != nil || !strings.Contains(reason, "partition") {
		t.Fatal("only the first partition key component was checked")
	}
}

func TestCassandraAtomicApplyExecutesOnceAndHasNoConfirmedPrefix(t *testing.T) {
	for _, category := range []string{"conflict", "cancelled", "timeout", "validation"} {
		t.Run(category, func(t *testing.T) {
			calls := 0
			result := executeAtomicChangePlans(make([]changePlan, 4), func(changePlan) protocol.Response {
				calls++
				return protocol.Response{Type: "error", Category: category, Message: "Stopped.", OutcomeUnknown: category == "timeout"}
			})
			if calls != 1 || result.Category != category || result.OutcomeUnknown != (category == "timeout") {
				t.Fatal("atomic Apply split or retried a batch, or lost its error")
			}
			if category == "timeout" {
				if result.AppliedChangeCount != nil {
					t.Fatal("unknown batch invented an applied count")
				}
			} else if result.AppliedChangeCount == nil || *result.AppliedChangeCount != 0 {
				t.Fatal("known atomic rejection reported saved rows")
			}
		})
	}
	result := executeAtomicChangePlans(make([]changePlan, 3), func(changePlan) protocol.Response {
		return protocol.Response{Type: "query.result", TransactionStatus: "unsupported"}
	})
	if result.CommandTag != "APPLY 3" || result.RowCount != 3 || result.AppliedChangeCount == nil || *result.AppliedChangeCount != 3 || result.AffectedRowCountKnown == nil || !*result.AffectedRowCountKnown {
		t.Fatal("successful Apply lost its exact row count")
	}
}
