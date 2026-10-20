package cassandra_test

import (
	"context"
	"strconv"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func liveChangesRequest(t *testing.T, s adapter.Session) protocol.ChangesRequest {
	t.Helper()
	snapshot := liveSQL(t, s, "SELECT * FROM dbeer.grid_cells WHERE tenant = 'one' AND id = 1")
	if len(snapshot.Rows) != 1 {
		t.Fatal("missing edit snapshot")
	}
	request := protocol.ChangesRequest{Schema: "dbeer", Table: "grid_cells", Changes: []protocol.RowChange{{Kind: "update"}}}
	for i, column := range snapshot.Columns {
		request.Columns = append(request.Columns, protocol.SnapshotColumn{Name: column.Name, Engine: "cassandra", NativeType: column.NativeType})
		value := protocol.CellValue{Kind: "null"}
		if snapshot.Rows[0][i] != nil {
			value.Kind, value.Value = "text", snapshot.Rows[0][i]
			if column.Encoding == "base64" {
				value.Kind = "binary"
			}
		}
		request.Changes[0].Original = append(request.Changes[0].Original, value)
	}
	return request
}

func liveChange(t *testing.T, s adapter.Session, request protocol.ChangesRequest, apply bool) protocol.Response {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	kind := "changes.preview"
	if apply {
		kind = "changes.apply"
	}
	return s.Execute(ctx, protocol.Command{Type: kind, RequestID: "grid", SessionID: "grid", QueryID: "grid", Changes: &request})
}

func TestCassandraLiveConditionalGridEdits(t *testing.T) {
	s := liveOpen(t, liveConnection(t))
	liveSQL(t, s, "CREATE TABLE IF NOT EXISTS dbeer.grid_cells (tenant text, id int, label text, absent text, exact decimal, payload blob, shared text static, PRIMARY KEY (tenant, id)) WITH default_time_to_live = 600")
	liveSQL(t, s, "INSERT INTO dbeer.grid_cells (tenant,id,label,exact,payload,shared) VALUES ('one',1,'original',9007199254740993.123456789,0x0001ff,'static') USING TTL 90")
	request := liveChangesRequest(t, s)
	empty := ""
	request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "label", Value: protocol.CellValue{Kind: "text", Value: &empty}}}
	preview := liveChange(t, s, request, false)
	if preview.Type != "query.result" || preview.CommandTag != "PREVIEW" {
		t.Fatalf("grid preview failed: %s", preview.Message)
	}
	before := liveSQL(t, s, "SELECT label FROM dbeer.grid_cells WHERE tenant='one' AND id=1")
	if v := liveValue(t, before, "label"); v == nil || *v != "original" {
		t.Fatal("preview wrote data")
	}
	applied := liveChange(t, s, request, true)
	if applied.Type != "query.result" || applied.CommandTag != "APPLY 1" || applied.RowCount != 1 || applied.AffectedRowCountKnown == nil || !*applied.AffectedRowCountKnown || applied.TransactionStatus != "unsupported" {
		t.Fatalf("conditional update failed: %s", applied.Message)
	}
	after := liveSQL(t, s, "SELECT label, exact, payload, TTL(label) AS lifetime FROM dbeer.grid_cells WHERE tenant='one' AND id=1")
	if v := liveValue(t, after, "label"); v == nil || *v != "" {
		t.Fatal("empty string became NULL")
	}
	if v := liveValue(t, after, "exact"); v == nil || *v != "9007199254740993.123456789" {
		t.Fatal("decimal precision lost")
	}
	if v := liveValue(t, after, "payload"); v == nil || *v != "AAH/" {
		t.Fatal("binary snapshot was corrupted")
	}
	if v := liveValue(t, after, "lifetime"); v == nil {
		t.Fatal("default TTL missing")
	} else if ttl, err := strconv.Atoi(*v); err != nil || ttl < 500 {
		t.Fatal("updated cell did not use table default TTL")
	}
	conflict := liveChange(t, s, request, true)
	if conflict.Type != "error" || conflict.Category != "conflict" || conflict.OutcomeUnknown {
		t.Fatal("stale edit was not rejected as a known conflict")
	}
	request = liveChangesRequest(t, s)
	literal, binary, decimal := "NULL", "", "9007199254740993.987654321"
	request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "absent", Value: protocol.CellValue{Kind: "text", Value: &literal}},
		{Column: "label", Value: protocol.CellValue{Kind: "null"}}, {Column: "payload", Value: protocol.CellValue{Kind: "binary", Value: &binary}},
		{Column: "exact", Value: protocol.CellValue{Kind: "text", Value: &decimal}}}
	if result := liveChange(t, s, request, true); result.Type != "query.result" {
		t.Fatalf("typed grid update failed: %s", result.Message)
	}
	after = liveSQL(t, s, "SELECT label, absent, exact, payload FROM dbeer.grid_cells WHERE tenant='one' AND id=1")
	if liveValue(t, after, "label") != nil {
		t.Fatal("NULL became text")
	}
	for column, want := range map[string]string{"absent": literal, "payload": binary, "exact": decimal} {
		if v := liveValue(t, after, column); v == nil || *v != want {
			t.Fatal("typed grid value did not round trip")
		}
	}
	request = liveChangesRequest(t, s)
	request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "absent", Value: protocol.CellValue{Kind: "text", Value: &empty}}}
	liveSQL(t, s, "DELETE FROM dbeer.grid_cells WHERE tenant='one' AND id=1")
	if result := liveChange(t, s, request, true); result.Category != "conflict" {
		t.Fatal("deleted row was resurrected")
	}
	// Deleting a clustered row leaves its partition's static value in place.
	// An all-null snapshot must still be rejected locally before a CAS can upsert.
	for i := range request.Changes[0].Original {
		if request.Columns[i].Name != "tenant" && request.Columns[i].Name != "id" && request.Columns[i].Name != "shared" {
			request.Changes[0].Original[i] = protocol.CellValue{Kind: "null"}
		}
	}
	if result := liveChange(t, s, request, true); result.Category != "validation" {
		t.Fatal("null-only original could recreate a deleted row")
	}
}

