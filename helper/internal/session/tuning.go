package session

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/queryparams"
	"dbeer/helper/internal/safety"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
)

var tuningSelect = regexp.MustCompile(`(?i)^SELECT\s+([a-z_][a-z0-9_]*(?:\s*,\s*[a-z_][a-z0-9_]*)*)\s+FROM\s+([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)\s+WHERE\s+(.+)$`)
var tuningEquality = regexp.MustCompile(`^([a-z_][a-z0-9_]*)\s*=\s*(:[a-zA-Z_][a-zA-Z0-9_]*|-?(?:0|[1-9][0-9]*))$`)
var tuningIn = regexp.MustCompile(`(?i)^([a-z_][a-z0-9_]*)\s+IN\s*\(([^()]*)\)$`)
var tuningOr = regexp.MustCompile(`(?i)\s+OR\s+`)

type tuningQuery struct {
	projected []string
	column    string
	values    []string
	prefix    string
	or        bool
}

// shortcut: only column projections and integer/typed numeric equality lists,
// expand with a dialect AST and catalog routine/operator proof before other SQL.
func parseTuningQuery(engine string, r protocol.ExplainRequest, target tableedit.Target) (tuningQuery, bool) {
	var q tuningQuery
	if r.WriteIntent != nil || !r.Valid() || len(r.SQL) > 65536 {
		return q, false
	}
	sql := strings.TrimSpace(r.SQL)
	sql = strings.TrimSuffix(sql, ";")
	sql = strings.TrimSpace(sql)
	m := tuningSelect.FindStringSubmatch(sql)
	if m == nil || strings.ToLower(m[2]) != target.Schema || strings.ToLower(m[3]) != target.Table {
		return q, false
	}
	if !asciiTuningName(m[2]) || !asciiTuningName(m[3]) {
		return q, false
	}
	for _, c := range strings.Split(m[1], ",") {
		name := strings.TrimSpace(c)
		if !asciiTuningName(name) {
			return q, false
		}
		q.projected = append(q.projected, strings.ToLower(name))
	}
	if len(q.projected) > 128 {
		return q, false
	}
	q.prefix = sql[:len(sql)-len(m[4])]
	if in := tuningIn.FindStringSubmatch(m[4]); in != nil {
		if !asciiTuningName(in[1]) {
			return q, false
		}
		q.column = strings.ToLower(in[1])
		q.values = strings.Split(in[2], ",")
		for i, v := range q.values {
			q.values[i] = strings.TrimSpace(v)
			if !tuningEquality.MatchString(q.column + " = " + q.values[i]) {
				return q, false
			}
		}
	} else {
		terms := tuningOr.Split(m[4], -1)
		q.or = len(terms) > 1
		for _, term := range terms {
			eq := tuningEquality.FindStringSubmatch(strings.TrimSpace(term))
			if eq == nil {
				return q, false
			}
			if q.column == "" {
				q.column = eq[1]
			}
			if q.column != eq[1] {
				return q, false
			}
			q.values = append(q.values, eq[2])
		}
	}
	if len(q.values) < 1 || len(q.values) > 16 {
		return q, false
	}
	for _, v := range q.values {
		if strings.HasPrefix(v, ":") {
			found := false
			for _, p := range r.Parameters {
				if p.Name == v[1:] && (p.Type == "integer" || p.Type == "decimal") {
					found = true
				}
			}
			if !found {
				return q, false
			}
		} else if _, err := strconv.ParseInt(v, 10, 64); err != nil {
			return q, false
		}
	}
	bound, err := queryparams.Bind(engine, r.SQL, r.Parameters)
	if err != nil {
		return q, false
	}
	statements := safety.Classify(engine, bound.AssessmentSQL)
	return q, len(statements) == 1 && statements[0].Kind == safety.Read
}
func tuningAvailable(physical adapter.Session) bool {
	explain, ok := physical.(adapter.ExplainSession)
	if !ok {
		return false
	}
	s := explain.ExplainSupport()
	_, catalog := physical.(tableedit.Adapter)
	_, stream := physical.(adapter.StreamingSession)
	return catalog && stream && adapter.TuningEngineSupported(s)
}
func (owner *owner) tuningContext(c *protocol.ExplainContext, physical adapter.Session) bool {
	return c != nil && c.Valid() && c.SessionID == owner.id && c.TransactionStatus == physical.TransactionStatus() && (c.TransactionStatus == "idle" || c.TransactionStatus == "transaction")
}
func (owner *owner) tuningOperationValid(op protocol.OperationRequest, physical adapter.Session) bool {
	if !tuningAvailable(physical) || owner.structureOnly || owner.importOnly || owner.monitorOnly {
		return false
	}
	s := physical.(adapter.ExplainSession).ExplainSupport()
	if op.Type == "tuning.setting" {
		return s.Engine == "postgresql" && op.TuningSetting != nil && op.TuningSetting.Valid() && owner.tuningContext(&op.TuningSetting.Context, physical)
	}
	if op.TuningValidation == nil || !op.TuningValidation.Valid() || !owner.tuningContext(op.TuningValidation.Original.Context, physical) || !owner.tuningContext(op.TuningValidation.Variant.Context, physical) {
		return false
	}
	_, a := parseTuningQuery(s.Engine, op.TuningValidation.Original, op.TuningValidation.Target)
	_, b := parseTuningQuery(s.Engine, op.TuningValidation.Variant, op.TuningValidation.Target)
	return a && b
}
func tuningCatalogSafe(b tableedit.Baseline, q tuningQuery) bool {
	if b.Advanced != nil {
		return false
	}
	if !b.DependencyProof || b.Facts == nil || !b.Facts.Proof || !b.Facts.Table.Columns.Complete || !b.Facts.Table.Indexes.Complete || !b.Facts.Table.Constraints.Complete || !tableedit.IsDigest(b.Fingerprint) {
		return false
	}
	for _, index := range b.Indexes {
		d := index.Definition
		if d == nil || d.Method != "btree" || d.Predicate != nil || d.Visible != nil && !*d.Visible {
			return false
		}
		for i, term := range d.Terms {
			if term.Column == nil || term.Expression != nil || term.PrefixLength != nil {
				return false
			}
			if b.Engine == "postgresql" {
				defaults := b.Facts.IndexDefaultOpclasses[index.Name]
				if term.Collation != nil {
					collations := b.Facts.IndexDefaultCollations[index.Name]
					if len(collations) != len(d.Terms) || !collations[i] {
						return false
					}
				}
				if len(defaults) != len(d.Terms) || !defaults[i] {
					return false
				}
			}
		}
	}
	for _, name := range append(append([]string{}, q.projected...), q.column) {
		c, ok := tableedit.FindColumn(b, name)
		if !ok || c.Type.Value == nil || c.Type.Value.Kind != "builtin" || c.Generated.Value == nil || c.Generated.Value.Kind != "none" {
			return false
		}
		if c.Type.Value.Modifiers.Value == nil || c.Type.Value.Modifiers.Value.ArrayDimensions != 0 {
			return false
		}
		native := c.Type.Value.Ref.Name
		if b.Engine == "postgresql" {
			expected := map[string]string{"int2": "21", "int4": "23", "int8": "20", "numeric": "1700", "varchar": "1043", "text": "25", "bool": "16", "bytea": "17", "float4": "700", "float8": "701"}[native]
			oid := fmt.Sprint(b.Attributes[name]["atttypid"])
			if c.Type.Value.Ref.Schema != "pg_catalog" || expected == "" || oid != expected {
				return false
			}
		} else if !map[string]bool{"tinyint": true, "smallint": true, "mediumint": true, "int": true, "integer": true, "bigint": true, "decimal": true, "numeric": true, "varchar": true, "text": true, "tinytext": true, "mediumtext": true, "longtext": true, "tinyblob": true, "blob": true, "mediumblob": true, "longblob": true, "varbinary": true, "binary": true, "float": true, "double": true}[native] {
			return false
		}
		if name == q.column && !map[string]bool{"int4": true, "int8": true, "numeric": true, "int": true, "integer": true, "bigint": true, "decimal": true}[native] {
			return false
		}
	}
	return true
}
func tuningInspection(r protocol.TuningInspectRequest, b tableedit.Baseline) protocol.TuningInspection {
	out := protocol.TuningInspection{Version: 1, Engine: r.Capture.Support.Engine, ServerVersion: r.Capture.Support.ServerVersion, EvidenceOrigin: "suppliedCapture", MetadataFingerprint: b.Fingerprint, Target: r.Target, Indexes: []protocol.TuningIndexAdvice{}, Variants: []protocol.TuningVariant{}, Limitations: []string{"Captured plan evidence was supplied by the client and is not execution authority. Current metadata does not prove capture ownership or freshness.", "Candidates do not predict a speedup. Indexes add storage, build locking and write maintenance; review a fresh dedicated table-structure preview before applying.", "Only a single explicitly qualified ordinary table, numeric equality predicates and built-in projected columns are supported. No functions, joins, CTEs, views, temporary tables, ORDER BY or LIMIT are admitted."}}
	q, ok := parseTuningQuery(b.Engine, r.Source, r.Target)
	if !b.DependencyProof || b.Facts == nil || !b.Facts.Proof {
		out.Limitations = append(out.Limitations, "Complete catalog index/key/dependency visibility is unavailable. MySQL requires the E2 global SELECT and TRIGGER metadata proof; an incomplete catalog cannot prove that an index is absent or safe to reuse.")
		return out
	}
	if !ok || !tuningCatalogSafe(b, q) || r.Capture.Status != "tree" || !r.Capture.Complete || r.Capture.DML != nil {
		out.Limitations = append(out.Limitations, "No candidate: complete matching supported query, plan and catalog evidence is unavailable.")
		return out
	}
	if q.or {
		variant := r.Source
		variant.Mode = "plan"
		variant.SQL = q.prefix + q.column + " IN (" + strings.Join(q.values, ", ") + ")"
		contextCopy := *variant.Context
		contextCopy.RangeLength = len(utf16.Encode([]rune(variant.SQL)))
		variant.Context = &contextCopy
		out.Variants = append(out.Variants, protocol.TuningVariant{ID: "or-to-in", Kind: "sameColumnOrToIn", Explanation: "Replace repeated numeric equalities on the same column with an IN list. The optimizer may already produce the same access path; no performance gain or result equivalence is claimed.", Validation: "unvalidated", Request: variant})
	}
	var scan *protocol.ExplainNode
	for i, n := range r.Capture.Nodes {
		match := b.Engine == "postgresql" && n.Operation == "Seq Scan" && n.Details["Schema"] == b.Target.Schema && n.Details["Relation Name"] == b.Target.Table
		match = match || b.Engine == "mysql" && (n.Operation == "Table access ALL on "+b.Target.Table || n.Operation == "Table scan on "+b.Target.Table)
		if match {
			if scan != nil {
				out.Limitations = append(out.Limitations, "Multiple matching scans are ambiguous; no index candidate is emitted.")
				return out
			}
			scan = &r.Capture.Nodes[i]
		}
	}
	if scan == nil {
		out.Limitations = append(out.Limitations, "No matching full-table scan was captured; no index candidate is emitted.")
		return out
	}
	// An unknown/partial expression index might already cover the workload. Do not
	// call it absent just because its simplified editable projection is missing.
	for _, index := range b.Indexes {
		d := index.Definition
		if d == nil || len(d.Terms) == 0 {
			out.Limitations = append(out.Limitations, "An index has incomplete definition evidence; duplicate-index advice is suppressed.")
			return out
		}
		if d.Terms[0].Column != nil && *d.Terms[0].Column == q.column {
			out.Limitations = append(out.Limitations, "An existing leading index term already uses the predicate column; review that index and its owning key before adding another.")
			return out
		}
	}
	for _, key := range b.Keys {
		if (key.Kind == "primary" || key.Kind == "unique") && len(key.Columns) > 0 && key.Columns[0] == q.column {
			out.Limitations = append(out.Limitations, "An existing primary or unique key already leads with the predicate column; its owned index must be preserved.")
			return out
		}
	}
	name := "dbeer_" + q.column + "_idx"
	if len(name) > 63 {
		name = name[:63]
	}
	for _, x := range b.Indexes {
		if x.Name == name {
			out.Limitations = append(out.Limitations, "The proposed index name is already in use; choose a name in the structure editor.")
			return out
		}
	}
	col := q.column
	advice := protocol.TuningIndexAdvice{ID: "numeric-equality-index", NodeID: scan.ID, Explanation: "A captured full-table scan serves a numeric equality predicate without a known leading index on that column. A nonunique B-tree is a candidate for selective lookups; a full scan can still be cheaper.", Evidence: []string{"Engine " + out.Engine + " " + out.ServerVersion, "Captured node " + scan.ID + ": " + scan.Operation, "Current complete catalog fingerprint: " + b.Fingerprint, "Predicate column: " + q.column}, Limitations: []string{"No selectivity, row-count or latency threshold was inferred. Capture, cache state and current data may differ.", "Per-loop, parallel, partial-input and logical-plan measurements are not converted into query totals or estimated gains."}, Edit: tableedit.IndexEdit{Action: "add", Name: name, Definition: &tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Column: &col}}}}}
	out.Indexes = append(out.Indexes, advice)
	return out
}
func (owner *owner) runTuning(ctx context.Context, physical adapter.Session, c protocol.Command, engine string) protocol.Response {
	reject := func(category, msg string) protocol.Response {
		r := rejectedCommand(c, category, msg)
		r.Connected = physical.TransactionStatus() != "unknown"
		r.TransactionStatus = physical.TransactionStatus()
		return r
	}
	if ctx.Err() != nil {
		return reject("cancelled", "Tuning was cancelled before it started.")
	}
	if owner.structureOnly || owner.importOnly || owner.monitorOnly {
		return reject("policy", "Tuning requires an ordinary query-tab owner.")
	}
	if !tuningAvailable(physical) {
		return reject("capability", "Tuning requires recognized PostgreSQL 14+ or Oracle MySQL 8.0.30+ with complete relational metadata and native values. MongoDB/Cassandra diagnostics and SQLite are not tuning models.")
	}
	support := physical.(adapter.ExplainSession).ExplainSupport()
	response := protocol.Response{Type: c.Type + ".result", Connected: true, TransactionStatus: physical.TransactionStatus()}
	switch c.Type {
	case "tuning.setting.observe":
		r := c.TuningSettingObservation
		if engine != "postgresql" || r == nil || !r.Valid() || !owner.tuningContext(&r.Context, physical) {
			return reject("validation", "Current work_mem observation requires the exact existing PostgreSQL transaction and owner.")
		}
		owner.invalidateGrant()
		child, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		value, err := adapter.ReadPostgresTuningWorkMem(child, physical, c)
		if err != nil || !owner.tuningContext(&r.Context, physical) {
			return reject("conflict", "Current work_mem or transaction context is unavailable. No setting was changed.")
		}
		response.TuningSettingObservation = &protocol.TuningSettingObservation{Version: 1, Name: "work_mem", WorkMemKiB: value, Scope: "currentTransaction"}
	case "tuning.inspect":
		r := c.TuningInspect
		if r == nil || !r.Valid() || !owner.tuningContext(r.Source.Context, physical) || r.Capture.Support.Engine != support.Engine || r.Capture.Support.ServerVersion != support.ServerVersion {
			return reject("conflict", "Inspect requires a matching current owner, capture engine/version and exact query context.")
		}
		child, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		b, err := physical.(tableedit.Adapter).StructureLoad(child, r.Target)
		if err != nil {
			return reject("validation", "Complete current table metadata is unavailable; no tuning candidate was prepared.")
		}
		if !owner.tuningContext(r.Source.Context, physical) {
			return reject("conflict", "The query session context changed while reading metadata.")
		}
		if b.Engine != engine || b.Target != r.Target || !tableedit.IsDigest(b.Fingerprint) {
			return reject("validation", "Current metadata does not identify the exact requested table.")
		}
		if b.Advanced != nil {
			return reject("validation", "Tuning requires the ordinary table model. Advanced security, hierarchy, type binding, persistence and storage-engine operations require their separate structure proof; no candidate or result query was prepared.")
		}
		if engine == "postgresql" && !adapter.PostgresTuningSearchPathSafe(child, physical, c) {
			return reject("validation", "Tuning requires pg_catalog first in the effective PostgreSQL search path; custom operator resolution is unsupported.")
		}
		owner.invalidateGrant()
		out := tuningInspection(*r, b)
		if engine == "postgresql" {
			if n, e := adapter.ReadPostgresTuningWorkMem(child, physical, c); e == nil {
				out.WorkMemKiB = &n
			} else {
				out.Limitations = append(out.Limitations, "Current work_mem is unavailable; setting actions require an exact supported current value.")
			}
		}
		response.TuningInspection = &out
	case "tuning.validate":
		if !owner.tuningOperationValid(protocol.OperationRequest{Type: c.Type, TuningValidation: c.TuningValidation}, physical) {
			return reject("validation", "Result validation requires the exact supported readonly queries and current owner context.")
		}
		r := *c.TuningValidation
		child, cancel := context.WithTimeout(ctx, time.Duration(r.TimeoutMS)*time.Millisecond)
		defer cancel()
		b, err := physical.(tableedit.Adapter).StructureLoad(child, r.Target)
		if err != nil || b.Fingerprint != r.MetadataFingerprint {
			return reject("conflict", "Table metadata changed or is incomplete. Inspect and review validation again.")
		}
		if b.Advanced != nil {
			return reject("validation", "Tuning requires the ordinary table model. Advanced security, hierarchy, type binding, persistence and storage-engine operations require their separate structure proof; no candidate or result query was prepared.")
		}
		if engine == "postgresql" && !adapter.PostgresTuningSearchPathSafe(child, physical, c) {
			return reject("validation", "Validation requires pg_catalog first in the effective PostgreSQL search path; custom operator resolution is unsupported.")
		}
		a, _ := parseTuningQuery(engine, r.Original, r.Target)
		v, _ := parseTuningQuery(engine, r.Variant, r.Target)
		if !tuningCatalogSafe(b, a) || !tuningCatalogSafe(b, v) || !owner.tuningContext(r.Original.Context, physical) {
			return reject("validation", "Validation requires current complete ordinary built-in column evidence and exact context.")
		}
		response.TuningValidation = runTuningValidation(child, physical, c, r)
	case "tuning.setting":
		if !owner.tuningOperationValid(protocol.OperationRequest{Type: c.Type, TuningSetting: c.TuningSetting}, physical) {
			return reject("validation", "Setting changes require a reviewed PostgreSQL transaction-local work_mem request.")
		}
		r := *c.TuningSetting
		before, err := adapter.ReadPostgresTuningWorkMem(ctx, physical, c)
		if err != nil || before != r.ExpectedValueKiB || !owner.tuningContext(&r.Context, physical) {
			return reject("conflict", "The current transaction or work_mem changed. Read and review the setting again.")
		}
		command := protocol.Command{Type: "execute", RequestID: c.RequestID, SessionID: c.SessionID, QueryID: c.QueryID, SQL: adapter.PostgresTuningSettingPreview(r).SQL}
		result := physical.Execute(ctx, command)
		if result.Type == "error" {
			return result
		}
		if physical.TransactionStatus() != "transaction" {
			failure := protocol.ErrorResponse(c, "conflict", "The setting SQL completed, but its current transaction scope is unavailable. Inspect explicitly before another change; do not replay it.")
			failure.SQLCompleted = true
			failure.Connected = physical.TransactionStatus() != "unknown"
			failure.TransactionStatus = physical.TransactionStatus()
			return failure
		}
		restore := r
		restore.ExpectedValueKiB, restore.ValueKiB = r.ValueKiB, before
		response.TuningSetting = &protocol.TuningSettingResult{Version: 1, State: "applied", BeforeKiB: before, RequestedKiB: r.ValueKiB, Restore: restore, Limitations: adapter.PostgresTuningSettingPreview(r).Risks}
	default:
		return reject("protocol", "Unknown tuning operation.")
	}
	response.TransactionStatus = physical.TransactionStatus()
	response.Connected = response.TransactionStatus != "unknown"
	return response
}

