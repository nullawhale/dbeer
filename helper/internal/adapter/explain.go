package adapter

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/queryparams"
	"dbeer/helper/internal/safety"
)

type PreparedExplain struct {
	Request protocol.ExplainRequest
	Preview protocol.ExplainPreview
	Prefix  string
	Bound   queryparams.Bound
}
type ExplainSession interface {
	ExplainSupport() protocol.ExplainSupport
	PrepareExplain(protocol.ExplainRequest) (PreparedExplain, error)
	ExecuteExplain(context.Context, protocol.Command) protocol.Response
}

func PrepareExplain(s protocol.ExplainSupport, r protocol.ExplainRequest) (PreparedExplain, error) {
	p := PreparedExplain{Request: r}
	bound, err := queryparams.Bind(s.Engine, r.SQL, r.Parameters)
	if r.PlanKind == "generic" {
		bound, err = queryparams.BindGeneric(r.SQL, r.Parameters)
	}
	if !r.Valid() || err != nil || !safety.VisualExplainTarget(s.Engine, bound.AssessmentSQL) {
		return p, errors.New("Visual Explain requires one unwrapped SELECT or read CTE, without locking, known side effects, or client commands.")
	}
	if !s.Valid() || len(s.Modes) == 0 {
		return p, errors.New("Visual Explain is unavailable for this server version or engine fork.")
	}
	if r.PlanKind != "" {
		allowed := false
		for _, kind := range s.PlanKinds {
			if r.PlanKind == kind {
				allowed = true
			}
		}
		if !allowed {
			return p, errors.New("The selected PostgreSQL plan kind is unavailable. Generic plans require PostgreSQL 16+; Analyze requires a custom plan.")
		}
	}
	p.Bound = bound
	if s.Engine == "postgresql" {
		p.Prefix = "EXPLAIN (ANALYZE FALSE, COSTS TRUE, FORMAT JSON)\n"
		if r.Mode == "analyze" {
			p.Prefix = "EXPLAIN (ANALYZE TRUE, COSTS TRUE, TIMING TRUE, SUMMARY TRUE, BUFFERS TRUE, FORMAT JSON)\n"
		}
		if r.PlanKind == "generic" {
			p.Prefix = "EXPLAIN (ANALYZE FALSE, GENERIC_PLAN TRUE, COSTS TRUE, FORMAT JSON)\n"
		}
	} else {
		p.Prefix = "EXPLAIN FORMAT=TREE\n"
		if r.Mode == "analyze" {
			p.Prefix = "EXPLAIN ANALYZE FORMAT=TREE\n"
		}
	}
	p.Preview = protocol.ExplainPreview{SQL: p.Prefix + bound.SQL, Mode: r.Mode, Support: s}
	return p, nil
}

var explainVersion = regexp.MustCompile(`^([0-9]+)\.([0-9]+)(?:\.([0-9]+))?`)

// Oracle server version strings are complete three-part releases. Unknown
// distribution/fork suffixes do not inherit compatibility from their prefix.
var oracleExplainVersion = regexp.MustCompile(`^[1-9][0-9]*\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:standard|commercial)(?:-debug)?|-debug)?$`)

func ExplainSupport(engine, version string) protocol.ExplainSupport {
	s := protocol.ExplainSupport{Engine: engine, ServerVersion: version, Format: "tree", Modes: []string{}}
	if engine == "postgresql" {
		s.Format = "json"
	}
	m := explainVersion.FindStringSubmatch(version)
	valid := len(m) == 4
	major, minor, patch := 0, 0, 0
	if valid {
		major, _ = strconv.Atoi(m[1])
		minor, _ = strconv.Atoi(m[2])
		patch, _ = strconv.Atoi(m[3])
	}
	lower := strings.ToLower(version)
	if engine == "postgresql" {
		valid = valid && major >= 14
	} else {
		valid = valid && oracleExplainVersion.MatchString(version) && (major > 8 || major == 8 && (minor > 0 || patch >= 21)) && !strings.Contains(lower, "mariadb") && !strings.Contains(lower, "percona") && !strings.Contains(lower, "tidb") && !strings.Contains(lower, "aurora")
	}
	if valid {
		s.Modes = []string{"plan", "analyze"}
		if engine == "postgresql" {
			s.PlanKinds = []string{"custom"}
			if major >= 16 {
				s.PlanKinds = append(s.PlanKinds, "generic")
			}
		}
	} else {
		s.UnavailableReason = "Visual Explain requires PostgreSQL 14+ or Oracle MySQL 8.0.21+ with the supported plan format."
	}
	return s
}

// ExplainCapture receives every row before normal grid truncation. It retains a
// bounded prefix and continues draining SQL completion after the bound is hit.
type ExplainCapture struct {
	Raw     string
	Limited bool
	rows    int
	Invalid bool
}

