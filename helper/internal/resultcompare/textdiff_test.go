package resultcompare

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestTextDiffReadsFullMappedValuesAndValidatesReferences(t *testing.T) {
	a := strings.Repeat("prefix ", 100) + "before"
	b := strings.Repeat("prefix ", 100) + "after"
	r := compare(t, source(cols("text"), []*string{text(a)}), source(cols("text"), []*string{text(b)}), Options{Mode: "rowOrder", Columns: []Mapping{{Left: 0, Right: 0}}})
	page, e := r.Page(context.Background(), 0, 1, 4096, 0)
	if e != nil || !page.Rows[0].Cells[0].Left.Truncated || !page.Rows[0].Cells[0].Right.Truncated {
		t.Fatal("test must compare truncated previews")
	}
	d, e := r.TextDiff(context.Background(), 0, 0)
	if e != nil || d.Status != "complete" || d.Lines[0].Source.Text != a || d.Lines[0].Target.Text != b {
		t.Fatal("diff used a preview or changed captured value")
	}
	if len(d.Lines[0].Source.Highlights) != 1 || d.Lines[0].Source.Highlights[0].Start < 256 {
		t.Fatal("change after preview was not highlighted")
	}
	for _, tc := range []struct {
		index   int64
		mapping int
	}{{-1, 0}, {1, 0}, {0, -1}, {0, 1}} {
		if _, e = r.TextDiff(context.Background(), tc.index, tc.mapping); !errors.Is(e, ErrReference) {
			t.Fatal("invalid diff selection accepted")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e = r.TextDiff(ctx, 0, 0); !errors.Is(e, context.Canceled) {
		t.Fatal("cancelled read completed")
	}
	_ = r.Close()
	if _, e = r.TextDiff(context.Background(), 0, 0); !errors.Is(e, ErrClosed) {
		t.Fatal("closed comparison remained readable")
	}
}
func TestTextDiffPreservesNullAbsentBinaryAndExactNumbers(t *testing.T) {
	for _, tc := range []struct {
		name                                     string
		left, right                              *string
		leftRows                                 int
		encoding, sourceKind, targetKind, status string
		bytes                                    int64
	}{
		{"null and empty", nil, text(""), 1, "", "null", "text", "complete", 0},
		{"text NULL", text("NULL"), nil, 1, "", "text", "null", "complete", 4},
		{"absent row", nil, nil, 0, "", "absent", "null", "complete", 0},
		{"binary", text("AP8="), text("AP9="), 1, "base64", "binary", "binary", "binary", 2},
		{"exact numeric", text("9007199254740993.123456789"), text("9007199254740993.123456788"), 1, "", "text", "text", "complete", 28},
	} {
		t.Run(tc.name, func(t *testing.T) {
			columns := cols("text")
			columns[0].Encoding = tc.encoding
			l := source(columns)
			if tc.leftRows > 0 {
				l = source(columns, []*string{tc.left})
			}
			r := compare(t, l, source(columns, []*string{tc.right}), Options{Mode: "rowOrder", Columns: []Mapping{{Left: 0, Right: 0}}})
			d, e := r.TextDiff(context.Background(), 0, 0)
			if e != nil || d.Status != tc.status || d.Source.Kind != tc.sourceKind || d.Target.Kind != tc.targetKind {
				t.Fatal("typed value lost")
			}
			if tc.name == "binary" && d.Source.TotalBytes != tc.bytes {
				t.Fatal("binary size counts base64 bytes")
			}
			if tc.name == "exact numeric" && d.Lines[0].Source.Text != *tc.left {
				t.Fatal("numeric value normalized")
			}
		})
	}
}
