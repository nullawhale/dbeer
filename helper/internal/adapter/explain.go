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
	target, targetOK := safety.ClassifyExplainTarget(s.Engine, bound.AssessmentSQL)
	if !r.Valid() || err != nil || !targetOK {
		return p, errors.New("Visual Explain requires one unwrapped SELECT, INSERT, UPDATE, DELETE or supported CTE; client commands, wrappers and multiple statements are unavailable.")
	}
	if !s.Valid() || len(s.Modes) == 0 {
		return p, errors.New("Visual Explain is unavailable for this server version or engine fork.")
	}
	if target.DML() {
		form := target.Statement
		if target.DataModifyingCTE {
			form = "dataModifyingCTE"
		} else if (s.Engine == "mysql" || s.Engine == "mariadb") && target.MySQLMultiTable {
			if form == "update" {
				form = "mysqlMultiTableUpdate"
			} else {
				form = "mysqlMultiTableDelete"
			}
		}
		if s.DML == nil || !s.DML.AllowsEstimated(form) {
			return p, errors.New("Data-changing Explain is unavailable for this server.")
		}
		dml := protocol.ExplainDMLTarget{Statement: target.Statement, DataModifyingCTE: target.DataModifyingCTE, MySQLMultiTable: target.MySQLMultiTable}
		p.Preview.DML = &dml
		if r.Mode == "analyze" {
			if !explainContains(s.DML.Analyze, form) {
				return p, errors.New("Actual DML Analyze is unavailable for this statement form. PostgreSQL supports INSERT, UPDATE, DELETE and data-changing CTEs; MySQL supports only multi-table UPDATE/DELETE from 8.0.18. Choose estimated Explain; the SQL is never rewritten.")
			}
			if r.WriteIntent == nil || r.Context == nil {
				return p, errors.New("DML Analyze requires explicit current-session write intent and a fresh review of the exact values and transaction context.")
			}
		}
	} else if r.WriteIntent != nil {
		return p, errors.New("Write intent is valid only for data-changing Explain Analyze.")
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
	if !explainContains(s.Modes, r.Mode) {
		reason := s.AnalyzeUnavailableReason
		if reason == "" {
			reason = "The selected Explain mode is unavailable on this server."
		}
		return p, errors.New(reason)
	}
	if r.Options != nil && (!r.Options.ForEngine(s.Engine) || s.Options == nil) {
		return p, errors.New("The selected engine does not support these Explain options.")
	}
	p.Bound = bound
	format := s.Format
	if s.Engine == "postgresql" {
		options := []string{"ANALYZE FALSE", "COSTS TRUE"}
		if r.Mode == "analyze" {
			options = []string{"ANALYZE TRUE", "COSTS TRUE", "TIMING TRUE", "SUMMARY TRUE", "BUFFERS TRUE"}
		}
		if r.PlanKind == "generic" {
			options = []string{"ANALYZE FALSE", "GENERIC_PLAN TRUE", "COSTS TRUE"}
		}
		if r.Options != nil {
			pg := r.Options.PostgreSQL
			allowed := s.Options.PostgreSQL.Plan
			if r.Mode == "analyze" {
				allowed = s.Options.PostgreSQL.Analyze
			}
			for _, pair := range []struct {
				key   string
				value *bool
			}{{"buffers", pg.Buffers}, {"wal", pg.WAL}, {"settings", pg.Settings}, {"memory", pg.Memory}, {"timing", pg.Timing}} {
				if pair.value == nil {
					continue
				}
				if !explainContains(allowed, pair.key) {
					return p, errors.New("The selected PostgreSQL Explain option is unavailable for this server version or mode: " + pair.key + ".")
				}
				native := strings.ToUpper(pair.key)
				filtered := options[:0]
				for _, option := range options {
					if !strings.HasPrefix(option, native+" ") {
						filtered = append(filtered, option)
					}
				}
				options = append(filtered, native+" "+strings.ToUpper(strconv.FormatBool(*pair.value)))
			}
			if pg.Serialize != "" {
				if !explainContains(allowed, "serialize") {
					return p, errors.New("SERIALIZE requires PostgreSQL 17+ and Explain Analyze.")
				}
				options = append(options, "SERIALIZE "+strings.ToUpper(pg.Serialize))
			}
		}
		options = append(options, "VERBOSE TRUE")
		p.Prefix = "EXPLAIN (" + strings.Join(append(options, "FORMAT JSON"), ", ") + ")\n"
	} else if s.Engine == "mysql" {
		if r.Options != nil {
			format = r.Options.MySQL.Format
			if format == "auto" {
				format = s.Format
			}
			allowed := s.Options.MySQL.Plan
			if r.Mode == "analyze" {
				allowed = s.Options.MySQL.Analyze
			}
			if !explainContains(allowed, format) {
				return p, errors.New("The selected MySQL Explain format is unavailable for this server version or mode.")
			}
		}
		if r.Mode == "analyze" {
			// 8.0.18–20 supports Analyze only with its implicit TREE syntax.
			if mysqlVersionAtLeast(s.ServerVersion, 8, 0, 21) {
				p.Prefix = "EXPLAIN ANALYZE FORMAT=" + strings.ToUpper(format) + "\n"
			} else {
				p.Prefix = "EXPLAIN ANALYZE\n"
			}
		} else {
			p.Prefix = "EXPLAIN FORMAT=" + strings.ToUpper(format) + "\n"
		}
	} else if s.Engine == "mariadb" {
		p.Prefix = "EXPLAIN FORMAT=JSON\n"
		if r.Mode == "analyze" {
			p.Prefix = "ANALYZE FORMAT=JSON\n"
		}
	} else {
		return p, errors.New("Unsupported relational Explain engine.")
	}
	p.Preview = protocol.ExplainPreview{DML: p.Preview.DML, SQL: p.Prefix + bound.SQL, Mode: r.Mode, Support: s, Options: r.Options, Format: format}
	return p, nil
}

