package mongodb

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/mongoscript"
	"dbeer/helper/internal/protocol"
	"go.mongodb.org/mongo-driver/v2/bson"
)

func (*Session) ExplainSupport() protocol.ExplainSupport {
	return protocol.ExplainSupport{Engine: "mongodb", ServerVersion: "MongoDB", Format: "mongodbExplain", DiagnosticModel: "mongodbExplain", Modes: []string{"plan", "analyze"}}
}
func (s *Session) PrepareExplain(r protocol.ExplainRequest) (adapter.PreparedExplain, error) {
	p := adapter.PreparedExplain{Request: r}
	script, err := mongoscript.Parse(r.SQL)
	if !r.Valid() || err != nil || script.Write || len(r.Parameters) != 0 || r.PlanKind != "" {
		return p, errors.New("MongoDB diagnostics require one read-only find or aggregate JSON request without parameters or output stages.")
	}
	if script.Database == "" {
		script.Database = s.database
	}
	if !mongoscript.ValidName(script.Database) {
		return p, errors.New("Select a MongoDB database before collecting diagnostics.")
	}
	if r.Context != nil && r.Context.TransactionStatus != "unsupported" {
		return p, errors.New("The MongoDB diagnostic session state changed.")
	}
	command := mongoExplainCommand(script, r.Mode)
	raw, err := bson.MarshalExtJSON(bson.D{{Key: "database", Value: script.Database}, {Key: "command", Value: command}}, true, false)
	if err != nil || len(raw) > 1024*1024+1024 {
		return p, errors.New("The MongoDB diagnostic request could not be represented within the review limit.")
	}
	p.Preview = protocol.ExplainPreview{SQL: string(raw), Mode: r.Mode, Support: s.ExplainSupport()}
	return p, nil
}
func mongoExplainCommand(s mongoscript.Script, mode string) bson.D {
	command := bson.D{}
	if s.Aggregate {
		command = append(command, bson.E{Key: "aggregate", Value: s.Collection}, bson.E{Key: "pipeline", Value: s.Pipeline}, bson.E{Key: "cursor", Value: bson.D{}}, bson.E{Key: "allowDiskUse", Value: false})
	} else {
		command = append(command, bson.E{Key: "find", Value: s.Collection}, bson.E{Key: "filter", Value: s.Filter})
		if len(s.Sort) > 0 {
			command = append(command, bson.E{Key: "sort", Value: s.Sort})
		}
		if len(s.Projection) > 0 {
			command = append(command, bson.E{Key: "projection", Value: s.Projection})
		}
		if s.Limit > 0 {
			command = append(command, bson.E{Key: "limit", Value: s.Limit})
		}
	}
	verbosity := "queryPlanner"
	if mode == "analyze" {
		verbosity = "executionStats"
	}
	return bson.D{{Key: "explain", Value: command}, {Key: "verbosity", Value: verbosity}}
}
func (s *Session) ExecuteExplain(ctx context.Context, c protocol.Command) protocol.Response {
	started := time.Now()
	reject := func(message string) protocol.Response {
		r := s.failure(c, "validation", message)
		r.SQLNotExecuted = true
		return r
	}
	if c.Explain == nil {
		return reject("Missing MongoDB diagnostic request.")
	}
	p, err := s.PrepareExplain(*c.Explain)
	if err != nil {
		return reject(err.Error())
	}
	if p.Preview.SQL != c.PreparedExplainSQL {
		return reject("MongoDB diagnostics require the exact reviewed command.")
	}
	script, _ := mongoscript.Parse(c.Explain.SQL)
	if script.Database == "" {
		script.Database = s.database
	}
	// RunCommand has no retryable-read label. A different verbosity is a separate
	// user-authorized operation; formatting never executes this request again.
	raw, err := s.client.Database(script.Database).RunCommand(ctx, mongoExplainCommand(script, c.Explain.Mode)).Raw()
	if err != nil {
		return safeError(c, ctx, err, false, nil)
	}
	result := mongoDiagnosticResult(p, raw)
	return protocol.Response{Type: "explain.result", RequestID: c.RequestID, SessionID: c.SessionID, QueryID: c.QueryID, Connected: true, TransactionStatus: "unsupported", SQLCompleted: true, DurationMS: float64(time.Since(started)) / float64(time.Millisecond), Explain: &result}
}
func diagnosticMetric(value any, unit, basis, reason string) protocol.DiagnosticMetric {
	m := protocol.DiagnosticMetric{Unit: unit, Basis: basis, UnavailableReason: reason}
	var text string
	switch v := value.(type) {
	case int32:
		if v >= 0 {
			text = strconv.FormatInt(int64(v), 10)
		}
	case int64:
		if v >= 0 {
			text = strconv.FormatInt(v, 10)
		}
	case float64:
		if v >= 0 && !math.IsNaN(v) && !math.IsInf(v, 0) {
			text = strconv.FormatFloat(v, 'g', -1, 64)
		}
	}
	if text != "" {
		m.Value = &text
		m.UnavailableReason = ""
	}
	return m
}
func mongoDiagnosticResult(p adapter.PreparedExplain, raw bson.Raw) protocol.ExplainResult {
	m := &protocol.MongoDBDiagnostic{Verbosity: "queryPlanner", Sections: []string{}, Stages: []protocol.MongoDBDiagnosticStage{}, Metrics: map[string]protocol.DiagnosticMetric{}}
	if p.Request.Mode == "analyze" {
		m.Verbosity = "executionStats"
	}
	reason := "notCollected"
	if p.Request.Mode == "analyze" {
		reason = "notReported"
	}
	for key, unit := range map[string]string{"nReturned": "documents", "totalKeysExamined": "keys", "totalDocsExamined": "documents", "executionTimeMillis": "ms"} {
		m.Metrics[key] = diagnosticMetric(nil, unit, "total", reason)
	}
	r := protocol.ExplainResult{Support: p.Preview.Support, Mode: p.Request.Mode, Status: "diagnostic", Complete: true, Roots: []string{}, Nodes: []protocol.ExplainNode{}, Metrics: map[string]protocol.ExplainMetric{}, EngineDiagnostic: &protocol.EngineDiagnostic{Kind: "mongodbExplain", MongoDB: m}, Diagnostic: "MongoDB stages and counters retain server meanings. Explain bypasses the plan cache; stage estimates are not exclusive time or an additive wall-clock total. Captured canonical BSON evidence omits server/session settings."}
	var doc bson.D
	if bson.Unmarshal(raw, &doc) != nil {
		r.Complete = false
		r.Diagnostic = "MongoDB confirmed the diagnostic command, but its BSON result could not be decoded."
		return r
	}
	sanitized := bson.D{}
	for _, e := range doc {
		if e.Key == "serverInfo" {
			if info, ok := e.Value.(bson.D); ok {
				for _, v := range info {
					if v.Key == "version" {
						if version, ok := v.Value.(string); ok && len(version) <= 256 {
							r.Support.ServerVersion = version
						}
					}
				}
			}
			continue
		}
		// Connection addresses and live server/session settings are not portable
		// evidence. Query context and exact canonical BSON values remain explicit.
		if e.Key == "serverParameters" || e.Key == "$clusterTime" || e.Key == "operationTime" {
			continue
		}
		sanitized = append(sanitized, e)
		if e.Key == "executionStats" {
			if stats, ok := e.Value.(bson.D); ok {
				for _, metric := range stats {
					if old, ok := m.Metrics[metric.Key]; ok {
						m.Metrics[metric.Key] = diagnosticMetric(metric.Value, old.Unit, old.Basis, "notReported")
					}
				}
			}
		}
	}
	var walk func(any, string, int)
	walk = func(value any, path string, depth int) {
		if depth > 128 || len(path) > 2048 {
			r.Complete = false
			return
		}
		switch value := value.(type) {
		case bson.D:
			stage := ""
			metrics := map[string]protocol.DiagnosticMetric{}
			for _, e := range value {
				if e.Key == "stage" {
					stage, _ = e.Value.(string)
				}
				switch e.Key {
				case "nReturned":
					metrics[e.Key] = diagnosticMetric(e.Value, "documents", "stage", "notReported")
				case "keysExamined":
					metrics[e.Key] = diagnosticMetric(e.Value, "keys", "stage", "notReported")
				case "docsExamined":
					metrics[e.Key] = diagnosticMetric(e.Value, "documents", "stage", "notReported")
				case "executionTimeMillisEstimate":
					metrics[e.Key] = diagnosticMetric(e.Value, "ms", "stageEstimate", "notReported")
				}
			}
			if stage == "" && strings.Contains(path, ":stages][") {
				for _, e := range value {
					if strings.HasPrefix(e.Key, "$") {
						stage = e.Key
						break
					}
				}
			}
			if stage != "" {
				if len(m.Stages) < protocol.MaxDiagnosticStages && len(stage) <= 1024 {
					m.Stages = append(m.Stages, protocol.MongoDBDiagnosticStage{Path: path, Operation: stage, Metrics: metrics})
				} else {
					r.Complete = false
				}
			}
			for i, e := range value {
				child := fmt.Sprintf("%s[%d:%s]", path, i, e.Key)
				if e.Key == "queryPlanner" || e.Key == "executionStats" || e.Key == "stages" || e.Key == "shards" {
					if len(m.Sections) < 1000 && len(child) <= 2048 {
						m.Sections = append(m.Sections, child)
					} else {
						r.Complete = false
					}
				}
				switch e.Key {
				default:
					if strings.HasSuffix(path, ":shards]") {
						walk(e.Value, child, depth+1)
					}
				case "queryPlanner", "executionStats", "stages", "shards", "winningPlan", "rejectedPlans", "queryPlan", "inputStage", "inputStages", "outerStage", "innerStage", "thenStage", "elseStage", "executionStages", "$cursor", "$geoNearCursor":
					walk(e.Value, child, depth+1)
				}
			}
		case bson.A:
			for i, e := range value {
				walk(e, fmt.Sprintf("%s[%d]", path, i), depth+1)
			}
		}
	}
	sanitized = sanitizeMongoEvidence(sanitized)
	walk(sanitized, "$", 0)
	encoded, err := bson.MarshalExtJSON(sanitized, true, false)
	if err != nil {
		r.Complete = false
		r.Diagnostic = "MongoDB confirmed the diagnostic command, but its output could not be retained."
		return r
	}
	if len(encoded) > protocol.MaxExplainRawBytes {
		encoded = encoded[:protocol.MaxExplainRawBytes]
		for !utf8.Valid(encoded) {
			encoded = encoded[:len(encoded)-1]
		}
		r.Complete = false
	}
	r.Raw = string(encoded)
	// The frame includes escaped canonical JSON and typed counters. Bound the
	// retained prefix after serialization without rerunning the database command.
	for {
		data, _ := json.Marshal(r)
		if len(data) <= protocol.MaxExplainResponseBytes {
			break
		}
		r.Complete = false
		if len(r.Raw) > 1024 {
			r.Raw = r.Raw[:len(r.Raw)/2]
			for !utf8.ValidString(r.Raw) {
				r.Raw = r.Raw[:len(r.Raw)-1]
			}
		} else {
			m.Stages = []protocol.MongoDBDiagnosticStage{}
			m.Sections = []string{}
			break
		}
	}
	if !r.Complete {
		r.Diagnostic += " Capture is incomplete; no operation was repeated."
	}
	return r
}

