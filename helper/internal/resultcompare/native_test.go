package resultcompare

import (
	"context"
	"dbeer/helper/internal/nativevalue"
	"encoding/json"
	"path/filepath"
	"testing"
)

func TestNativeValuesKeepKindsAndUnresolvedSemanticsUncertain(t *testing.T) {
	encoded := func(v nativevalue.NativeValue) *string {
		b, e := json.Marshal(v)
		if e != nil {
			t.Fatal(e)
		}
		s := string(b)
		return &s
	}
	for _, tc := range []struct {
		name               string
		a, b               nativevalue.NativeValue
		changed, uncertain int64
	}{
		{"different scalar kinds", nativevalue.NativeScalar("text", "42"), nativevalue.NativeScalar("integer", "42"), 1, 0},
		{"same exact integer", nativevalue.NativeScalar("integer", "9007199254740993"), nativevalue.NativeScalar("integer", "9007199254740993"), 0, 0},
		{"opaque equality unproven", nativevalue.NativeValue{Kind: "opaque", Value: text("AA=="), Engine: "postgresql", NativeType: "custom"}, nativevalue.NativeValue{Kind: "opaque", Value: text("AA=="), Engine: "postgresql", NativeType: "custom"}, 0, 1},
		{"unordered set unproven", nativevalue.NativeValue{Kind: "set", Items: []nativevalue.NativeValue{nativevalue.NativeScalar("integer", "1")}}, nativevalue.NativeValue{Kind: "set", Items: []nativevalue.NativeValue{nativevalue.NativeScalar("integer", "1")}}, 0, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			column := Column{Index: 0, Name: "value", Engine: "postgresql", NativeType: "captured", TypeIdentity: "typed-v1", Encoding: "nativeValue"}
			left := &memorySource{meta: Metadata{Columns: []Column{column}, RowCount: 1, Complete: true}, rows: [][]*string{{encoded(tc.a)}}}
			right := &memorySource{meta: left.meta, rows: [][]*string{{encoded(tc.b)}}}
			result, e := Compare(context.Background(), left, right, Options{Mode: "rowOrder", Columns: []Mapping{{Left: 0, Right: 0}}, ScratchDir: filepath.Join(t.TempDir(), "scratch")})
			if e != nil {
				t.Fatal(e)
			}
			defer result.Close()
			summary := result.Summary()
			if summary.ChangedRows != tc.changed || summary.UncertainRows != tc.uncertain || summary.FullEquality != (tc.changed == 0 && tc.uncertain == 0) {
				t.Fatal("native equality lost kind or uncertainty")
			}
		})
	}
}
