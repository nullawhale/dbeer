package adapter

import (
	"dbeer/helper/internal/protocol"
	"testing"
)

func mariaDBHookSupport(version string) protocol.ExplainSupport {
	return protocol.ExplainSupport{Engine: "mariadb", ServerVersion: version, Format: "json", Modes: []string{"plan", "analyze"}, DML: &protocol.ExplainDMLSupport{Estimated: true, EstimatedForms: []string{"update", "delete", "mysqlMultiTableUpdate", "mysqlMultiTableDelete"}, Analyze: []string{"update", "delete", "mysqlMultiTableUpdate", "mysqlMultiTableDelete"}, AnalyzeTargetExecution: "executes"}}
}
func TestMariaDBPrepareExplainNativePrefixAndDMLForms(t *testing.T) {
	s := mariaDBHookSupport("11.4.13-MariaDB")
	for _, mode := range []string{"plan", "analyze"} {
		r := dmlExplainRequest("UPDATE sample SET id=2", "plan", "idle")
		if mode == "analyze" {
			r = dmlExplainRequest(r.SQL, mode, "idle")
		}
		p, err := PrepareExplain(s, r)
		prefix := "EXPLAIN FORMAT=JSON\n"
		if mode == "analyze" {
			prefix = "ANALYZE FORMAT=JSON\n"
		}
		if err != nil || p.Prefix != prefix || p.Preview.SQL != prefix+r.SQL || p.Preview.Support.Engine != "mariadb" {
			t.Fatal("native Explain prefix or retained statement identity changed")
		}
	}
	if _, err := PrepareExplain(s, dmlExplainRequest("INSERT INTO sample VALUES(2)", "plan", "idle")); err == nil {
		t.Fatal("undeclared estimated INSERT form admitted")
	}
	r := dmlExplainRequest("DELETE FROM sample", "analyze", "idle")
	r.WriteIntent = nil
	if _, err := PrepareExplain(s, r); err == nil {
		t.Fatal("executing MariaDB Analyze lost explicit write intent")
	}
}
func TestMariaDBTuningVersionFloorIsNative(t *testing.T) {
	for version, want := range map[string]bool{"10.11.8-MariaDB": false, "10.11.9-MariaDB": true, "11.4.2-MariaDB": false, "11.4.3-MariaDB": true, "11.4.13-MariaDB-ubu2404": true, "11.5.1-MariaDB": false, "8.4.13": false, "5.5.5-10.11.19-MariaDB": false} {
		if TuningEngineSupported(mariaDBHookSupport(version)) != want {
			t.Fatal("native tuning version family/patch boundary changed")
		}
	}
}
