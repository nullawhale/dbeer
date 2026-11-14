package adapter

import (
	"dbeer/helper/internal/protocol"
	"strings"
	"testing"
)

func TestExplainOptionsVersionModesAndPreselectedFormats(t *testing.T) {
	b := func(v bool) *bool { return &v }
	for _, version := range []string{"14.0", "16.9", "17.0", "18.1"} {
		support := ExplainSupport("postgresql", version)
		for _, mode := range []string{"plan", "analyze"} {
			for _, key := range []string{"buffers", "wal", "settings", "memory", "serialize", "timing"} {
				pg := &protocol.PostgresExplainOptions{}
				switch key {
				case "buffers":
					pg.Buffers = b(false)
				case "wal":
					pg.WAL = b(false)
				case "settings":
					pg.Settings = b(true)
				case "memory":
					pg.Memory = b(true)
				case "serialize":
					pg.Serialize = "text"
				case "timing":
					pg.Timing = b(false)
				}
				r := protocol.ExplainRequest{SQL: "SELECT 1", Mode: mode, Options: &protocol.ExplainOptions{PostgreSQL: pg}}
				p, err := PrepareExplain(support, r)
				expected := (key != "memory" && key != "serialize" || version >= "17") && (mode == "analyze" || key != "wal" && key != "timing" && key != "serialize")
				if (err == nil) != expected {
					t.Fatalf("PostgreSQL %s %s %s gate", version, mode, key)
				}
				if expected && (p.Preview.Format != "json" || p.Preview.Options != r.Options || !strings.Contains(p.Prefix, strings.ToUpper(key)+" ")) {
					t.Fatal("option omitted from exact preview")
				}
			}
		}
	}
	for _, item := range []struct {
		version, format string
		analyze         bool
		prefix          string
	}{{"5.7.44", "json", false, ""}, {"8.0.15", "json", false, ""}, {"8.0.16", "tree", false, ""}, {"8.0.17", "tree", false, ""}, {"8.0.18", "tree", true, "EXPLAIN ANALYZE\n"}, {"8.0.20", "tree", true, "EXPLAIN ANALYZE\n"}, {"8.0.21", "tree", true, "EXPLAIN ANALYZE FORMAT=TREE\n"}, {"8.2.0", "tree", true, "EXPLAIN ANALYZE FORMAT=TREE\n"}, {"8.3.0", "tree", true, "EXPLAIN ANALYZE FORMAT=TREE\n"}, {"8.4.6", "tree", true, "EXPLAIN ANALYZE FORMAT=TREE\n"}} {
		support := ExplainSupport("mysql", item.version)
		expectedNotices := 0
		if item.version == "8.0.18" {
			expectedNotices = 2
		}
		if len(support.Notices) != expectedNotices {
			t.Fatal("older Analyze limitations omitted")
		}
		if !support.Valid() || support.Format != item.format {
			t.Fatal("MySQL capability matrix")
		}
		r := protocol.ExplainRequest{SQL: "SELECT 1", Mode: "plan", Options: &protocol.ExplainOptions{MySQL: &protocol.MySQLExplainOptions{Format: "auto"}}}
		p, err := PrepareExplain(support, r)
		if err != nil || p.Preview.Format != item.format {
			t.Fatal("estimated format selection")
		}
		r.Mode = "analyze"
		p, err = PrepareExplain(support, r)
		if (err == nil) != item.analyze {
			t.Fatal("Analyze version gate")
		}
		if !item.analyze && support.AnalyzeUnavailableReason == "" {
			t.Fatal("missing concrete Analyze reason")
		}
		if item.analyze && p.Prefix != item.prefix {
			t.Fatalf("wrong older syntax %s", item.version)
		}
		r.Options.MySQL.Format = "json"
		_, err = PrepareExplain(support, r)
		if (err == nil) != (item.version >= "8.3") {
			t.Fatal("JSON v2 Analyze gate")
		}
	}
	for _, version := range []string{"5.6.51", "6.0.0", "7.0.0", "5.7.44-unknownVendor"} {
		if len(ExplainSupport("mysql", version).Modes) != 0 {
			t.Fatal("unverified version admitted")
		}
	}
	r := protocol.ExplainRequest{SQL: "SELECT 1", Mode: "plan", Options: &protocol.ExplainOptions{MySQL: &protocol.MySQLExplainOptions{Format: "tree"}}}
	if _, err := PrepareExplain(ExplainSupport("mysql", "5.7.44"), r); err == nil {
		t.Fatal("TREE on5.7")
	}
	if _, err := PrepareExplain(ExplainSupport("postgresql", "17.6"), r); err == nil {
		t.Fatal("cross-engine options")
	}
	support := ExplainSupport("postgresql", "17.6")
	support.Options = nil
	r.Options = &protocol.ExplainOptions{PostgreSQL: &protocol.PostgresExplainOptions{}}
	if _, err := PrepareExplain(support, r); err == nil {
		t.Fatal("unadvertised options")
	}
}