type tuningBag struct {
	columns                        []protocol.Column
	counts                         map[string]int
	rows, bytes, maxRows, maxBytes int
	limited, invalid, ended        bool
	pending                        bool
	cancel                         context.CancelFunc
}

var errTuningBound = errors.New("Tuning result comparison bound reached.")

func (s *tuningBag) Begin(index int, cols []protocol.Column) error {
	if index != 0 || len(cols) < 1 || len(cols) > 128 || s.columns != nil {
		s.invalid = true
		s.cancel()
		return errTuningBound
	}
	data, err := json.Marshal(cols)
	if err != nil || len(data) > 65536 {
		s.invalid = true
		s.cancel()
		return errTuningBound
	}
	s.columns = append([]protocol.Column{}, cols...)
	return nil
}
func (s *tuningBag) NativeRow(index int, row []protocol.NativeValue) error {
	if s.pending || index != 0 || !protocol.NativeMatrixValid([][]protocol.NativeValue{row}, 1, len(s.columns)) {
		s.invalid = true
		s.cancel()
		return errTuningBound
	}
	data, err := json.Marshal(row)
	if err != nil {
		s.invalid = true
		s.cancel()
		return errTuningBound
	}
	if s.rows >= s.maxRows || s.bytes+len(data) > s.maxBytes {
		s.limited = true
		s.cancel()
		return errTuningBound
	}
	s.counts[string(data)]++
	s.rows++
	s.bytes += len(data)
	s.pending = true
	return nil
}
func (s *tuningBag) Row(index int, _ []*string) error {
	if index != 0 || !s.pending {
		s.invalid = true
		s.cancel()
		return errTuningBound
	}
	s.pending = false
	return nil
}
func (s *tuningBag) End(index int, _ protocol.ResultSet) error {
	if index != 0 || s.pending {
		s.invalid = true
		return errTuningBound
	}
	s.ended = true
	return nil
}
func runTuningValidation(ctx context.Context, physical adapter.Session, c protocol.Command, r protocol.TuningValidationRequest) *protocol.TuningValidation {
	out := &protocol.TuningValidation{Version: 1, State: "inconclusive", Comparison: "multiset", Scope: "sequentialCurrentSession", Limitations: []string{"This compares two sequential observations in the current idle physical session. E2 metadata uses its own read-only observation transaction; the compared SELECTs are not wrapped in a transaction or shared snapshot, reconnected or retried.", "Observed equality is not logical equivalence or a performance measurement. Concurrent writes and session state may change results; open user transactions and temporary-table context are refused.", "Exact native scalar types, SQL NULL, numeric spelling, binary bytes and duplicate multiplicity are compared; row order is ignored. No result rows are retained in the reply."}}
	bags := []*tuningBag{}
	for i, request := range []protocol.ExplainRequest{r.Original, r.Variant} {
		if ctx.Err() != nil || physical.TransactionStatus() != request.Context.TransactionStatus {
			out.Limitations = append(out.Limitations, "Validation stopped before the next observation because its deadline or transaction context changed.")
			break
		}
		child, cancel := context.WithCancel(ctx)
		bag := &tuningBag{counts: map[string]int{}, maxRows: r.MaxRows, maxBytes: r.MaxBytes - out.ComparedBytes, cancel: cancel}
		bags = append(bags, bag)
		cmd := protocol.Command{Type: "execute", RequestID: c.RequestID, SessionID: c.SessionID, QueryID: c.QueryID, SQL: request.SQL, Parameters: request.Parameters, ResultValues: protocol.NativeResultValuesFormat}
		result := physical.(adapter.StreamingSession).ExecuteWithSink(child, cmd, bag)
		cancel()
		out.ComparedBytes += bag.bytes
		if i == 0 {
			out.OriginalRows = bag.rows
		} else {
			out.VariantRows = bag.rows
		}
		if bag.limited || bag.invalid || !bag.ended || result.Type != "query.result" || result.OutcomeUnknown || physical.TransactionStatus() != request.Context.TransactionStatus || ctx.Err() != nil {
			out.Limitations = append(out.Limitations, "A row/byte/deadline bound, unsupported native value, error or incomplete acknowledgement stopped validation. No partial equality is claimed.")
			break
		}
	}
	if len(bags) == 2 && !bags[0].limited && !bags[1].limited && !bags[0].invalid && !bags[1].invalid && bags[0].ended && bags[1].ended && ctx.Err() == nil {
		// Completion of each observation is tracked separately from stream End;
		// End may precede the final transaction acknowledgement.
		if len(out.Limitations) > 3 {
			return out
		}
		out.Complete = true
		out.State = "observedDifferent"
		if reflect.DeepEqual(bags[0].columns, bags[1].columns) && reflect.DeepEqual(bags[0].counts, bags[1].counts) {
			out.State = "observedEqual"
		}
	}
	return out
}

func asciiTuningName(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || i > 0 && c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}