func TestCassandraLiveAtomicGridApply(t *testing.T) {
	s := liveOpen(t, liveConnection(t))
	liveSQL(t, s, "CREATE TABLE IF NOT EXISTS dbeer.grid_multi (tenant int, bucket int, id int, label text, marker text, amount int, shared text static, PRIMARY KEY ((tenant,bucket),id))")
	liveSQL(t, s, "INSERT INTO dbeer.grid_multi (tenant,bucket,id,label,marker,amount,shared) VALUES (1,1,1,'one','stable',1,'static'); INSERT INTO dbeer.grid_multi (tenant,bucket,id,label,marker,amount,shared) VALUES (1,1,2,'two','stable',1,'static'); INSERT INTO dbeer.grid_multi (tenant,bucket,id,label,marker,amount,shared) VALUES (2,1,1,'three','stable',1,'static')")
	request := protocol.ChangesRequest{Schema: "dbeer", Table: "grid_multi"}
	for _, predicate := range []string{"tenant=1 AND bucket=1 AND id=1", "tenant=1 AND bucket=1 AND id=2", "tenant=2 AND bucket=1 AND id=1"} {
		snapshot := liveSQL(t, s, "SELECT * FROM dbeer.grid_multi WHERE "+predicate)
		if len(snapshot.Rows) != 1 {
			t.Fatal("missing multi-row snapshot")
		}
		change := protocol.RowChange{Kind: "update"}
		for i, column := range snapshot.Columns {
			if len(request.Changes) == 0 {
				request.Columns = append(request.Columns, protocol.SnapshotColumn{Name: column.Name, Engine: "cassandra", NativeType: column.NativeType})
			}
			change.Original = append(change.Original, protocol.CellValue{Kind: "text", Value: snapshot.Rows[0][i]})
		}
		next := "updated-" + strconv.Itoa(len(request.Changes))
		change.Values = []protocol.ColumnAssignment{{Column: "label", Value: protocol.CellValue{Kind: "text", Value: &next}}}
		request.Changes = append(request.Changes, change)
	}
	for _, apply := range []bool{false, true} {
		rejected := liveChange(t, s, request, apply)
		if rejected.Type != "error" || rejected.Category != "validation" || rejected.OutcomeUnknown {
			t.Fatal("cross-partition atomic request was not rejected before execution")
		}
	}
	// Keep two rows of the same composite partition; one batch must guard both.
	request.Changes = request.Changes[:2]
	preview := liveChange(t, s, request, false)
	if preview.Type != "query.result" || len(preview.Rows) != 1 || preview.Rows[0][1] == nil || !strings.HasPrefix(*preview.Rows[0][1], "BEGIN BATCH") {
		t.Fatal("atomic preview did not expose the exact conditional batch")
	}
	invalid := request
	invalid.Changes = append([]protocol.RowChange(nil), request.Changes...)
	bad := "not-an-integer"
	invalid.Changes[1].Values = []protocol.ColumnAssignment{{Column: "amount", Value: protocol.CellValue{Kind: "text", Value: &bad}}}
	if result := liveChange(t, s, invalid, true); result.Category != "validation" || result.OutcomeUnknown || result.AppliedChangeCount == nil || *result.AppliedChangeCount != 0 {
		t.Fatal("invalid value did not reject the entire atomic batch")
	}
	liveSQL(t, s, "UPDATE dbeer.grid_multi SET marker='concurrent' WHERE tenant=1 AND bucket=1 AND id=2")
	conflict := liveChange(t, s, request, true)
	if conflict.Category != "conflict" || conflict.OutcomeUnknown || conflict.AppliedChangeCount == nil || *conflict.AppliedChangeCount != 0 {
		t.Fatalf("batch conflict did not reject every row: %s", conflict.Message)
	}
	for i, predicate := range []string{"tenant=1 AND bucket=1 AND id=1", "tenant=1 AND bucket=1 AND id=2", "tenant=2 AND bucket=1 AND id=1"} {
		row := liveSQL(t, s, "SELECT label FROM dbeer.grid_multi WHERE "+predicate)
		want := []string{"one", "two", "three"}[i]
		if value := liveValue(t, row, "label"); value == nil || *value != want {
			t.Fatal("rejected Apply changed a row")
		}
	}
	// Refresh the conflicted original value and apply both rows together.
	for i, column := range request.Columns {
		if column.Name == "marker" {
			text := "concurrent"
			request.Changes[1].Original[i] = protocol.CellValue{Kind: "text", Value: &text}
		}
	}
	result := liveChange(t, s, request, true)
	if result.Type != "query.result" || result.CommandTag != "APPLY 2" || result.AppliedChangeCount == nil || *result.AppliedChangeCount != 2 {
		t.Fatalf("atomic batch did not apply every row: %s", result.Message)
	}
	rows := liveSQL(t, s, "SELECT label FROM dbeer.grid_multi WHERE tenant=1 AND bucket=1")
	if len(rows.Rows) != 2 || rows.Rows[0][0] == nil || *rows.Rows[0][0] != "updated-0" || rows.Rows[1][0] == nil || *rows.Rows[1][0] != "updated-1" {
		t.Fatal("confirmed batch lost a row update")
	}
	// A deleted member must reject a valid edit to the other member as well.
	for i, column := range request.Columns {
		if column.Name == "label" {
			for j := range request.Changes {
				text := "updated-" + strconv.Itoa(j)
				request.Changes[j].Original[i] = protocol.CellValue{Kind: "text", Value: &text}
			}
		}
	}
	liveSQL(t, s, "DELETE FROM dbeer.grid_multi WHERE tenant=1 AND bucket=1 AND id=2")
	changed := "must-not-be-saved"
	request.Changes[0].Values[0].Value = protocol.CellValue{Kind: "text", Value: &changed}
	if result := liveChange(t, s, request, true); result.Category != "conflict" {
		t.Fatal("deleted batch member was not rejected")
	}
	unchanged := liveSQL(t, s, "SELECT label FROM dbeer.grid_multi WHERE tenant=1 AND bucket=1 AND id=1")
	if value := liveValue(t, unchanged, "label"); value == nil || *value != "updated-0" {
		t.Fatal("batch with deleted member saved another row")
	}
}