func sanitizeMongoEvidence(doc bson.D) bson.D {
	result := bson.D{}
	for _, e := range doc {
		switch e.Key {
		case "serverInfo", "serverParameters", "$clusterTime", "operationTime", "connectionString":
			continue
		}
		switch e.Key {
		case "command":
			if command, ok := e.Value.(bson.D); ok {
				clean := bson.D{}
				for _, field := range command {
					switch field.Key {
					case "lsid", "$clusterTime", "txnNumber", "autocommit", "startTransaction", "$readPreference", "readConcern", "writeConcern":
						continue
					}
					clean = append(clean, field)
				}
				e.Value = clean
			}
		case "queryPlanner", "executionStats", "stages", "shards", "winningPlan", "rejectedPlans", "queryPlan", "inputStage", "inputStages", "outerStage", "innerStage", "thenStage", "elseStage", "executionStages", "$cursor", "$geoNearCursor":
			switch value := e.Value.(type) {
			case bson.D:
				if e.Key == "shards" {
					for i, v := range value {
						if child, ok := v.Value.(bson.D); ok {
							value[i].Value = sanitizeMongoEvidence(child)
						}
					}
					e.Value = value
				} else {
					e.Value = sanitizeMongoEvidence(value)
				}
			case bson.A:
				for i, v := range value {
					if child, ok := v.(bson.D); ok {
						value[i] = sanitizeMongoEvidence(child)
					}
				}
				e.Value = value
			}
		}
		result = append(result, e)
	}
	return result
}
