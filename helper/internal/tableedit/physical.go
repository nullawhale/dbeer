package tableedit

import (
	"context"
	"errors"
	"math/big"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const PhysicalCapability = "tableStructurePhysicalV1"

// Physical drafts contain portable intent only. Catalog proof and grants are session-owned.
type PhysicalValue struct {
	Kind  string  `json:"kind"`
	Value *string `json:"value,omitempty"`
}

func (v PhysicalValue) Valid() bool {
	switch v.Kind {
	case "null", "min", "max":
		return v.Value == nil
	case "integer":
		if v.Value == nil || len(*v.Value) > 80 {
			return false
		}
		n, ok := new(big.Int).SetString(*v.Value, 10)
		return ok && n.String() == *v.Value
	case "text":
		return v.Value != nil && len(*v.Value) <= 4096 && utf8.ValidString(*v.Value) && !strings.ContainsRune(*v.Value, 0)
	}
	return false
}

type PhysicalBound struct {
	Kind      string            `json:"kind"`
	From      []PhysicalValue   `json:"from,omitempty"`
	To        []PhysicalValue   `json:"to,omitempty"`
	Values    [][]PhysicalValue `json:"values,omitempty"`
	Modulus   int               `json:"modulus,omitempty"`
	Remainder *int              `json:"remainder,omitempty"`
}

func (b PhysicalBound) Valid() bool {
	valid := func(v []PhysicalValue) bool {
		if len(v) == 0 || len(v) > 16 {
			return false
		}
		for _, x := range v {
			if !x.Valid() {
				return false
			}
		}
		return true
	}
	switch b.Kind {
	case "default":
		return len(b.From)+len(b.To)+len(b.Values) == 0 && b.Modulus == 0 && b.Remainder == nil
	case "range":
		return len(b.From) <= 16 && valid(b.To) && (len(b.From) == 0 || valid(b.From) && len(b.From) == len(b.To)) && len(b.Values) == 0 && b.Modulus == 0 && b.Remainder == nil
	case "list":
		if len(b.From)+len(b.To) > 0 || b.Modulus != 0 || b.Remainder != nil || len(b.Values) == 0 || len(b.Values) > 128 {
			return false
		}
		for _, v := range b.Values {
			if !valid(v) {
				return false
			}
		}
		return true
	case "hash":
		return len(b.From)+len(b.To)+len(b.Values) == 0 && b.Modulus > 0 && b.Modulus <= 8192 && b.Remainder != nil && *b.Remainder >= 0 && *b.Remainder < b.Modulus
	}
	return false
}

type PhysicalPartitionDefinition struct {
	Name  string        `json:"name"`
	Bound PhysicalBound `json:"bound"`
}
type PhysicalIntent struct {
	Kind        string                        `json:"kind"`
	Child       *Target                       `json:"child,omitempty"`
	Bound       *PhysicalBound                `json:"bound,omitempty"`
	Concurrent  bool                          `json:"concurrent,omitempty"`
	Index       *IndexEdit                    `json:"index,omitempty"`
	Engine      string                        `json:"engine,omitempty"`
	Algorithm   string                        `json:"algorithm,omitempty"`
	Lock        string                        `json:"lock,omitempty"`
	Partitions  []string                      `json:"partitions,omitempty"`
	Definitions []PhysicalPartitionDefinition `json:"definitions,omitempty"`
	Count       int                           `json:"count,omitempty"`
	ColumnOrder []string                      `json:"columnOrder,omitempty"`
	Method      string                        `json:"method,omitempty"`
	Columns     []string                      `json:"columns,omitempty"`
}

func physicalNames(names []string, limit int) bool {
	if len(names) == 0 || len(names) > limit {
		return false
	}
	seen := map[string]bool{}
	for _, n := range names {
		if !Identifier(n) || seen[n] {
			return false
		}
		seen[n] = true
	}
	return true
}
func (x PhysicalIntent) Valid() bool {
	if x.Kind != "partitionTable" && (x.Method != "" || len(x.Columns) > 0) {
		return false
	}
	if x.Child != nil && (!x.Child.Valid() || x.Child.Create || x.Child.Reconcile) || x.Bound != nil && !x.Bound.Valid() || len(x.Partitions) > 128 || len(x.Definitions) > 128 {
		return false
	}
	if len(x.Partitions) > 0 && !physicalNames(x.Partitions, 128) {
		return false
	}
	seen := map[string]bool{}
	for _, d := range x.Definitions {
		if !Identifier(d.Name) || !d.Bound.Valid() || seen[d.Name] {
			return false
		}
		seen[d.Name] = true
	}
	// Empty and unused fields are rejected by the wire shape as well as here.
	switch x.Kind {
	case "exchangePartition":
		return x.Child != nil && len(x.Partitions) == 1 && x.Bound == nil && x.Index == nil && x.Engine == "" && len(x.Definitions)+len(x.ColumnOrder) == 0 && x.Count == 0 && !x.Concurrent && physicalAlgorithm(x.Algorithm, x.Lock)
	case "removePartitioning":
		return x.Child == nil && x.Bound == nil && x.Index == nil && x.Engine == "" && len(x.Partitions)+len(x.Definitions)+len(x.ColumnOrder) == 0 && x.Count == 0 && !x.Concurrent && physicalAlgorithm(x.Algorithm, x.Lock)
	case "partitionTable":
		return x.Child == nil && x.Bound == nil && x.Index == nil && x.Engine == "" && len(x.Partitions)+len(x.ColumnOrder) == 0 && !x.Concurrent && physicalAlgorithm(x.Algorithm, x.Lock) && columnsValid(x.Columns) && ((x.Method == "range" || x.Method == "list" || x.Method == "rangeColumns" || x.Method == "listColumns") && len(x.Definitions) > 0 && x.Count == 0 || (x.Method == "hash" || x.Method == "key") && len(x.Definitions) == 0 && x.Count > 0 && x.Count <= 8192)
	case "concurrentIndex":
		return x.Index != nil && physicalIndexValid(*x.Index) && x.Child == nil && x.Bound == nil && x.Engine == "" && x.Algorithm == "" && x.Lock == "" && len(x.Partitions)+len(x.Definitions)+len(x.ColumnOrder) == 0 && x.Count == 0 && !x.Concurrent
	case "onlineIndex":
		return x.Index != nil && physicalIndexValid(*x.Index) && x.Child == nil && x.Bound == nil && x.Engine == "" && physicalAlgorithm(x.Algorithm, x.Lock) && len(x.Partitions)+len(x.Definitions)+len(x.ColumnOrder) == 0 && x.Count == 0 && !x.Concurrent
	case "storageEngine":
		return (x.Engine == "InnoDB" || x.Engine == "MyISAM") && physicalAlgorithm(x.Algorithm, x.Lock) && x.Child == nil && x.Bound == nil && x.Index == nil && len(x.Partitions)+len(x.Definitions)+len(x.ColumnOrder) == 0 && x.Count == 0 && !x.Concurrent
	case "reorderColumns":
		return physicalNames(x.ColumnOrder, 128) && physicalAlgorithm(x.Algorithm, x.Lock) && x.Child == nil && x.Bound == nil && x.Index == nil && x.Engine == "" && len(x.Partitions)+len(x.Definitions) == 0 && x.Count == 0 && !x.Concurrent
	case "createPartition", "attachPartition":
		return x.Child != nil && x.Bound != nil && x.Index == nil && x.Engine == "" && x.Algorithm == "" && x.Lock == "" && len(x.Partitions)+len(x.Definitions)+len(x.ColumnOrder) == 0 && x.Count == 0 && !x.Concurrent
	case "detachPartition", "finalizePartition":
		return x.Child != nil && x.Bound == nil && x.Index == nil && x.Engine == "" && x.Algorithm == "" && x.Lock == "" && len(x.Partitions)+len(x.Definitions)+len(x.ColumnOrder) == 0 && x.Count == 0 && (x.Kind != "finalizePartition" || !x.Concurrent)
	case "dropPartition", "truncatePartition":
		return (x.Child != nil && len(x.Partitions) == 0 || x.Child == nil && len(x.Partitions) > 0) && x.Bound == nil && x.Index == nil && x.Engine == "" && len(x.Definitions)+len(x.ColumnOrder) == 0 && x.Count == 0 && !x.Concurrent && (x.Child != nil && x.Algorithm == "" && x.Lock == "" || x.Child == nil && physicalAlgorithm(x.Algorithm, x.Lock))
	case "addPartition", "reorganizePartition":
		return x.Child == nil && x.Bound == nil && x.Index == nil && x.Engine == "" && physicalAlgorithm(x.Algorithm, x.Lock) && len(x.Definitions) > 0 && len(x.ColumnOrder) == 0 && x.Count == 0 && !x.Concurrent && (x.Kind == "addPartition" && len(x.Partitions) == 0 || x.Kind == "reorganizePartition" && len(x.Partitions) > 0)
	case "addHashPartitions", "coalescePartitions":
		return x.Child == nil && x.Bound == nil && x.Index == nil && x.Engine == "" && physicalAlgorithm(x.Algorithm, x.Lock) && len(x.Definitions)+len(x.Partitions)+len(x.ColumnOrder) == 0 && x.Count > 0 && x.Count <= 8192 && !x.Concurrent
	}
	return false
}
func physicalAlgorithm(a, l string) bool {
	return (a == "INPLACE" || a == "COPY" || a == "INSTANT") && (l == "NONE" || l == "SHARED" || l == "EXCLUSIVE")
}
func physicalIndexValid(x IndexEdit) bool {
	if x.Action != "add" && x.Action != "drop" {
		return false
	}
	d := Draft{Columns: []Column{}, Indexes: []IndexEdit{x}, AllowDestructive: true}
	if x.Definition != nil {
		d.AuthoringVersion = 3
	}
	return d.Valid()
}

type PhysicalDraft struct {
	Version int            `json:"version"`
	Target  Target         `json:"target"`
	Intent  PhysicalIntent `json:"intent"`
}

func (d PhysicalDraft) Valid() bool {
	return d.Version == 1 && d.Target.Valid() && !d.Target.Create && !d.Target.Reconcile && d.Intent.Valid()
}

type PhysicalRequest struct {
	Target *Target        `json:"target,omitempty"`
	Draft  *PhysicalDraft `json:"draft,omitempty"`
	Apply  *Apply         `json:"apply,omitempty"`
}

func (r PhysicalRequest) Valid(c string) bool {
	if c == "structure.physical.inspect" {
		return r.Target != nil && r.Target.Valid() && !r.Target.Create && !r.Target.Reconcile && r.Draft == nil && r.Apply == nil
	}
	if r.Target != nil {
		return false
	}
	switch c {
	case "structure.physical.preview":
		return r.Draft != nil && r.Draft.Valid() && r.Apply == nil
	case "structure.physical.apply":
		return r.Draft == nil && r.Apply != nil && r.Apply.Valid()
	case "structure.physical.status", "structure.physical.reconcile", "structure.physical.close":
		return r.Draft == nil && r.Apply == nil
	}
	return false
}

type PhysicalPartition struct {
	Name          string  `json:"name"`
	Target        *Target `json:"target,omitempty"`
	Method        string  `json:"method"`
	Description   string  `json:"description"`
	DetachPending bool    `json:"detachPending,omitempty"`
}
type PhysicalIndexState struct {
	Name  string `json:"name"`
	Valid bool   `json:"valid"`
	Ready bool   `json:"ready"`
	Live  bool   `json:"live"`
}
type PhysicalObject struct {
	Columns           []ObservedColumn     `json:"columns"`
	PartitionMethod   string               `json:"partitionMethod,omitempty"`
	PartitionColumns  []string             `json:"partitionColumns,omitempty"`
	PartitionKeyCount int                  `json:"partitionKeyCount,omitempty"`
	Target            Target               `json:"target"`
	Identity          string               `json:"identity"`
	Kind              string               `json:"kind"`
	StorageEngine     string               `json:"storageEngine,omitempty"`
	Fingerprint       string               `json:"fingerprint"`
	Definition        string               `json:"definition,omitempty"`
	Partitions        []PhysicalPartition  `json:"partitions"`
	Indexes           []PhysicalIndexState `json:"indexes"`
	Limitations       []string             `json:"limitations"`
}
type PhysicalPlan struct {
	ID              string           `json:"id"`
	Digest          string           `json:"digest"`
	Draft           PhysicalDraft    `json:"draft"`
	Engine          string           `json:"engine"`
	ServerVersion   int              `json:"serverVersion"`
	SQL             []string         `json:"sql"`
	Objects         []PhysicalObject `json:"objects"`
	Prerequisites   []string         `json:"prerequisites"`
	Risks           []string         `json:"risks"`
	Consequences    []Consequence    `json:"consequences"`
	TransactionMode string           `json:"transactionMode"`
	Locking         string           `json:"locking"`
	Destructive     bool             `json:"destructive"`
	Evidence        any              `json:"-"`
	EvidenceDigest  string           `json:"-"`
	Created         time.Time        `json:"-"`
}
type PhysicalOutcome struct {
	Consequences []Consequence    `json:"consequences,omitempty"`
	ExecutionID  string           `json:"executionId"`
	PlanID       string           `json:"planId"`
	State        string           `json:"state"`
	Phase        string           `json:"phase"`
	Steps        []StepOutcome    `json:"steps"`
	Observed     []PhysicalObject `json:"observed,omitempty"`
	RefreshError string           `json:"refreshError,omitempty"`
	Reconciled   bool             `json:"reconciled"`
}
type PhysicalReply struct {
	Inspection          *PhysicalInspection `json:"inspection,omitempty"`
	Draft               *PhysicalDraft      `json:"draft,omitempty"`
	Plan                *PhysicalPlan       `json:"plan,omitempty"`
	Outcome             *PhysicalOutcome    `json:"outcome,omitempty"`
	ElapsedMilliseconds int64               `json:"elapsedMilliseconds,omitempty"`
}
type PhysicalAdapter interface {
	PhysicalPrepare(context.Context, PhysicalDraft) (PhysicalPlan, error)
	PhysicalExecute(context.Context, PhysicalPlan, func(int, string)) []Execution
	PhysicalObserve(context.Context, PhysicalPlan) ([]PhysicalObject, error)
}
type PhysicalStore struct {
	mu        sync.Mutex
	draft     *PhysicalDraft
	plan      *PhysicalPlan
	retained  *PhysicalPlan
	outcome   *PhysicalOutcome
	started   time.Time
	active    bool
	reconcile bool
}

func (s *PhysicalStore) NeedsReconciliation() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.active || s.reconcile
}
func (s *PhysicalStore) Preview(ctx context.Context, a PhysicalAdapter, d PhysicalDraft) (PhysicalReply, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.active || s.reconcile {
		return PhysicalReply{}, errors.New("Reconcile the retained physical execution before preparing another plan.")
	}
	s.plan = nil
	if !d.Valid() {
		return PhysicalReply{}, ErrInvalid
	}
	p, e := a.PhysicalPrepare(ctx, d)
	if e != nil {
		return PhysicalReply{}, e
	}
	if len(p.SQL) == 0 || len(p.SQL) > 64 || len(p.Objects) == 0 || !IsDigest(p.EvidenceDigest) || p.ServerVersion <= 0 || (p.Engine != "postgresql" && p.Engine != "mysql") {
		return PhysicalReply{}, ErrInvalid
	}
	total := 0
	for _, q := range p.SQL {
		total += len(q)
		if q == "" || strings.ContainsRune(q, 0) {
			return PhysicalReply{}, ErrInvalid
		}
	}
	if total > MaxSQLBytes {
		return PhysicalReply{}, ErrInvalid
	}
	p.ID = Token()
	p.Draft = d
	p.Created = time.Now()
	p.Destructive = true
	p.Digest = Fingerprint([]any{p, p.EvidenceDigest})
	if p.ID == "" {
		return PhysicalReply{}, ErrInvalid
	}
	s.draft = &d
	s.plan = &p
	s.outcome = nil
	s.retained = nil
	s.started = time.Time{}
	return s.statusLocked(), nil
}
func (s *PhysicalStore) resolveLocked(r Apply) (*PhysicalPlan, error) {
	if !r.Valid() || s.active || s.reconcile || s.plan == nil || s.plan.ID != r.PlanID || s.plan.Digest != r.Digest || time.Since(s.plan.Created) > 10*time.Minute {
		return nil, ErrStale
	}
	return s.plan, nil
}
func (s *PhysicalStore) Resolve(r Apply) (*PhysicalPlan, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.resolveLocked(r)
}
func (s *PhysicalStore) Apply(ctx context.Context, a PhysicalAdapter, r Apply) (PhysicalReply, error) {
	s.mu.Lock()
	p, e := s.resolveLocked(r)
	if e != nil {
		s.mu.Unlock()
		return PhysicalReply{}, e
	}
	s.plan = nil
	s.retained = p
	s.active = true
	s.reconcile = true
	s.started = time.Now()
	s.outcome = &PhysicalOutcome{Consequences: append([]Consequence(nil), p.Consequences...), ExecutionID: r.ExecutionID, PlanID: p.ID, State: "applying", Phase: "metadataRecheck", Steps: make([]StepOutcome, len(p.SQL))}
	for i := range s.outcome.Steps {
		s.outcome.Steps[i].State = "notStarted"
	}
	s.mu.Unlock()
	executions := a.PhysicalExecute(ctx, *p, func(i int, phase string) {
		s.mu.Lock()
		defer s.mu.Unlock()
		if i >= 0 && i < len(s.outcome.Steps) {
			s.outcome.Phase = phase
			if phase == "acknowledged" {
				s.outcome.Steps[i].State = "applied"
			}
		}
	})
	s.mu.Lock()
	applied, failed, unknown := 0, false, false
	for i, x := range executions {
		if i >= len(s.outcome.Steps) {
			unknown = true
			break
		}
		switch x.State {
		case "applied":
			applied++
		case "notStarted", "failed", "rolledBack":
			failed = true
		case "unknown":
			unknown = true
		default:
			x.State = "unknown"
			unknown = true
		}
		s.outcome.Steps[i] = StepOutcome{State: x.State, Message: x.Message}
	}
	switch {
	case unknown:
		s.outcome.State = "outcomeUnknown"
	case applied == len(p.SQL) && !failed:
		s.outcome.State = "applied"
	case applied > 0:
		s.outcome.State = "partiallyApplied"
	case ctx.Err() != nil:
		s.outcome.State = "cancelled"
	default:
		s.outcome.State = "failed"
	}
	s.outcome.Phase = "finished"
	s.active = false
	s.mu.Unlock()
	// The acknowledgement is authoritative. Observation cannot convert an unknown write to applied.
	observe := true
	s.mu.Lock()
	for _, step := range s.outcome.Steps {
		if step.State == "applied" && step.Message != "" {
			observe = false
			s.outcome.RefreshError = step.Message
		}
	}
	s.mu.Unlock()
	if ctx.Err() == nil && observe {
		_, _ = s.Reconcile(ctx, a)
	}
	return s.Status(), nil
}
func (s *PhysicalStore) Reconcile(ctx context.Context, a PhysicalAdapter) (PhysicalReply, error) {
	s.mu.Lock()
	if s.active || s.retained == nil {
		s.mu.Unlock()
		return PhysicalReply{}, ErrStale
	}
	p := *s.retained
	s.mu.Unlock()
	objects, e := a.PhysicalObserve(ctx, p)
	s.mu.Lock()
	defer s.mu.Unlock()
	if e != nil {
		s.outcome.RefreshError = "Catalog observation is unavailable. Retained acknowledgement is unchanged; reconnecting must not replay this operation."
		return s.statusLocked(), nil
	}
	s.outcome.Observed = objects
	s.outcome.RefreshError = ""
	s.outcome.Reconciled = true
	s.reconcile = false
	return s.statusLocked(), nil
}
func (s *PhysicalStore) Status() PhysicalReply {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.statusLocked()
}
func (s *PhysicalStore) statusLocked() PhysicalReply {
	r := PhysicalReply{Draft: s.draft, Plan: s.plan}
	if s.outcome != nil {
		o := *s.outcome
		o.Steps = append([]StepOutcome(nil), o.Steps...)
		o.Observed = append([]PhysicalObject(nil), o.Observed...)
		r.Outcome = &o
	}
	if s.active {
		r.ElapsedMilliseconds = time.Since(s.started).Milliseconds()
	}
	return r
}
func (s *PhysicalStore) Close() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.active || s.reconcile {
		return false
	}
	s.draft = nil
	s.plan = nil
	s.retained = nil
	s.outcome = nil
	return true
}
