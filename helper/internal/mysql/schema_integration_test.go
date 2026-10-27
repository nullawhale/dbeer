package mysql

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"testing"
)

func TestSchemaCaptureEffectiveDefaultsAndIndexes(t *testing.T) {
	s := integrationSession(t)
	run(t, s, "DROP TABLE IF EXISTS schema_compare_fixture")
	defer run(t, s, "DROP TABLE IF EXISTS schema_compare_fixture")
	run(t, s, "CREATE TABLE schema_compare_fixture(id bigint PRIMARY KEY, amount decimal(30,9) DEFAULT 9007199254740993.123456789, note varchar(255) DEFAULT '', KEY note_idx(note(12))) ENGINE=InnoDB")
	settings := integrationSettings(t)
	capture := func() sc.Capture {
		opened, e := Open(context.Background(), settings)
		if e != nil {
			t.Fatal("capture open failed")
		}
		defer opened.Close()
		reader := opened.(*Session)
		if e = reader.SetReadOnly(context.Background(), true); e != nil {
			t.Fatal("read-only setup failed")
		}
		c := sc.NewCollector(context.Background(), sc.DefaultLimits())
		if e = reader.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{settings.Database}, Limits: sc.DefaultLimits()}, c); e != nil {
			t.Fatalf("schema capture failed: %T", e)
		}
		return c.Capture
	}
	left := capture()
	m := sc.Mappings{Schemas: []sc.NamePair{{Source: settings.Database, Target: settings.Database}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}
	result, e := sc.Build(context.Background(), t.TempDir(), left, capture(), m)
	if e != nil {
		t.Fatal(e)
	}
	defer result.Close()
	if !result.Report.Summary.FullEquality {
		for _, issue := range result.Report.Issues {
			t.Log(issue.Code, issue.Property)
		}
		for _, d := range result.Report.Differences {
			t.Log(d.Property, d.Kind)
		}
		t.Fatalf("identical fully visible schema did not match: complete=%v differences=%d issues=%d", result.Report.Summary.Complete, result.Report.Summary.DifferenceCount, result.Report.Summary.IssueCount)
	}
	found := false
	for _, table := range left.Tables {
		if table.Ref.Name == "schema_compare_fixture" {
			for _, column := range table.Columns.Items {
				if column.Ref.Name == "amount" {
					found = column.Default.Value != nil && column.Default.Value.Value != nil && *column.Default.Value.Value == "9007199254740993.123456789"
				}
			}
		}
	}
	if !found {
		t.Fatal("exact numeric default was lost")
	}
	run(t, s, "ALTER TABLE schema_compare_fixture MODIFY note varchar(100) DEFAULT ''")
	changed, e := sc.Build(context.Background(), t.TempDir(), left, capture(), m)
	if e != nil {
		t.Fatal(e)
	}
	defer changed.Close()
	if changed.Report.Summary.DifferenceCount == 0 || changed.Report.Summary.FullEquality {
		t.Fatal("column drift was missed")
	}
}
