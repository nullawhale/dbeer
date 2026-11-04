package sqlite

import (
	"context"
	"fmt"
	"math"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/syncplan"
	tc "dbeer/helper/internal/tablecapture"
)

func realGuardValue(f float64) protocol.SQLiteValue {
	return protocol.SQLiteValue{Type: "real", Value: fmt.Sprintf("%016x", math.Float64bits(f))}
}

func realGuardOperation(t *testing.T, kind string, value protocol.SQLiteValue) syncplan.DataOperation {
	t.Helper()
	op := syncRealOperation(t, kind, syncRealCell(t, "text", "Y2hhbmdlZA=="), syncRealCell(t, value.Type, value.Value))
	// Even an excluded source column remains an exact target-original guard.
	op.Descriptor.Columns = append(op.Descriptor.Columns, tc.Column{Index: 2, Name: "note", NativeType: "TEXT"})
	op.Target = append(op.Target, syncRealCell(t, "text", "Y2FwdHVyZWQ="))
	return op
}

func TestSQLiteSynchronizationNonzeroRealOriginals(t *testing.T) {
	for _, c := range []struct {
		name string
		f    float64
	}{
		{"one", 1}, {"negative_one", -1}, {"fraction", .1},
		{"tiny", math.SmallestNonzeroFloat64}, {"negative_tiny", -math.SmallestNonzeroFloat64},
		{"largest_subnormal", math.Float64frombits(0x000fffffffffffff)},
		{"smallest_normal", math.Float64frombits(0x0010000000000000)},
		{"maximum", math.MaxFloat64}, {"minimum", -math.MaxFloat64},
		{"infinity", math.Inf(1)}, {"negative_infinity", math.Inf(-1)},
	} {
		for _, kind := range []string{"update", "delete"} {
			t.Run(c.name+"/"+kind, func(t *testing.T) {
				s := toolSession(t)
				ctx := context.Background()
				toolExec(t, s, "CREATE TABLE records(id INTEGER PRIMARY KEY,value BLOB,note TEXT)")
				value := realGuardValue(c.f)
				toolExec(t, s, "INSERT INTO records VALUES(1,?,'captured')", value)
				op := realGuardOperation(t, kind, value)
				sql, err := RenderDataSynchronization(op)
				if err != nil || !strings.Contains(sql, `typeof("value")='real'`) {
					t.Fatal("nonzero REAL guard was not generated")
				}
				// A different value one binary64 step away must never pass the guard.
				toolExec(t, s, "UPDATE records SET value=?", realGuardValue(math.Nextafter(c.f, 0)))
				toolExec(t, s, sql)
				if s.conn.Changes() != 0 {
					t.Fatal("adjacent REAL value passed the original-value guard")
				}
				// A column absent from the mappings still protects the captured row.
				toolExec(t, s, "UPDATE records SET value=?,note='concurrent'", value)
				toolExec(t, s, sql)
				if s.conn.Changes() != 0 {
					t.Fatal("an excluded changed column passed the original-value guard")
				}
				toolExec(t, s, "UPDATE records SET note='captured'")
				toolExec(t, s, sql)
				if s.conn.Changes() != 1 {
					t.Fatal("unchanged nonzero REAL original did not match exactly")
				}
				rows, _, err := s.query(ctx, "SELECT value FROM records")
				if err != nil || kind == "delete" && len(rows) != 0 || kind == "update" && (len(rows) != 1 || cellText(rows[0][0]) != "changed") {
					t.Fatal("guarded synchronization did not perform the selected operation")
				}
			})
		}
	}
}

func TestSQLiteSynchronizationRealOriginalRejectsIntegerStorage(t *testing.T) {
	for _, kind := range []string{"update", "delete"} {
		t.Run(kind, func(t *testing.T) {
			s := toolSession(t)
			toolExec(t, s, "CREATE TABLE records(id INTEGER PRIMARY KEY,value BLOB,note TEXT)")
			toolExec(t, s, "INSERT INTO records VALUES(1,1,'captured')")
			sql, err := RenderDataSynchronization(realGuardOperation(t, kind, realGuardValue(1)))
			if err != nil {
				t.Fatal(err)
			}
			toolExec(t, s, sql)
			if s.conn.Changes() != 0 {
				t.Fatal("INTEGER storage passed a numerically equal REAL guard")
			}
		})
	}
}

func TestSQLiteSynchronizationRealPrimaryKeyGuard(t *testing.T) {
	for _, kind := range []string{"update", "delete"} {
		t.Run(kind, func(t *testing.T) {
			s := toolSession(t)
			toolExec(t, s, "CREATE TABLE records(id BLOB PRIMARY KEY NOT NULL,value TEXT)")
			key := realGuardValue(.1)
			toolExec(t, s, "INSERT INTO records VALUES(?,'before')", key)
			id := syncRealCell(t, key.Type, key.Value)
			op := syncplan.DataOperation{Kind: kind,
				Descriptor: tc.Descriptor{Engine: "sqlite", Table: tc.Table{Schema: "main", Name: "records"}, Columns: []tc.Column{{Index: 0, Name: "id", NativeType: "BLOB", PrimaryKey: 1}, {Index: 1, Name: "value", NativeType: "TEXT"}}},
				Mappings:   []syncplan.DataMapping{{SourceIndex: 0, TargetIndex: 0, Key: true}, {SourceIndex: 1, TargetIndex: 1}},
				Source:     []*string{id, syncRealCell(t, "text", "YWZ0ZXI=")},
				Target:     []*string{id, syncRealCell(t, "text", "YmVmb3Jl")}}
			sql, err := RenderDataSynchronization(op)
			if err != nil {
				t.Fatal(err)
			}
			toolExec(t, s, "UPDATE records SET id=?", realGuardValue(math.Nextafter(.1, 1)))
			toolExec(t, s, sql)
			if s.conn.Changes() != 0 {
				t.Fatal("adjacent REAL key passed the original key guard")
			}
			toolExec(t, s, "UPDATE records SET id=?", key)
			toolExec(t, s, sql)
			if s.conn.Changes() != 1 {
				t.Fatal("exact REAL primary key did not match")
			}
		})
	}
}

func TestSQLiteSynchronizationRealZerosAndNaNStayManual(t *testing.T) {
	for _, bits := range []string{"0000000000000000", "8000000000000000", "7ff8000000000000", "fff8000000000000", "7ff0000000000001"} {
		for _, kind := range []string{"update", "delete"} {
			if _, err := RenderDataSynchronization(realGuardOperation(t, kind, protocol.SQLiteValue{Type: "real", Value: bits})); err == nil {
				t.Fatal("an ambiguous or unrepresentable REAL original received an executable guard")
			}
		}
	}
}
