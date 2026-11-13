package protocol

import (
	"encoding/json"
	"errors"
	"unicode/utf8"
)

const EngineDiagnosticsCapability = "engineDiagnosticsV1"
const MaxDiagnosticStages = 1000
const MaxTraceEvents = 1000

// Engine diagnostics retain server-native meanings instead of treating traces
// or document execution stages as relational plan costs.
type DiagnosticMetric struct {
	Value             *string `json:"value,omitempty"`
	Unit              string  `json:"unit"`
	Basis             string  `json:"basis"`
	UnavailableReason string  `json:"unavailableReason,omitempty"`
}

func (m DiagnosticMetric) Valid() bool {
	switch m.Unit {
	case "documents", "keys", "ms", "us", "count":
	default:
		return false
	}
	switch m.Basis {
	case "total", "stage", "stageEstimate", "coordinator", "sourceElapsed":
	default:
		return false
	}
	if m.Value != nil {
		return m.UnavailableReason == "" && ValidExplainDecimal(*m.Value)
	}
	switch m.UnavailableReason {
	case "notCollected", "notReported", "unsupported", "notExecuted":
		return true
	}
	return false
}

type MongoDBDiagnosticStage struct {
	Path      string                      `json:"path"`
	Operation string                      `json:"operation"`
	Metrics   map[string]DiagnosticMetric `json:"metrics"`
}
type MongoDBDiagnostic struct {
	Verbosity string                      `json:"verbosity"`
	Sections  []string                    `json:"sections"`
	Stages    []MongoDBDiagnosticStage    `json:"stages"`
	Metrics   map[string]DiagnosticMetric `json:"metrics"`
}
type CassandraTraceEvent struct {
	ID            string           `json:"id"`
	Timestamp     string           `json:"timestamp"`
	Activity      string           `json:"activity"`
	Source        string           `json:"source"`
	Thread        string           `json:"thread"`
	SourceElapsed DiagnosticMetric `json:"sourceElapsed"`
}
type CassandraTraceSession struct {
	ID          string                `json:"id"`
	Command     string                `json:"command"`
	Coordinator string                `json:"coordinator"`
	StartedAt   string                `json:"startedAt"`
	Duration    DiagnosticMetric      `json:"duration"`
	Events      []CassandraTraceEvent `json:"events"`
}
type CassandraDiagnostic struct {
	Scope                 string                  `json:"scope"`
	CollectionConsistency string                  `json:"collectionConsistency"`
	PageSize              int                     `json:"pageSize"`
	HasMorePages          bool                    `json:"hasMorePages"`
	TraceSessions         []CassandraTraceSession `json:"traceSessions"`
	CollectionStatus      string                  `json:"collectionStatus"`
}
type EngineDiagnostic struct {
	Kind      string               `json:"kind"`
	MongoDB   *MongoDBDiagnostic   `json:"mongodb,omitempty"`
	Cassandra *CassandraDiagnostic `json:"cassandra,omitempty"`
}

func diagnosticText(s string, maximum int) bool { return len(s) <= maximum && utf8.ValidString(s) }
func diagnosticMetricsValid(m map[string]DiagnosticMetric) bool {
	if len(m) > 16 {
		return false
	}
	for k, v := range m {
		if !diagnosticText(k, 128) || !v.Valid() {
			return false
		}
	}
	return true
}
func (d EngineDiagnostic) Valid(engine, mode string) bool {
	if d.Kind == "mongodbExplain" {
		if engine != "mongodb" || d.MongoDB == nil || d.Cassandra != nil {
			return false
		}
		m := d.MongoDB
		expected := "queryPlanner"
		if mode == "analyze" {
			expected = "executionStats"
		}
		if m.Verbosity != expected || len(m.Sections) > 1000 || len(m.Stages) > MaxDiagnosticStages || !diagnosticMetricsValid(m.Metrics) {
			return false
		}
		for _, s := range m.Sections {
			if !diagnosticText(s, 2048) {
				return false
			}
		}
		seen := map[string]bool{}
		for _, s := range m.Stages {
			if !diagnosticText(s.Path, 2048) || s.Path == "" || seen[s.Path] || !diagnosticText(s.Operation, 1024) || s.Operation == "" || !diagnosticMetricsValid(s.Metrics) {
				return false
			}
			seen[s.Path] = true
		}
		return true
	}
	if d.Kind != "cassandraTrace" || engine != "cassandra" || mode != "analyze" || d.Cassandra == nil || d.MongoDB != nil {
		return false
	}
	c := d.Cassandra
	if c.Scope != "firstServerPage" || c.CollectionConsistency != "ONE" || c.PageSize != 200 || len(c.TraceSessions) > 4 {
		return false
	}
	switch c.CollectionStatus {
	case "observed", "partial", "unavailable", "cancelled", "limited":
	default:
		return false
	}
	events := 0
	seen := map[string]bool{}
	for _, s := range c.TraceSessions {
		if !ValidID(s.ID) || seen[s.ID] || !diagnosticText(s.Command, 256) || !diagnosticText(s.Coordinator, 256) || !diagnosticText(s.StartedAt, 64) || !s.Duration.Valid() || s.Duration.Unit != "us" || s.Duration.Basis != "coordinator" {
			return false
		}
		seen[s.ID] = true
		local := map[string]bool{}
		events += len(s.Events)
		if events > MaxTraceEvents {
			return false
		}
		for _, e := range s.Events {
			if !ValidID(e.ID) || local[e.ID] || !diagnosticText(e.Timestamp, 64) || !diagnosticText(e.Activity, 16384) || !diagnosticText(e.Source, 256) || !diagnosticText(e.Thread, 1024) || !e.SourceElapsed.Valid() || e.SourceElapsed.Unit != "us" || e.SourceElapsed.Basis != "sourceElapsed" {
				return false
			}
			local[e.ID] = true
		}
	}
	return true
}

// Reject unknown union tags and injected payloads before model publication.
func (d *EngineDiagnostic) UnmarshalJSON(data []byte) error {
	type plain EngineDiagnostic
	fields, ok := changesObject(data, "kind|mongodb|cassandra", "kind")
	if !ok {
		return errDiagnostic
	}
	var value plain
	if json.Unmarshal(data, &value) != nil {
		return errDiagnostic
	}
	if value.Kind == "mongodbExplain" {
		if _, ok = fields["mongodb"]; !ok || value.MongoDB == nil || len(fields) != 2 {
			return errDiagnostic
		}
	} else if value.Kind == "cassandraTrace" {
		if _, ok = fields["cassandra"]; !ok || value.Cassandra == nil || len(fields) != 2 {
			return errDiagnostic
		}
	} else {
		return errDiagnostic
	}
	*d = EngineDiagnostic(value)
	return nil
}

var errDiagnostic = errors.New("invalid engine diagnostic")
