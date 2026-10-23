package textdiff

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestSharedDiffFixture(t *testing.T) {
	b, err := os.ReadFile("../../../protocol/fixtures/text-diff-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name           string
			Source, Target Input
			Expected       Diff
		}
	}
	if err = json.Unmarshal(b, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			got, e := Compare(context.Background(), c.Source, c.Target)
			if e != nil {
				t.Fatal(e)
			}
			if !reflect.DeepEqual(got, c.Expected) {
				t.Fatalf("diff does not match shared fixture: %+v", got)
			}
		})
	}
}
func TestSemanticStatesAndWhitespace(t *testing.T) {
	for _, tc := range []struct {
		name           string
		source, target Input
		kind           string
	}{
		{"null versus empty", Input{Kind: "null"}, Text(""), "targetOnly"},
		{"absent versus null", Input{Kind: "absent"}, Input{Kind: "null"}, ""},
		{"literal NULL", Input{Kind: "null"}, Text("NULL"), "targetOnly"},
		{"trailing space", Text("abc"), Text("abc "), "changed"},
		{"tab", Text("a b"), Text("a\tb"), "changed"},
		{"CRLF", Text("a\r\n"), Text("a\n"), "changed"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d, e := Compare(context.Background(), tc.source, tc.target)
			if e != nil || d.Status != "complete" || d.Source.Kind != tc.source.Kind || d.Target.Kind != tc.target.Kind {
				t.Fatal("states changed")
			}
			if tc.kind == "" {
				if len(d.Lines) != 0 {
					t.Fatal("non-text state rendered as text")
				}
				return
			}
			if len(d.Lines) == 0 || d.Lines[0].Kind != tc.kind {
				t.Fatal("change was hidden")
			}
			if tc.name == "trailing space" && !reflect.DeepEqual(d.Lines[0].Target.Highlights, []Range{{3, 4}}) {
				t.Fatal("trailing whitespace not highlighted")
			}
			if tc.name == "tab" && (!reflect.DeepEqual(d.Lines[0].Source.Highlights, []Range{{1, 2}}) || !reflect.DeepEqual(d.Lines[0].Target.Highlights, []Range{{1, 2}})) {
				t.Fatal("whitespace-only replacement hidden")
			}
		})
	}
}
func TestAlignmentAndUTF8ByteRanges(t *testing.T) {
	d, e := Compare(context.Background(), Text("α old 😀\nanchor\nlast"), Text("α new 😀\ninserted\nanchor\nlast\n"))
	if e != nil || d.Status != "complete" || len(d.Lines) != 5 {
		t.Fatal("alignment failed")
	}
	if d.Lines[1].Kind != "targetOnly" || d.Lines[2].Kind != "equal" || d.Lines[4].Kind != "targetOnly" {
		t.Fatal("added lines not aligned")
	}
	if !reflect.DeepEqual(d.Lines[0].Source.Highlights, []Range{{3, 6}}) {
		t.Fatal("ranges are not UTF-8 bytes")
	}
	for _, p := range d.Lines {
		for _, l := range []*Line{p.Source, p.Target} {
			if l != nil {
				for _, r := range l.Highlights {
					if !utf8.ValidString(l.Text[:r.Start]) || !utf8.ValidString(l.Text[:r.End]) {
						t.Fatal("split Unicode scalar")
					}
				}
			}
		}
	}
}
func TestBoundedWorkOutputAndCancellation(t *testing.T) {
	for _, tc := range []struct{ name, a, b string }{
		{"input", strings.Repeat("猫", MaxTextBytes), "x"},
		{"line cost", strings.Repeat("a\n", 1500), strings.Repeat("b\n", 1500)},
		{"token cost", strings.Repeat("a,", 2000), strings.Repeat("b,", 2000)},
		{"JSON escaping", strings.Repeat("\x00", MaxTextBytes), strings.Repeat("\x01", MaxTextBytes)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d, e := Compare(context.Background(), Text(tc.a), Text(tc.b))
			if e != nil || d.Status != "limited" {
				t.Fatal("budget did not produce explicit fallback")
			}
			b, _ := json.Marshal(d)
			if len(b) > maxOutputBytes {
				t.Fatal("response exceeded output cap")
			}
			if d.Source.TotalBytes != int64(len(tc.a)) {
				t.Fatal("original size lost")
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e := Compare(ctx, Text("a"), Text("b")); !errors.Is(e, context.Canceled) {
		t.Fatal("cancelled diff ran")
	}
	ctx, cancel = context.WithCancel(context.Background())
	budget := maxWork
	cancel()
	if _, _, _, e := lcs(ctx, []string{"a"}, []string{"b"}, &budget); !errors.Is(e, context.Canceled) {
		t.Fatal("LCS ignored cancellation")
	}
}
func TestBinaryIsNotText(t *testing.T) {
	for _, in := range []Input{{Kind: "binary", TotalBytes: 2}, Text(string([]byte{0xff, 0xfe}))} {
		d, e := Compare(context.Background(), in, Text("AP8="))
		if e != nil || d.Status != "binary" || d.Source.Kind != "binary" || len(d.Lines) != 0 {
			t.Fatal("binary was rendered as text")
		}
	}
}
