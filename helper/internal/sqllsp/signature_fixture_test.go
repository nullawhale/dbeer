package sqllsp

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"unicode/utf16"
)

// Shared with the Swift reference and future Rust frontend. The wire spans
// count UTF-16 units, while the signature engine consumes UTF-8 byte offsets.
func TestSharedSignatureHelpFixtures(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/signature-help.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		ID, Engine, SQLWithCaret string
		Catalog                  []catalogEntry
		Expect                   struct {
			Present             bool
			Name, ParameterText string
			ActiveParameter     int
		}
	}
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) == 0 {
		t.Fatal("empty shared signature corpus")
	}
	for _, check := range cases {
		t.Run(check.ID, func(t *testing.T) {
			if strings.Count(check.SQLWithCaret, "|") != 1 {
				t.Fatal("expected exactly one caret")
			}
			offset := strings.Index(check.SQLWithCaret, "|")
			result := signatureHelp(strings.Replace(check.SQLWithCaret, "|", "", 1), offset,
				configuration{Engine: check.Engine, Catalog: check.Catalog})
			if (result != nil) != check.Expect.Present {
				t.Fatal("signature presence differs from shared fixture")
			}
			if result == nil {
				return
			}
			selected := result.Signatures[result.ActiveSignature]
			if !strings.HasPrefix(selected.Label, check.Expect.Name+"(") || selected.ActiveParameter == nil || *selected.ActiveParameter != check.Expect.ActiveParameter {
				t.Fatal("active function or argument differs from shared fixture")
			}
			units := utf16.Encode([]rune(selected.Label))
			for _, parameter := range selected.Parameters {
				span := parameter.Label
				if span[0] < 0 || span[1] <= span[0] || span[1] > len(units) {
					t.Fatal("invalid UTF-16 parameter span")
				}
			}
			if check.Expect.ParameterText != "" {
				span := selected.Parameters[*selected.ActiveParameter].Label
				if string(utf16.Decode(units[span[0]:span[1]])) != check.Expect.ParameterText {
					t.Fatal("active parameter text differs from shared fixture")
				}
			}
		})
	}
}
