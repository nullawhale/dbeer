package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestMariaDBConnectionIdentityAndSessionPurposes(t *testing.T) {
	for _, purpose := range []string{"", "structure", "import", "monitor"} {
		connection := Connection{Engine: "mariadb", Host: "fixture.invalid", Port: 3306, Database: "fixture", User: "fixture", SSLMode: "verify-full", SessionPurpose: purpose}
		if !connection.Valid() || connection.DatabaseEngine() != "mariadb" {
			t.Fatal("explicit MariaDB identity or dedicated purpose was rejected")
		}
		raw, err := json.Marshal(connection)
		if err != nil {
			t.Fatal(err)
		}
		var observed Connection
		if json.Unmarshal(raw, &observed) != nil || observed.DatabaseEngine() != "mariadb" {
			t.Fatal("MariaDB connection identity changed during serialization")
		}
	}
	if (Connection{}).DatabaseEngine() != "postgresql" {
		t.Fatal("legacy omitted engine changed semantics")
	}
	connection := Connection{Engine: "mariadb", Host: "fixture.invalid", Port: 3306, Database: "fixture", User: "fixture", SessionPurpose: "foreignPurpose"}
	if connection.Valid() {
		t.Fatal("unknown session purpose accepted")
	}
}

func TestMariaDBDMLFormsAndNativeExecutionRemainExplicit(t *testing.T) {
	support := ExplainDMLSupport{Estimated: true, EstimatedForms: []string{"update", "delete"}, Analyze: []string{"update", "delete"}, AnalyzeTargetExecution: "executes"}
	if !support.Valid("mariadb") || !support.AllowsEstimated("update") || support.AllowsEstimated("insert") {
		t.Fatal("native MariaDB DML form boundary is invalid")
	}
	for _, changed := range []ExplainDMLSupport{
		{Estimated: true, Analyze: []string{}, AnalyzeTargetExecution: "unavailable"},
		{Estimated: true, EstimatedForms: []string{"insert"}, Analyze: []string{}, AnalyzeTargetExecution: "unavailable"},
		{Estimated: true, EstimatedForms: []string{"update", "update"}, Analyze: []string{}, AnalyzeTargetExecution: "unavailable"},
		{Estimated: true, EstimatedForms: []string{"update"}, Analyze: []string{"update"}, AnalyzeTargetExecution: "suppresses"},
	} {
		if changed.Valid("mariadb") {
			t.Fatal("missing/ambiguous native MariaDB DML support was admitted")
		}
	}
	if support.Valid("mysql") {
		t.Fatal("MariaDB forms weakened the legacy MySQL DML contract")
	}
}

func TestMariaDBSharedEngineFixture(t *testing.T) {
	raw, err := os.ReadFile("../../../protocol/fixtures/mariadb-engine-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Version              int
		Engine               string
		DefaultPort          int
		Connections          []Connection
		NativeValues         []NativeValue
		InvalidNativeValues  []json.RawMessage
		ExplainSupport       ExplainSupport
		DMLOutcomes          []ExplainDMLResult
		Metrics              map[string]ExplainMetric
		OptimizerObservation MariaDBOptimizerObservation
		OptimizerVariant     MariaDBOptimizerVariant
		NodeMetrics          ExplainNodeMetrics
	}
	if json.Unmarshal(raw, &f) != nil || f.Version != 1 || f.Engine != "mariadb" || f.DefaultPort != 3306 || len(f.Connections) != 3 || !f.ExplainSupport.Valid() {
		t.Fatal("invalid shared MariaDB engine fixture")
	}
	if !f.OptimizerObservation.Valid() || !f.OptimizerVariant.Valid() || !f.NodeMetrics.Valid("mariadb", ExplainNode{Execution: "executed"}, "analyze") || f.NodeMetrics.Counters["mariaDBPagesAccessed"].Value == nil || *f.NodeMetrics.Counters["mariaDBPagesAccessed"].Value != "9007199254740993" || f.NodeMetrics.Counters["mariaDBPagesReadTime"].Value == nil || *f.NodeMetrics.Counters["mariaDBPagesReadTime"].Value != "1.2300" {
		t.Fatal("native optimizer or exact total metrics fixture rejected")
	}
	for _, c := range f.Connections {
		if !c.Valid() || c.DatabaseEngine() != "mariadb" {
			t.Fatal("fixture connection changed engine identity")
		}
	}
	for _, v := range f.NativeValues {
		if !v.Valid() || v.Engine != "mariadb" {
			t.Fatal("valid native fixture rejected")
		}
	}
	for _, raw := range f.InvalidNativeValues {
		var v NativeValue
		if json.Unmarshal(raw, &v) == nil && v.Valid() {
			t.Fatal("invalid native fixture admitted")
		}
	}
	for _, o := range f.DMLOutcomes {
		if !o.Valid("mariadb", "analyze") {
			t.Fatal("native execution/transaction fixture rejected")
		}
	}
	for _, m := range f.Metrics {
		if !m.Valid() {
			t.Fatal("native metric basis fixture rejected")
		}
	}
}

