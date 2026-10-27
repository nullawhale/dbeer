package schemacompare_test

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/postgres"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/textdiff"
)

func TestSharedSQLDefinitionFixtureUsesFrozenAdapterOutput(t *testing.T) {
	raw, e := os.ReadFile("../../../protocol/fixtures/schema-sql-diff-v1.json")
	if e != nil {
		t.Fatal(e)
	}
	var fixture struct {
		FormatVersion int
		Cases         []struct {
			Name, Engine                 string
			SourceCapture, TargetCapture sc.Capture
			Mappings                     sc.Mappings
			SourceSQL, TargetSQL         string
			Expected                     textdiff.Diff
		}
	}
	if e = json.Unmarshal(raw, &fixture); e != nil {
		t.Fatal(e)
	}
	if fixture.FormatVersion != 1 || len(fixture.Cases) != 2 {
		t.Fatal("invalid SQL fixture")
	}
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			renderer := postgres.RenderSchemaDefinition
			if test.Engine == "mysql" {
				renderer = mysql.RenderSchemaDefinition
			}
			for _, side := range []struct {
				capture sc.Capture
				sql     string
			}{{test.SourceCapture, test.SourceSQL}, {test.TargetCapture, test.TargetSQL}} {
				definition, e := renderer(context.Background(), side.capture, side.capture.Tables[0].Ref)
				if e != nil || definition.Limited || definition.SQL != side.sql {
					t.Fatal("SQL fixture differs from actual adapter rendering")
				}
			}
			r, e := sc.Build(context.Background(), t.TempDir(), test.SourceCapture, test.TargetCapture, test.Mappings)
			if e != nil {
				t.Fatal(e)
			}
			defer r.Close()
			if len(r.Report.Differences) == 0 {
				t.Fatal("fixture has no semantic difference")
			}
			d, e := r.TextDiff(context.Background(), 0, renderer)
			if e != nil || !reflect.DeepEqual(d, test.Expected) {
				t.Fatal("shared SQL wire fixture differs from definition operation")
			}
			source, target := []string{}, []string{}
			for _, line := range d.Lines {
				if line.Source != nil {
					source = append(source, line.Source.Text)
				}
				if line.Target != nil {
					target = append(target, line.Target.Text)
				}
			}
			if strings.Join(source, "\n") != test.SourceSQL || strings.Join(target, "\n") != test.TargetSQL {
				t.Fatal("SQL diff lost original lines")
			}
			metadata, e := r.MetadataTextDiff(context.Background(), 0)
			if e != nil || len(metadata.Lines) == 0 {
				t.Fatal("exact metadata inspection unavailable")
			}
		})
	}
}
