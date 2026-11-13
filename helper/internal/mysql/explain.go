package mysql

import (
	"context"
	"errors"
	"regexp"
	"strconv"
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"

	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func (s *Session) ExplainSupport() protocol.ExplainSupport {
	support := adapter.ExplainSupport("mysql", s.work.client.GetServerVersion())
	if !strings.HasPrefix(s.explainVendor, "MySQL Community Server") && !strings.HasPrefix(s.explainVendor, "MySQL Enterprise Server") {
		support.Modes = []string{}
		support.Options = nil
		support.Notices = nil
		support.AnalyzeUnavailableReason = ""
		support.UnavailableReason = "Visual Explain requires a recognized Oracle MySQL server; this server vendor could not be verified."
	}
	return support
}
func (s *Session) PrepareExplain(r protocol.ExplainRequest) (adapter.PreparedExplain, error) {
	return adapter.PrepareExplain(s.ExplainSupport(), r)
}
func (s *Session) ExecuteExplain(ctx context.Context, c protocol.Command) protocol.Response {
	p, err := s.PrepareExplain(*c.Explain)
	if err == nil && p.Preview.SQL != c.PreparedExplainSQL {
		err = errors.New("Explain requires fresh authorization of the exact prepared SQL.")
	}
	if err != nil {
		r := protocol.ErrorResponse(c, "validation", err.Error())
		r.SQLNotExecuted = true
		r.Connected = !s.closed.Load()
		r.TransactionStatus = s.TransactionStatus()
		return r
	}
	capture := &adapter.ExplainCapture{}
	actualStarted := false
	response := s.executeWith(ctx, c, func(collector *collector, result *wire.Result) error {
		if p.Request.Mode == "analyze" && p.Preview.Format == "json" {
			// Read only: JSON v2 must already be selected in this physical session.
			// The probe shares cancellation/recovery with the single execution below.
			probe, err := s.work.client.Execute("SELECT @@SESSION.explain_json_format_version")
			if err != nil {
				return err
			}
			version, readErr := probe.GetInt(0, 0)
			valid := probe.RowNumber() == 1 && readErr == nil && version == 2
			probe.Close()
			if !valid {
				return &adapter.ConnectionError{Category: "validation", Message: "JSON Explain Analyze requires this session's explain_json_format_version to be 2. The analyzed SQL was not executed; choose TREE or explicitly configure the session first."}
			}
		}
		if ctx.Err() != nil {
			return &adapter.ConnectionError{Category: "cancelled", Message: "Explain was cancelled before the analyzed SQL was sent."}
		}
		actualStarted = true
		if len(p.Bound.Parameters) > 0 {
			bound := p.Bound
			bound.SQL = p.Preview.SQL
			return s.executeBoundResults(bound, collector, result)
		}
		return s.executeResults(p.Preview.SQL, collector, result)
	}, capture)
	if !actualStarted && response.Type == "error" {
		response.SQLNotExecuted = true
		response.OutcomeUnknown = false
	}
	// Decode only this captured response. Unknown formats never trigger execution.
	selected := p.Preview.Format
	if selected == "json" {
		p.Preview.Format = mysqlPlanFormat(capture.Raw)
	}
	parser := parseExplainTree
	if selected == "json" {
		parser = parseExplainJSON
	}
	finished := adapter.FinishExplain(ctx, c, response, p, capture, parser)
	return finished
}

const treeDecimal = `(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?`

var treeCost = regexp.MustCompile(` \(cost=(` + treeDecimal + `)(?:\.\.(` + treeDecimal + `))? rows=(` + treeDecimal + `)\)$`)
var treeActual = regexp.MustCompile(` \(actual time=(` + treeDecimal + `)\.\.(` + treeDecimal + `) rows=(` + treeDecimal + `) loops=(` + treeDecimal + `)\)$`)

func parseExplainTree(ctx context.Context, raw, mode string) ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error) {
	fail := func() ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error) {
		return nil, nil, nil, errors.New("unsupported TREE plan")
	}
	// Fold indented continuation lines before decoding trailing metric groups.
	// Raw Plan remains byte-for-byte unchanged in the response.
	logical := []string{}
	headerIndent := -1
	for _, line := range strings.Split(raw, "\n") {
		if ctx.Err() != nil {
			return fail()
		}
		text := strings.TrimSpace(line)
		if text == "" {
			continue
		}
		if strings.ContainsRune(line, '\t') {
			return fail()
		}
		indent := len(line) - len(strings.TrimLeft(line, " "))
		if strings.HasPrefix(text, "-> ") {
			if len(logical) >= protocol.MaxExplainNodes {
				return fail()
			}
			logical = append(logical, line)
			headerIndent = indent
		} else {
			if len(logical) == 0 || indent <= headerIndent {
				return fail()
			}
			last := len(logical) - 1
			if len(logical[last])+len(text)+1 > 65536 {
				return fail()
			}
			logical[last] += " " + text
		}
	}
	nodes := []protocol.ExplainNode{}
	roots := []string{}
	stack := []int{}
	indents := []int{}
	previousIndent := -1
	for _, line := range logical {
		if ctx.Err() != nil {
			return fail()
		}
		if strings.TrimSpace(line) == "" {
			continue
		}
		if strings.ContainsRune(line, '\t') {
			return fail()
		}
		indent := len(line) - len(strings.TrimLeft(line, " "))
		text := strings.TrimSpace(line)
		if indent%4 != 0 && strings.HasPrefix(text, "-> ") {
			return fail()
		}
		if !strings.HasPrefix(text, "-> ") {
			if len(nodes) == 0 || indent <= previousIndent {
				return fail()
			}
			last := &nodes[len(nodes)-1]
			last.Details["Continuation"] += strings.TrimSpace(line) + "\n"
			continue
		}
		text = strings.TrimPrefix(text, "-> ")
		if len(nodes) >= protocol.MaxExplainNodes {
			return fail()
		}
		node := protocol.ExplainNode{ID: strconv.Itoa(len(nodes)), Operation: text, Children: []string{}, Details: map[string]string{}, Metrics: map[string]protocol.ExplainMetric{}, Execution: "estimated"}
		for _, key := range []string{"startupCost", "totalCost", "estimatedRows", "actualRows", "loops", "startupTime", "totalTime"} {
			unit, basis, reason := "ms", "perInvocation", "notReported"
			switch key {
			case "startupCost", "totalCost":
				unit, basis = "cost", "inclusive"
			case "estimatedRows", "actualRows":
				unit = "rows"
			case "loops":
				unit, basis = "count", "total"
			}
			if mode == "plan" && (key == "actualRows" || key == "loops" || key == "startupTime" || key == "totalTime") {
				reason = "notCollected"
			}
			node.Metrics[key] = adapter.ExplainMetric(nil, unit, basis, reason)
		}
		set := func(key, value string) bool {
			if !protocol.ValidExplainDecimal(value) {
				return false
			}
			m := node.Metrics[key]
			m.Value = &value
			m.UnavailableReason = ""
			node.Metrics[key] = m
			return true
		}
		if strings.HasSuffix(text, " (never executed)") {
			if mode != "analyze" {
				return fail()
			}
			node.Execution = "notExecuted"
			text = strings.TrimSuffix(text, " (never executed)")
			for _, key := range []string{"actualRows", "loops", "startupTime", "totalTime"} {
				m := node.Metrics[key]
				m.UnavailableReason = "notExecuted"
				node.Metrics[key] = m
			}
		} else if m := treeActual.FindStringSubmatch(text); m != nil {
			if mode != "analyze" {
				return fail()
			}
			node.Execution = "executed"
			if !set("startupTime", m[1]) || !set("totalTime", m[2]) || !set("actualRows", m[3]) || !set("loops", m[4]) {
				return fail()
			}
			text = strings.TrimSuffix(text, m[0])
		}
		if m := treeCost.FindStringSubmatch(text); m != nil {
			total := m[1]
			if m[2] != "" {
				if !set("startupCost", m[1]) {
					return fail()
				}
				total = m[2]
			}
			if !set("totalCost", total) || !set("estimatedRows", m[3]) {
				return fail()
			}
			text = strings.TrimSuffix(text, m[0])
		}
		// A metric-like suffix that did not match is an unknown format, never a
		// confidently normalized partial plan. Parentheses in labels stay intact.
		if strings.Contains(text, " (actual time=") || strings.Contains(text, " (cost=") {
			return fail()
		}
		node.Operation = text
		if text == "" {
			return fail()
		}
		for len(stack) > 0 && indent <= indents[len(indents)-1] {
			stack = stack[:len(stack)-1]
			indents = indents[:len(indents)-1]
		}
		if len(stack) == 0 {
			if len(roots) > 0 || indent != 0 {
				return fail()
			}
			roots = append(roots, node.ID)
		} else {
			parent := stack[len(stack)-1]
			if indent != indents[len(indents)-1]+4 {
				return fail()
			}
			nodes[parent].Children = append(nodes[parent].Children, node.ID)
		}
		if len(stack)+1 > protocol.MaxExplainDepth {
			return fail()
		}
		stack = append(stack, len(nodes))
		indents = append(indents, indent)
		previousIndent = indent
		nodes = append(nodes, node)
	}
	if len(nodes) == 0 {
		return fail()
	}
	return nodes, roots, map[string]protocol.ExplainMetric{}, nil
}