var explainVersion = regexp.MustCompile(`^([0-9]+)\.([0-9]+)(?:\.([0-9]+))?`)

// Oracle server version strings are complete three-part releases. Unknown
// distribution/fork suffixes do not inherit compatibility from their prefix.
var oracleExplainVersion = regexp.MustCompile(`^[1-9][0-9]*\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:standard|commercial)(?:-debug)?|-debug)?$`)

func explainContains(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}
func mysqlVersionAtLeast(version string, major, minor, patch int) bool {
	m := explainVersion.FindStringSubmatch(version)
	if len(m) != 4 {
		return false
	}
	a, _ := strconv.Atoi(m[1])
	b, _ := strconv.Atoi(m[2])
	c, _ := strconv.Atoi(m[3])
	return a > major || a == major && (b > minor || b == minor && c >= patch)
}
func ExplainSupport(engine, version string) protocol.ExplainSupport {
	s := protocol.ExplainSupport{Engine: engine, ServerVersion: version, Format: "tree", Modes: []string{}}
	m := explainVersion.FindStringSubmatch(version)
	major := 0
	if len(m) == 4 {
		major, _ = strconv.Atoi(m[1])
	}
	if engine == "postgresql" {
		s.Format = "json"
		if major >= 14 {
			s.Modes = []string{"plan", "analyze"}
			s.PlanKinds = []string{"custom"}
			if major >= 16 {
				s.PlanKinds = append(s.PlanKinds, "generic")
			}
			pg := &protocol.PostgresExplainOptionSupport{Plan: []string{"buffers", "settings"}, Analyze: []string{"buffers", "wal", "settings", "timing"}}
			if major >= 17 {
				pg.Plan = append(pg.Plan, "memory")
				pg.Analyze = append(pg.Analyze, "memory", "serialize")
			}
			s.Options = &protocol.ExplainOptionSupport{PostgreSQL: pg}
			s.DML = &protocol.ExplainDMLSupport{Estimated: true, Analyze: []string{"insert", "update", "delete", "dataModifyingCTE"}, AnalyzeTargetExecution: "executes"}
		}
	} else if engine == "mysql" && oracleExplainVersion.MatchString(version) && (strings.HasPrefix(version, "5.7.") || mysqlVersionAtLeast(version, 8, 0, 0)) {
		s.Format = "json"
		my := &protocol.MySQLExplainOptionSupport{Plan: []string{"json"}, Analyze: []string{}}
		s.Modes = []string{"plan"}
		s.AnalyzeUnavailableReason = "Explain Analyze requires Oracle MySQL 8.0.18+; this server supports estimated JSON plans only."
		if mysqlVersionAtLeast(version, 8, 0, 16) {
			my.Plan = append(my.Plan, "tree")
			s.Format = "tree"
		}
		if mysqlVersionAtLeast(version, 8, 0, 18) {
			s.Modes = append(s.Modes, "analyze")
			my.Analyze = append(my.Analyze, "tree")
			s.AnalyzeUnavailableReason = ""
		}
		if mysqlVersionAtLeast(version, 8, 0, 18) && !mysqlVersionAtLeast(version, 8, 0, 19) {
			s.Notices = append(s.Notices, "MySQL 8.0.18 Analyze does not evaluate SELECT-list expressions; its measurements exclude that work.")
		}
		if mysqlVersionAtLeast(version, 8, 0, 18) && !mysqlVersionAtLeast(version, 8, 0, 20) {
			s.Notices = append(s.Notices, "This MySQL version cannot stop Analyze with KILL QUERY. Stop may close the session after the recovery deadline; an unacknowledged execution remains unknown and is never retried.")
		}
		if mysqlVersionAtLeast(version, 8, 3, 0) {
			my.Analyze = append(my.Analyze, "json")
			my.JSONAnalyzeRequiresVersion2 = true
		}
		s.Options = &protocol.ExplainOptionSupport{MySQL: my}
		s.DML = &protocol.ExplainDMLSupport{Estimated: true, Analyze: []string{}, AnalyzeTargetExecution: "unavailable"}
		if mysqlVersionAtLeast(version, 8, 0, 18) {
			s.DML.Analyze = []string{"mysqlMultiTableUpdate", "mysqlMultiTableDelete"}
			s.DML.AnalyzeTargetExecution = "suppresses"
		}
	}
	if len(s.Modes) == 0 {
		s.UnavailableReason = "Visual Explain requires PostgreSQL 14+ or recognized Oracle MySQL 5.7+; MySQL Analyze requires 8.0.18+."
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
		response.ExplainDML = ExplainDMLOutcome(p, response)
		if p.Preview.DML != nil && response.TransactionStatus == "unknown" {
			response.TransactionStatus = ""
		}
		if response.ExplainDML != nil && response.ExplainDML.Execution == "unknown" || response.ExplainDML != nil && response.SQLCompleted && (response.ExplainDML.Persistence == "unknown" || response.ExplainDML.TransactionAfter == "unknown") {
			response.OutcomeUnknown = true
		}
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
	result := &protocol.ExplainResult{DML: ExplainDMLOutcome(p, response), Support: p.Preview.Support, Mode: p.Request.Mode, Options: p.Request.Options, Format: p.Preview.Format, Raw: c.Raw, Status: "rawOnly", Complete: !c.Limited, Roots: []string{}, Nodes: []protocol.ExplainNode{}, Metrics: map[string]protocol.ExplainMetric{}, Diagnostic: "The SQL completed, but its plan could not be visualized. Inspect Raw Plan."}
	if c.Limited {
		result.Status = "limited"
		result.Diagnostic = "The SQL completed. Plan capture exceeded 4 MiB; Raw Plan is an incomplete prefix."
	} else if !c.Invalid && ctx.Err() == nil {
		nodes, roots, metrics, err := parse(ctx, c.Raw, p.Request.Mode)
		if err == nil {
			result.Nodes, result.Roots, result.Metrics = nodes, roots, metrics
			if len(nodes) > 0 && nodes[0].AdvancedMetrics != nil {
				result.AdvancedMetrics = &protocol.ExplainPlanMetrics{Version: 1}
			}
			result.Status = "tree"
			result.Diagnostic = ""
			if !result.Valid() {
				result.AdvancedMetrics = nil
				result.Nodes = []protocol.ExplainNode{}
				result.Roots = []string{}
				result.Metrics = map[string]protocol.ExplainMetric{}
				result.Status = "rawOnly"
				result.Diagnostic = "The SQL completed, but plan structure exceeded visualization limits. Inspect Raw Plan."
			}
		}
	}
	if result.Status != "tree" && p.Preview.Support.Engine == "mysql" {
		// An undecodable response proves completion, not a recognized JSON version.
		result.Format = p.Preview.Support.Format
		if p.Request.Options != nil && p.Request.Options.MySQL != nil && p.Request.Options.MySQL.Format != "auto" {
			result.Format = p.Request.Options.MySQL.Format
		}
	}
	response = protocol.Response{Type: "explain.result", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID, DurationMS: response.DurationMS, TransactionStatus: response.TransactionStatus, Connected: response.Connected, SQLCompleted: true, Explain: result}
	encoded, _ := json.Marshal(response)
	if len(encoded) > protocol.MaxExplainResponseBytes {
		result.Status = "rawOnly"
		result.AdvancedMetrics = nil
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