func TestMariaDBDatabaseToolProtocolUsesNativeNamesAndSQL(t *testing.T) {
	connection := &Connection{Engine: "mariadb", Host: "fixture.invalid", Port: 3306, Database: "fixture", User: "fixture", SSLMode: "verify-full"}
	request := DatabaseToolsRequest{Connection: connection, Operation: "dump", Format: "sql", Path: "/tmp/fixture.sql", ToolPath: "/usr/local/bin/mariadb-dump"}
	if !request.Valid("dbtools.preview") {
		t.Fatal("native MariaDB SQL utility preview rejected")
	}
	for _, format := range []string{"custom", "tar"} {
		request.Format = format
		if request.Valid("dbtools.preview") {
			t.Fatal("MariaDB accepted a PostgreSQL-only utility archive format")
		}
	}
	reply := DatabaseToolsReply{PlanID: "plan", ApprovalToken: "approval", State: "prepared", Phase: "ready", Engine: "mariadb", Operation: "dump", Format: "sql", Database: "fixture", Path: "/tmp/fixture.sql", ToolName: "mariadb-dump", ToolVersion: "11.4.13", ServerVersion: "11.4.13-MariaDB", Warnings: []string{}}
	if !reply.Valid("dbtools.preview.result") {
		t.Fatal("native utility summary rejected")
	}
	reply.ToolName = "mysqldump"
	if reply.Valid("dbtools.preview.result") {
		t.Fatal("Oracle utility name was admitted for MariaDB")
	}
	reply.ToolName = "mariadb"
	reply.Operation = "restore"
	reply.RequiresConfirmation = true
	if !reply.Valid("dbtools.preview.result") {
		t.Fatal("reviewed native restore summary rejected")
	}
}

func TestMariaDBExplainCountersStayNativeAndTotal(t *testing.T) {
	value := "12345678901234567890"
	m := ExplainMetric{Value: &value, Unit: "count", Basis: "total"}
	if !validMariaDBExplainCounters(map[string]ExplainMetric{"mariaDBPagesAccessed": m}) {
		t.Fatal("native exact total counter rejected")
	}
	if validExplainCounters(map[string]ExplainMetric{"mariaDBPagesAccessed": m}, false) {
		t.Fatal("MariaDB counter leaked into legacy engine counters")
	}
	for _, metrics := range []map[string]ExplainMetric{
		nil,
		{"sharedReadBlocks": m},
		{"mariaDBPagesAccessed": {Value: &value, Unit: "blocks", Basis: "total"}},
		{"mariaDBPagesAccessed": {Value: &value, Unit: "count", Basis: "inclusiveTotal"}},
		{"mariaDBPagesAccessed": {Value: &value, Unit: "count", Basis: "perInvocation"}},
	} {
		if validMariaDBExplainCounters(metrics) {
			t.Fatal("foreign label, scope or unit was admitted as native MariaDB engine statistics")
		}
	}
}