func (c *ExplainCapture) Begin(_ int, columns []protocol.Column) error {
	if len(columns) != 1 {
		c.Invalid = true
	}
	return nil
}
func (c *ExplainCapture) Row(_ int, values []*string) error {
	if len(values) != 1 || values[0] == nil {
		c.Invalid = true
		return nil
	}
	c.rows++
	value := *values[0]
	if c.rows > 1 {
		value = "\n" + value
	}
	remaining := protocol.MaxExplainRawBytes - len(c.Raw)
	if len(value) > remaining {
		value = value[:remaining]
		for !utf8.ValidString(value) && len(value) > 0 {
			value = value[:len(value)-1]
		}
		c.Limited = true
	}
	if c.Raw == "" && value != "" {
		// A sliced first row could retain a much larger driver backing string.
		// Copy only the retained prefix so the capture limit also bounds memory.
		c.Raw = strings.Clone(value)
	} else {
		c.Raw += value
	}
	return nil
}
func (c *ExplainCapture) End(_ int, _ protocol.ResultSet) error { return nil }
func FinishExplain(ctx context.Context, command protocol.Command, response protocol.Response, p PreparedExplain, c *ExplainCapture, parse func(context.Context, string, string) ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error)) protocol.Response {
	if response.Type == "error" {
		if len(p.Request.Parameters) > 0 {
			response.ErrorPosition = 0
		}
		if response.ErrorPosition > 0 {
			prefix := utf8.RuneCountInString(p.Prefix)
			if response.ErrorPosition > prefix && response.ErrorPosition-prefix <= utf8.RuneCountInString(p.Request.SQL)+1 {
				response.ErrorPosition -= prefix
			} else {
				response.ErrorPosition = 0
			}
		}
		response.Columns = nil
		response.Rows = nil
		response.ResultSets = nil
		response.Source = nil
		response.StorageTokens = nil
		return response
	}
	result := &protocol.ExplainResult{Support: p.Preview.Support, Mode: p.Request.Mode, Raw: c.Raw, Status: "rawOnly", Complete: !c.Limited, Roots: []string{}, Nodes: []protocol.ExplainNode{}, Metrics: map[string]protocol.ExplainMetric{}, Diagnostic: "The SQL completed, but its plan could not be visualized. Inspect Raw Plan."}
	if c.Limited {
		result.Status = "limited"
		result.Diagnostic = "The SQL completed. Plan capture exceeded 4 MiB; Raw Plan is an incomplete prefix."
	} else if !c.Invalid && ctx.Err() == nil {
		nodes, roots, metrics, err := parse(ctx, c.Raw, p.Request.Mode)
		if err == nil {
			result.Nodes, result.Roots, result.Metrics = nodes, roots, metrics
			result.Status = "tree"
			result.Diagnostic = ""
			if !result.Valid() {
				result.Nodes = []protocol.ExplainNode{}
				result.Roots = []string{}
				result.Metrics = map[string]protocol.ExplainMetric{}
				result.Status = "rawOnly"
				result.Diagnostic = "The SQL completed, but plan structure exceeded visualization limits. Inspect Raw Plan."
			}
		}
	}
	response = protocol.Response{Type: "explain.result", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID, DurationMS: response.DurationMS, TransactionStatus: response.TransactionStatus, Connected: response.Connected, SQLCompleted: true, Explain: result}
	encoded, _ := json.Marshal(response)
	if len(encoded) > protocol.MaxExplainResponseBytes {
		result.Status = "rawOnly"
		result.Nodes = []protocol.ExplainNode{}
		result.Roots = []string{}
		result.Metrics = map[string]protocol.ExplainMetric{}
		result.Diagnostic = "The SQL completed, but normalized plan data exceeded the response limit. Inspect Raw Plan."
		encoded, _ = json.Marshal(response)
		if len(encoded) > protocol.MaxExplainResponseBytes {
			result.Raw = c.Raw
			result.Status = "limited"
			result.Complete = false
			result.Diagnostic = "The SQL completed, but escaped plan text exceeded the response limit. Raw Plan is an incomplete prefix."
			for {
				encoded, _ = json.Marshal(response)
				if len(encoded) <= protocol.MaxExplainResponseBytes {
					break
				}
				prefix := len(result.Raw) / 2
				for prefix > 0 && !utf8.ValidString(result.Raw[:prefix]) {
					prefix--
				}
				result.Raw = result.Raw[:prefix]
			}
		}
	}
	return response
}
func ExplainMetric(value *string, unit, basis, reason string) protocol.ExplainMetric {
	m := protocol.ExplainMetric{Value: value, Unit: unit, Basis: basis}
	if value == nil {
		m.UnavailableReason = reason
	}
	return m
}
