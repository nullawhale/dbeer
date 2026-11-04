package protocol

import (
	"encoding/json"
	"regexp"
	"strings"
	"unicode/utf8"
)

const VisualExplainCapability = "visualExplainV1"
const MaxExplainRawBytes = 4 * 1024 * 1024
const MaxExplainNodes = 10000
const MaxExplainDepth = 128
const MaxExplainResponseBytes = 8 * 1024 * 1024

type ExplainRequest struct {
	SQL  string `json:"sql"`
	Mode string `json:"mode"`
}

func (r ExplainRequest) Valid() bool {
	return (r.Mode == "plan" || r.Mode == "analyze") && len(r.SQL) > 0 && len(r.SQL) <= 1024*1024 && utf8.ValidString(r.SQL) && !strings.ContainsRune(r.SQL, 0)
}
func parseExplain(raw json.RawMessage) (*ExplainRequest, bool) {
	if _, ok := changesObject(raw, "sql|mode", "sql", "mode"); !ok {
		return nil, false
	}
	var r ExplainRequest
	if json.Unmarshal(raw, &r) != nil || !r.Valid() {
		return nil, false
	}
	return &r, true
}

type ExplainSupport struct {
	Engine            string   `json:"engine"`
	ServerVersion     string   `json:"serverVersion"`
	Format            string   `json:"format"`
	Modes             []string `json:"modes"`
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
	Support    ExplainSupport           `json:"support"`
	Mode       string                   `json:"mode"`
	Status     string                   `json:"status"`
	Raw        string                   `json:"raw"`
	Complete   bool                     `json:"complete"`
	Diagnostic string                   `json:"diagnostic,omitempty"`
	Roots      []string                 `json:"roots"`
	Nodes      []ExplainNode            `json:"nodes"`
	Metrics    map[string]ExplainMetric `json:"metrics"`
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
	if s.Engine != "postgresql" && s.Engine != "mysql" && s.Engine != "sqlite" || len(s.ServerVersion) > 256 || len(s.Modes) > 2 {
		return false
	}
	if s.Engine == "sqlite" && (s.Format != "queryPlan" || len(s.Modes) != 1 || s.Modes[0] != "plan") || s.Engine == "postgresql" && s.Format != "json" || s.Engine == "mysql" && s.Format != "tree" {
		return false
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
