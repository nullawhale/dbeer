package schemacompare

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func TestMetadataTextDiffFullCapturedPropertiesAndReferences(t *testing.T) {
	a, b := testCapture("a"), testCapture("b")
	a.Tables[0].Columns.Items[0].Comment = Known(strings.Repeat("unchanged ", 60) + "before")
	b.Tables[0].Columns.Items[0].Comment = Known(strings.Repeat("unchanged ", 60) + "after")
	r := buildTest(t, a, b, testMappings())
	if len(r.Report.Differences) != 1 || !r.Report.Differences[0].SourcePreview.Truncated {
		t.Fatal("test requires full property beyond preview")
	}
	d, e := r.MetadataTextDiff(context.Background(), 0)
	if e != nil || d.Status != "complete" {
		t.Fatal("diff unavailable")
	}
	found := false
	for _, p := range d.Lines {
		if p.Source != nil && strings.Contains(p.Source.Text, "before") {
			found = true
			if p.Target == nil || !strings.Contains(p.Target.Text, "after") || len(p.Source.Highlights) == 0 {
				t.Fatal("full change not highlighted")
			}
		}
	}
	if !found {
		t.Fatal("diff compared truncated previews")
	}
	for _, index := range []int64{-1, 1} {
		if _, e = r.MetadataTextDiff(context.Background(), index); e == nil {
			t.Fatal("invalid difference index accepted")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e = r.MetadataTextDiff(ctx, 0); !errors.Is(e, context.Canceled) {
		t.Fatal("cancelled schema diff completed")
	}
}
func TestMetadataTextDiffDecodedExpressionAndAbsentProperty(t *testing.T) {
	r := buildTest(t, testCapture("a"), testCapture("b"), testMappings())
	// Exercise scalar storage as well as the structured facts used by captures.
	if e := r.diff(reflect.ValueOf("SELECT 猫\nFROM before"), reflect.ValueOf("SELECT 猫\nFROM after"), nil, nil, "expression", "changed"); e != nil {
		t.Fatal(e)
	}
	d, e := r.MetadataTextDiff(context.Background(), 0)
	if e != nil || len(d.Lines) != 2 || d.Lines[0].Source.Text != "SELECT 猫" || d.Lines[1].Source.Text != "FROM before" {
		t.Fatal("expression remains JSON escaped")
	}
	if e = r.diff(reflect.Value{}, reflect.ValueOf(""), nil, nil, "expression", "targetOnly"); e != nil {
		t.Fatal(e)
	}
	d, e = r.MetadataTextDiff(context.Background(), 1)
	if e != nil || d.Source.Kind != "absent" || d.Target.Kind != "text" || d.Lines[0].Target.Text != "" {
		t.Fatal("absence confused with empty property")
	}
}
