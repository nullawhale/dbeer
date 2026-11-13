package protocol

import (
	"encoding/json"
	"regexp"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

const VisualExplainCapability = "visualExplainV1"
const ExplainParametersCapability = "explainParametersV1"
const MaxExplainRawBytes = 4 * 1024 * 1024
const MaxExplainNodes = 10000
const MaxExplainDepth = 128
const MaxExplainResponseBytes = 8 * 1024 * 1024

// Context is transient execution ownership. Portable artifacts retain the source
// range separately and must never retain session handles or authorization.
type ExplainContext struct {
	DocumentID        string `json:"documentId"`
	TargetDocumentID  string `json:"targetDocumentId"`
	RangeLocation     int    `json:"rangeLocation"`
	RangeLength       int    `json:"rangeLength"`
	ProfileID         string `json:"profileId"`
	SessionID         string `json:"sessionId"`
	TransactionStatus string `json:"transactionStatus"`
}

func (c ExplainContext) Valid() bool {
	return ValidID(c.DocumentID) && ValidID(c.TargetDocumentID) && ValidID(c.ProfileID) && ValidID(c.SessionID) &&
		c.RangeLocation >= 0 && c.RangeLocation <= 16*1024*1024 && c.RangeLength > 0 && c.RangeLength <= 1024*1024 &&
		(c.TransactionStatus == "idle" || c.TransactionStatus == "transaction" || c.TransactionStatus == "failedTransaction" || c.TransactionStatus == "unsupported")
}

type ExplainRequest struct {
	SQL        string           `json:"sql"`
	Mode       string           `json:"mode"`
	Parameters []QueryParameter `json:"parameters,omitempty"`
	PlanKind   string           `json:"planKind,omitempty"`
	Context    *ExplainContext  `json:"context,omitempty"`
}

func (r ExplainRequest) Valid() bool {
	return (r.Mode == "plan" || r.Mode == "analyze") && len(r.SQL) > 0 && len(r.SQL) <= 1024*1024 && utf8.ValidString(r.SQL) && !strings.ContainsRune(r.SQL, 0) &&
		QueryParametersValid(r.Parameters) && (r.PlanKind == "" || r.PlanKind == "custom" || r.PlanKind == "generic" && r.Mode == "plan") &&
		(r.Context == nil || r.Context.Valid() && r.Context.RangeLength == len(utf16.Encode([]rune(r.SQL))))
}
func parseExplain(raw json.RawMessage) (*ExplainRequest, bool) {
	fields, ok := changesObject(raw, "sql|mode|parameters|planKind|context", "sql", "mode")
	if !ok {
		return nil, false
	}
	var r ExplainRequest
	if !stringField(fields, "sql", &r.SQL) || !stringField(fields, "mode", &r.Mode) {
		return nil, false
	}
	if v, exists := fields["parameters"]; exists {
		r.Parameters, ok = parseQueryParameters(v)
		if !ok {
			return nil, false
		}
	}
	if _, exists := fields["planKind"]; exists && !stringField(fields, "planKind", &r.PlanKind) {
		return nil, false
	}
	if v, exists := fields["context"]; exists {
		if _, ok := changesObject(v, "documentId|targetDocumentId|rangeLocation|rangeLength|profileId|sessionId|transactionStatus", "documentId", "targetDocumentId", "rangeLocation", "rangeLength", "profileId", "sessionId", "transactionStatus"); !ok {
			return nil, false
		}
		var c ExplainContext
		if json.Unmarshal(v, &c) != nil || !c.Valid() {
			return nil, false
		}
		r.Context = &c
	}
	return &r, r.Valid()
}

type ExplainSupport struct {
	DiagnosticModel   string   `json:"diagnosticModel,omitempty"`
	Engine            string   `json:"engine"`
	ServerVersion     string   `json:"serverVersion"`
	Format            string   `json:"format"`
	Modes             []string `json:"modes"`
	PlanKinds         []string `json:"planKinds,omitempty"`
	UnavailableReason string   `json:"unavailableReason,omitempty"`
}
type ExplainPreview struct {
	SQL     string         `json:"sql"`
	Mode    string         `json:"mode"`
	Support ExplainSupport `json:"support"`
}
type ExplainMetric struct {
	Value             *string `json:"value,omitempty"`
	Unit              string  `json:"unit"`
	Basis             string  `json:"basis"`
	UnavailableReason string  `json:"unavailableReason,omitempty"`
}
type ExplainNode struct {
	ID        string                   `json:"id"`
	Children  []string                 `json:"children"`
	Operation string                   `json:"operation"`
	Details   map[string]string        `json:"details"`
	Execution string                   `json:"execution"`
	Metrics   map[string]ExplainMetric `json:"metrics"`
}
type ExplainResult struct {
	EngineDiagnostic *EngineDiagnostic        `json:"engineDiagnostic,omitempty"`
	Support          ExplainSupport           `json:"support"`
	Mode             string                   `json:"mode"`
	Status           string                   `json:"status"`
	Raw              string                   `json:"raw"`
	Complete         bool                     `json:"complete"`
	Diagnostic       string                   `json:"diagnostic,omitempty"`
	Roots            []string                 `json:"roots"`
	Nodes            []ExplainNode            `json:"nodes"`
	Metrics          map[string]ExplainMetric `json:"metrics"`
}

var explainDecimal = regexp.MustCompile(`^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$`)

func ValidExplainDecimal(s string) bool { return len(s) <= 128 && explainDecimal.MatchString(s) }
func (m ExplainMetric) Valid() bool {
	if m.Unit != "cost" && m.Unit != "rows" && m.Unit != "ms" && m.Unit != "count" {
		return false
	}
	if m.Basis != "inclusive" && m.Basis != "perInvocation" && m.Basis != "total" {
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
func (s ExplainSupport) Valid() bool {
	if s.Engine != "postgresql" && s.Engine != "mysql" && s.Engine != "sqlite" && s.Engine != "mongodb" && s.Engine != "cassandra" || len(s.ServerVersion) > 256 || len(s.Modes) > 2 {
		return false
	}
	if s.Engine == "sqlite" && (s.Format != "queryPlan" || len(s.Modes) != 1 || s.Modes[0] != "plan") || s.Engine == "postgresql" && s.Format != "json" || s.Engine == "mysql" && s.Format != "tree" {
		return false
	}
	if s.Engine == "mongodb" {
		if s.Format != "mongodbExplain" || s.DiagnosticModel != "mongodbExplain" {
			return false
		}
	} else if s.Engine == "cassandra" {
		if s.Format != "cassandraTrace" || s.DiagnosticModel != "cassandraTrace" || len(s.Modes) != 1 || s.Modes[0] != "analyze" {
			return false
		}
	} else if s.DiagnosticModel != "" {
		return false
	}
	if len(s.PlanKinds) > 2 || s.Engine != "postgresql" && len(s.PlanKinds) != 0 {
		return false
	}
	kinds := map[string]bool{}
	for _, k := range s.PlanKinds {
		if (k != "custom" && k != "generic") || kinds[k] {
			return false
		}
		kinds[k] = true
	}
	seen := map[string]bool{}
	for _, m := range s.Modes {
		if (m != "plan" && m != "analyze") || seen[m] {
			return false
		}
		seen[m] = true
	}
	return len(s.Modes) > 0 && s.UnavailableReason == "" || len(s.Modes) == 0 && s.UnavailableReason != ""
}
func (r ExplainResult) Valid() bool {
	supported := false
	for _, mode := range r.Support.Modes {
		if mode == r.Mode {
			supported = true
		}
	}
	if !supported || !r.Support.Valid() || (r.Mode != "plan" && r.Mode != "analyze") || len(r.Raw) > MaxExplainRawBytes || !utf8.ValidString(r.Raw) || len(r.Nodes) > MaxExplainNodes || len(r.Metrics) > 16 || len(r.Diagnostic) > 4096 {
		return false
	}
	if r.Support.Engine == "cassandra" && r.Complete {
		return false
	}
	if r.Support.Engine == "mongodb" || r.Support.Engine == "cassandra" {
		if r.EngineDiagnostic == nil || !r.EngineDiagnostic.Valid(r.Support.Engine, r.Mode) || r.Status != "diagnostic" || len(r.Nodes) != 0 || len(r.Roots) != 0 || len(r.Metrics) != 0 || r.Diagnostic == "" {
			return false
		}
		return true
	} else if r.EngineDiagnostic != nil {
		return false
	}
	if r.Status != "tree" && r.Status != "rawOnly" && r.Status != "limited" {
		return false
	}
	if r.Status == "tree" && (!r.Complete || len(r.Nodes) == 0 || len(r.Roots) == 0 || r.Diagnostic != "") {
		return false
	}
	if r.Status != "tree" && (len(r.Nodes) != 0 || len(r.Roots) != 0 || r.Diagnostic == "") {
		return false
	}
	if r.Status == "limited" && r.Complete {
		return false
	}
	for _, m := range r.Metrics {
		if !m.Valid() {
			return false
		}
	}
	nodes := map[string]ExplainNode{}
	for _, n := range r.Nodes {
		if !ValidID(n.ID) || n.Operation == "" || len(n.Operation) > 65536 || len(n.Details) > 128 || len(n.Metrics) > 32 || len(n.Children) > MaxExplainNodes || nodes[n.ID].ID != "" {
			return false
		}
		if n.Execution != "estimated" && n.Execution != "executed" && n.Execution != "notExecuted" {
			return false
		}
		for k, v := range n.Details {
			if len(k) > 1024 || len(v) > 65536 {
				return false
			}
		}
		for _, m := range n.Metrics {
			if !m.Valid() {
				return false
			}
		}
		nodes[n.ID] = n
	}
	seen := map[string]bool{}
	var visit func(string, int) bool
	visit = func(id string, depth int) bool {
		n, ok := nodes[id]
		if !ok || seen[id] || depth > MaxExplainDepth {
			return false
		}
		seen[id] = true
		for _, child := range n.Children {
			if !visit(child, depth+1) {
				return false
			}
		}
		return true
	}
	for _, id := range r.Roots {
		if !visit(id, 1) {
			return false
		}
	}
	return len(seen) == len(nodes)
}
