package sqlite

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"math/rand"
	"testing"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/syncplan"
	tc "dbeer/helper/internal/tablecapture"
)

func syncRealCell(t *testing.T, kind, value string) *string {
	t.Helper()
	b, err := json.Marshal(protocol.SQLiteValue{Type: kind, Value: value})
	if err != nil {
		t.Fatal("could not encode synchronization fixture")
	}
	s := string(b)
	return &s
}

func syncRealOperation(t *testing.T, kind string, source, target *string) syncplan.DataOperation {
	t.Helper()
	id := syncRealCell(t, "integer", "1")
	op := syncplan.DataOperation{Kind: kind, Descriptor: tc.Descriptor{Engine: "sqlite", Table: tc.Table{Schema: "main", Name: "records"},
		Columns: []tc.Column{{Index: 0, Name: "id", NativeType: "INTEGER", PrimaryKey: 1}, {Index: 1, Name: "value", NativeType: "ANY"}}},
		Mappings: []syncplan.DataMapping{{SourceIndex: 0, TargetIndex: 0, Key: true}, {SourceIndex: 1, TargetIndex: 1}}}
	if source != nil {
		op.Source = []*string{id, source}
	}
	if target != nil {
		op.Target = []*string{id, target}
	}
	return op
}

func TestSQLiteSynchronizationRealAssignmentsRoundtripExactly(t *testing.T) {
	ctx := context.Background()
	cases := []struct {
		name  string
		value float64
	}{
		{"zero", 0}, {"one", 1}, {"negative_one", -1},
		{"fraction", .1}, {"next_fraction", math.Nextafter(.1, 1)}, {"tiny", math.SmallestNonzeroFloat64},
		{"largest_subnormal", math.Float64frombits(0x000fffffffffffff)},
		{"smallest_normal", math.Float64frombits(0x0010000000000000)},
		{"large", math.MaxFloat64}, {"negative_large", -math.MaxFloat64},
		{"positive_infinity", math.Inf(1)}, {"negative_infinity", math.Inf(-1)},
	}
	rng := rand.New(rand.NewSource(7))
	for i := 0; i < 128; i++ {
		v := math.Float64frombits(rng.Uint64())
		if !math.IsNaN(v) {
			cases = append(cases, struct {
				name  string
				value float64
			}{fmt.Sprintf("sample_%d", i), v})
		}
	}
	for _, affinity := range []struct{ name, definition string }{
		{"untyped", "value"}, {"blob", "value BLOB"}, {"real", "value REAL"}, {"strict_any", "value ANY) STRICT"},
	} {
		t.Run(affinity.name, func(t *testing.T) {
			s := toolSession(t)
			definition := "CREATE TABLE records(id INTEGER PRIMARY KEY," + affinity.definition
			if affinity.name != "strict_any" {
				definition += ")"
			}
			toolExec(t, s, definition)
			descriptor, err := s.DescribeTable(ctx, tc.Table{Schema: "main", Name: "records"})
			if err != nil {
				t.Fatal("could not capture target affinity")
			}
			for _, c := range cases {
				t.Run(c.name, func(t *testing.T) {
					toolExec(t, s, "DELETE FROM records")
					bits := fmt.Sprintf("%016x", math.Float64bits(c.value))
					source := syncRealCell(t, "real", bits)
					op := syncRealOperation(t, "insert", source, nil)
					op.Descriptor = descriptor
					sql, err := RenderDataSynchronization(op)
					if err != nil {
						t.Fatal("REAL source synchronization was refused")
					}
					toolExec(t, s, sql)
					rows, _, err := s.query(ctx, "SELECT value FROM records")
					if err != nil || len(rows) != 1 || rows[0][0].Type != "real" || rows[0][0].Value != bits {
						t.Fatal("REAL synchronization did not retain the exact storage class and binary64 value")
					}
				})
			}
		})
	}
}

func TestSQLiteSynchronizationRealAssignmentsKeepOriginalGuards(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TABLE records(id INTEGER PRIMARY KEY,value)")
	toolExec(t, s, "INSERT INTO records VALUES(1,'before')")
	source := syncRealCell(t, "real", "3ff8000000000000")
	target := syncRealCell(t, "text", "YmVmb3Jl")
	sql, err := RenderDataSynchronization(syncRealOperation(t, "update", source, target))
	if err != nil {
		t.Fatal("supported original-value guard did not permit a REAL assignment")
	}
	toolExec(t, s, sql)
	rows, _, err := s.query(ctx, "SELECT value FROM records")
	if err != nil || rows[0][0].Type != "real" || rows[0][0].Value != "3ff8000000000000" {
		t.Fatal("guarded REAL update did not preserve the source value")
	}
	toolExec(t, s, "UPDATE records SET value='concurrent'")
	toolExec(t, s, sql)
	rows, _, err = s.query(ctx, "SELECT value FROM records")
	if err != nil || rows[0][0].Type != "text" || cellText(rows[0][0]) != "concurrent" {
		t.Fatal("REAL assignment weakened original-value conflict protection")
	}
	for _, kind := range []string{"update", "delete"} {
		if _, err = RenderDataSynchronization(syncRealOperation(t, kind, source, syncRealCell(t, "real", "0000000000000000"))); err == nil {
			t.Fatal("a zero REAL original was accepted without bitwise conflict protection")
		}
	}
	for _, bits := range []string{"7ff8000000000000", "fff8000000000000", "7ff0000000000001", "8000000000000000"} {
		if _, err = RenderDataSynchronization(syncRealOperation(t, "insert", syncRealCell(t, "real", bits), nil)); err == nil {
			t.Fatal("an unpreservable REAL source was converted silently")
		}
	}
}
