package sqlcomplete

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestEditorColumnTypesUseSharedFourLanguageMetadata(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/editor-tools-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Engine, Source, CaretText, ExpectedType string
			Catalog                                 []Relation
		} `json:"columnTypeCases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) != 4 {
		t.Fatal("missing language type fixtures")
	}
	for _, c := range fixture.Cases {
		t.Run(c.Engine, func(t *testing.T) {
			offset := strings.Index(c.Source, c.CaretText)
			if offset < 0 {
				t.Fatal("invalid caret fixture")
			}
			analysis := AnalyzeEditor(c.Source, offset+1, Context{Engine: c.Engine, Catalog: c.Catalog})
			if len(analysis.Definitions) != 1 || !strings.Contains(analysis.Definitions[0].Detail, c.ExpectedType) {
				t.Fatal("loaded native type did not reach information detail", analysis.Definitions)
			}
			if c.Engine == "mongodb" && !strings.Contains(analysis.Definitions[0].Detail, "Samples are not a schema") {
				t.Fatal("sample evidence lost")
			}
		})
	}
}
