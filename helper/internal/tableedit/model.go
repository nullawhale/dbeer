// Package tableedit owns immutable table-edit plans. Dialect SQL belongs to adapters.
package tableedit

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"time"
	"unicode/utf8"
)

const Capability = "tableStructureEditorV1"
const AuthoringCapability = "tableStructureAuthoringV2"
const IndexAuthoringCapability = "tableStructureIndexAuthoringV1"
const DestructiveCapability = "tableStructureDestructiveV1"
const ReconstructionCapability = "tableStructureReconstructionV1"
const MaxColumns = 128
const MaxSQLBytes = 1024 * 1024

var ErrInvalid = errors.New("The table structure draft is invalid or unsupported.")
var ErrStale = errors.New("The table structure changed. Reconcile and prepare a new preview.")
var ErrUnsupported = errors.New("This table or server does not support structure editing.")

type Target struct {
	Reconcile bool   `json:"reconcile,omitempty"`
	Schema    string `json:"schema"`
	Table     string `json:"table"`
	Create    bool   `json:"create"`
}

func Identifier(s string) bool {
	return s != "" && len(s) <= 63 && utf8.ValidString(s) && !strings.ContainsRune(s, 0)
}
func (t Target) Valid() bool { return Identifier(t.Schema) && Identifier(t.Table) }

type DataType struct {
	Kind      string         `json:"kind"`
	Length    int            `json:"length,omitempty"`
	Precision int            `json:"precision,omitempty"`
	Scale     int            `json:"scale,omitempty"`
	Reference *TypeReference `json:"reference,omitempty"`
}

func (t DataType) Valid() bool {
	if t.Kind == "reference" {
		return t.Reference != nil && t.Reference.Valid() && t.Length == 0 && t.Precision == 0 && t.Scale == 0
	}
	if t.Reference != nil {
		return false
	}
	switch t.Kind {
	case "integer", "bigint", "boolean", "text", "real", "blob", "any", "sqliteNumeric":
		return t.Length == 0 && t.Precision == 0 && t.Scale == 0
	case "varchar":
		return t.Length > 0 && t.Length <= 16383 && t.Precision == 0 && t.Scale == 0
	case "numeric":
		return t.Length == 0 && t.Precision > 0 && t.Precision <= 65 && t.Scale >= 0 && t.Scale <= t.Precision && t.Scale <= 30
	}
	return false
}

// Explicit kinds distinguish no DEFAULT, SQL NULL and the text "NULL".
type Default struct {
	Kind  string  `json:"kind"`
	Value *string `json:"value,omitempty"`
}

func (d Default) Valid() bool {
	switch d.Kind {
	case "none", "null":
		return d.Value == nil
	case "text", "numeric", "boolean", "expression":
		return d.Value != nil && len(*d.Value) <= 4096 && utf8.ValidString(*d.Value) && !strings.ContainsRune(*d.Value, 0)
	}
	return false
}

type Column struct {
	PrimaryKeyName string      `json:"-"`
	Resolved       *TypeGuard  `json:"-"`
	Name           string      `json:"name"`
	Type           DataType    `json:"type"`
	Nullable       bool        `json:"nullable"`
	Default        Default     `json:"default"`
	Generated      *Generation `json:"generated,omitempty"`
	Identity       *Identity   `json:"identity,omitempty"`
}

func (c Column) Valid() bool {
	return Identifier(c.Name) && c.Type.Valid() && c.Default.Valid() && !(c.Default.Kind == "null" && !c.Nullable) && columnAuthoredValid(c)
}

type Draft struct {
	Backfills        []Backfill     `json:"backfills,omitempty"`
	ColumnOrder      []string       `json:"columnOrder,omitempty"`
	Reconstruct      bool           `json:"reconstruct,omitempty"`
	DropTable        bool           `json:"dropTable,omitempty"`
	AuthoringVersion int            `json:"authoringVersion,omitempty"`
	RenameTable      *string        `json:"renameTable,omitempty"`
	Columns          []Column       `json:"columns"`
	Changes          []ColumnChange `json:"changes,omitempty"`
	Indexes          []IndexEdit    `json:"indexes,omitempty"`
	Keys             []KeyEdit      `json:"keys,omitempty"`
	AllowDestructive bool           `json:"allowDestructive,omitempty"`
}

func (d Draft) Valid() bool { return d.Validate() == nil }

type ObservedColumn struct {
	Unsigned          *bool          `json:"unsigned,omitempty"`
	Charset           *string        `json:"charset,omitempty"`
	Collation         *TypeReference `json:"collation,omitempty"`
	EditableType      *DataType      `json:"editableType,omitempty"`
	CanModify         bool           `json:"canModify"`
	Name              string         `json:"name"`
	NativeType        string         `json:"nativeType"`
	Nullable          bool           `json:"nullable"`
	DefaultExpression *string        `json:"defaultExpression,omitempty"`
}
type Baseline struct {
	NativeDefinition string                    `json:"-"`
	Identity         string                    `json:"-"`
	Scope            string                    `json:"-"`
	Guard            string                    `json:"-"`
	Attributes       map[string]map[string]any `json:"-"`
	Facts            *Facts                    `json:"-"`
	Keys             []Key                     `json:"keys"`
	Indexes          []Index                   `json:"indexes"`
	DependencyProof  bool                      `json:"dependencyProof"`
	ID               string                    `json:"id"`
	Target           Target                    `json:"target"`
	Engine           string                    `json:"engine"`
	Fingerprint      string                    `json:"fingerprint"`
	Columns          []ObservedColumn          `json:"columns"`
	Limitations      []string                  `json:"limitations"`
}
type Plan struct {
	Reconstruction   *Reconstruction   `json:"-"`
	DroppedTarget    bool              `json:"droppedTarget,omitempty"`
	Consequences     []Consequence     `json:"consequences,omitempty"`
	ValidationChecks []ValidationCheck `json:"validationChecks,omitempty"`
	IndexGuards      []IndexGuard      `json:"-"`
	ResultTarget     *Target           `json:"resultTarget,omitempty"`
	Types            []TypeGuard       `json:"-"`
	RenamedColumns   map[string]string `json:"-"`
	Conditions       []Condition       `json:"-"`
	References       []Baseline        `json:"-"`
	Destructive      bool              `json:"destructive"`
	ID               string            `json:"id"`
	BaselineID       string            `json:"baselineId"`
	Digest           string            `json:"digest"`
	Target           Target            `json:"target"`
	SQL              []string          `json:"sql"`
	Risks            []string          `json:"risks"`
	Created          time.Time         `json:"-"`
}
type Apply struct {
	PlanID      string `json:"planId"`
	Digest      string `json:"digest"`
	ExecutionID string `json:"executionId"`
}

func ID(s string) bool {
	if len(s) == 0 || len(s) > 128 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}
func (a Apply) Valid() bool {
	return ID(a.PlanID) && len(a.Digest) == 64 && ID(a.ExecutionID) && IsDigest(a.Digest)
}
func IsDigest(s string) bool {
	if len(s) != 64 {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil && strings.ToLower(s) == s
}

type Request struct {
	Validation *Apply  `json:"validation,omitempty"`
	Target     *Target `json:"target,omitempty"`
	BaselineID string  `json:"baselineId,omitempty"`
	Draft      *Draft  `json:"draft,omitempty"`
	Apply      *Apply  `json:"apply,omitempty"`
}

func (r Request) Valid(command string) bool {
	if command == "structure.validate" {
		return r.Target == nil && r.BaselineID == "" && r.Draft == nil && r.Apply == nil && r.Validation != nil && r.Validation.Valid()
	}
	if r.Validation != nil {
		return false
	}
	switch command {
	case "structure.load":
		return r.Target != nil && r.Target.Valid() && (!r.Target.Reconcile || r.Target.Create) && r.BaselineID == "" && r.Draft == nil && r.Apply == nil
	case "structure.preview":
		return r.Target == nil && ID(r.BaselineID) && r.Draft != nil && r.Draft.Valid() && r.Apply == nil
	case "structure.apply":
		return r.Target == nil && r.BaselineID == "" && r.Draft == nil && r.Apply != nil && r.Apply.Valid()
	case "structure.status", "structure.close":
		return r.Target == nil && r.BaselineID == "" && r.Draft == nil && r.Apply == nil
	}
	return false
}

type StepOutcome struct {
	State   string `json:"state"`
	Message string `json:"message,omitempty"`
}
type Outcome struct {
	DroppedTarget bool          `json:"droppedTarget,omitempty"`
	ExecutionID   string        `json:"executionId"`
	PlanID        string        `json:"planId"`
	State         string        `json:"state"`
	Steps         []StepOutcome `json:"steps"`
	Observed      *Baseline     `json:"observed,omitempty"`
	RefreshError  string        `json:"refreshError,omitempty"`
}
type Reply struct {
	Validation *ValidationOutcome `json:"validation,omitempty"`
	Baseline   *Baseline          `json:"baseline,omitempty"`
	Plan       *Plan              `json:"plan,omitempty"`
	Outcome    *Outcome           `json:"outcome,omitempty"`
}

// Adapters provide positively acknowledged completion separately from observation.
type Execution struct {
	State   string
	Message string
}
type Adapter interface {
	StructureLoad(context.Context, Target) (Baseline, error)
	StructureRender(Baseline, Draft) ([]string, []string, error)
	StructureApply(context.Context, Baseline, []string) Execution
}

func Token() string {
	var b [24]byte
	if _, err := rand.Read(b[:]); err != nil {
		return ""
	}
	return hex.EncodeToString(b[:])
}
func Fingerprint(v any) string {
	b, _ := json.Marshal(v)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

type Store struct {
	validation *ValidationOutcome
	baseline   *Baseline
	plan       *Plan
	outcome    *Outcome
}

func (s *Store) Load(ctx context.Context, a Adapter, t Target) (Reply, error) {
	s.baseline = nil
	s.plan = nil
	s.validation = nil
	b, e := a.StructureLoad(ctx, t)
	if e != nil {
		return Reply{}, e
	}
	if !ValidBaseline(b) {
		return Reply{}, ErrUnsupported
	}
	b.ID = Token()
	if b.ID == "" {
		return Reply{}, ErrInvalid
	}
	s.baseline = &b
	s.plan = nil
	return Reply{Baseline: &b}, nil
}
func (s *Store) Preview(a Adapter, id string, d Draft) (Reply, error) {
	return s.PreviewContext(context.Background(), a, id, d)
}
func (s *Store) PreviewContext(ctx context.Context, a Adapter, id string, d Draft) (Reply, error) {
	s.plan = nil
	s.validation = nil
	if s.baseline == nil || s.baseline.ID != id {
		return Reply{}, ErrStale
	}
	if err := d.Validate(); err != nil {
		return Reply{}, err
	}
	var sql, risks []string
	var references []Baseline
	var conditions []Condition
	var types []TypeGuard
	var indexGuards []IndexGuard
	var resultTarget *Target
	var droppedTarget bool
	var reconstruction *Reconstruction
	var consequences []Consequence
	var validationChecks []ValidationCheck
	var err error
	if advanced, ok := a.(AdvancedAdapter); ok {
		var prepared Prepared
		prepared, err = advanced.StructurePrepare(ctx, *s.baseline, d)
		sql, risks, references, conditions = prepared.SQL, prepared.Risks, prepared.References, prepared.Conditions
		types, resultTarget = prepared.Types, prepared.ResultTarget
		indexGuards = prepared.IndexGuards
		droppedTarget, consequences, validationChecks = prepared.DroppedTarget, prepared.Consequences, prepared.ValidationChecks
		reconstruction = prepared.Reconstruction
	} else {
		if d.NeedsAuthoringV2() || d.NeedsAuthoringV3() || d.NeedsAuthoringV4() || d.NeedsAuthoringV5() || len(d.Changes)+len(d.Keys)+len(d.Indexes) > 0 || !s.baseline.Target.Create && (len(d.Columns) != 1 || !d.Columns[0].Nullable) {
			return Reply{}, ErrUnsupported
		}
		sql, risks, err = a.StructureRender(*s.baseline, d)
	}
	if err != nil {
		return Reply{}, err
	}
	if d.RenameTable != nil && resultTarget == nil {
		return Reply{}, ErrUnsupported
	}
	if len(sql) == 0 || len(sql) > 64 || (conditions != nil && len(conditions) != len(sql)) {
		return Reply{}, ErrInvalid
	}
	total := 0
	for _, step := range sql {
		total += len(step)
		if len(step) == 0 || strings.ContainsRune(step, 0) {
			return Reply{}, ErrInvalid
		}
	}
	if total > MaxSQLBytes {
		return Reply{}, ErrInvalid
	}
	referenceBytes := 0
	for _, ref := range references {
		if !ValidBaseline(ref) {
			return Reply{}, ErrUnsupported
		}
		raw, _ := json.Marshal([]any{ref, ref.Facts, ref.Attributes})
		referenceBytes += len(raw)
	}
	if referenceBytes > 8<<20 {
		return Reply{}, ErrUnsupported
	}
	if !validReview(consequences, validationChecks) || droppedTarget != d.DropTable {
		return Reply{}, ErrInvalid
	}
	p := &Plan{Reconstruction: reconstruction, DroppedTarget: droppedTarget, Consequences: consequences, ValidationChecks: validationChecks, ID: Token(), BaselineID: id, Target: s.baseline.Target, SQL: sql, Risks: risks, References: references, Destructive: d.Destructive() || d.RequiresEffectConfirmation(), ResultTarget: resultTarget, Types: types, IndexGuards: indexGuards, Conditions: conditions, Created: time.Now()}
	identities := []string{}
	for _, b := range references {
		identities = append(identities, b.Fingerprint)
	}
	p.RenamedColumns = map[string]string{}
	for _, c := range d.Changes {
		if c.RenameTo != nil {
			p.RenamedColumns[c.Name] = *c.RenameTo
		}
	}
	p.Digest = Fingerprint([]any{p, identities, conditions, types, indexGuards, p.RenamedColumns, reconstruction})
	s.plan = p
	return Reply{Plan: p}, nil
}
func (s *Store) Resolve(a Apply) (*Plan, error) {
	if !a.Valid() || s.plan == nil || s.baseline == nil || s.plan.ID != a.PlanID || s.plan.Digest != a.Digest || time.Since(s.plan.Created) > 10*time.Minute || s.outcome != nil && s.outcome.PlanID == a.PlanID {
		return nil, ErrStale
	}
	return s.plan, nil
}
func (s *Store) Apply(ctx context.Context, a Adapter, r Apply) (Reply, error) {
	p, e := s.Resolve(r)
	if e != nil {
		return Reply{}, e
	}
	b := *s.baseline
	s.outcome = &Outcome{ExecutionID: r.ExecutionID, PlanID: p.ID, State: "applying", Steps: make([]StepOutcome, len(p.SQL))}
	for i := range s.outcome.Steps {
		s.outcome.Steps[i].State = "notStarted"
	}
	if ctx.Err() != nil {
		s.outcome.State = "cancelled"
		return Reply{Outcome: s.outcome}, nil
	}
	var executions []Execution
	if advanced, ok := a.(AdvancedAdapter); ok {
		executions = advanced.StructureApplySteps(ctx, b, *p)
	} else {
		executions = []Execution{a.StructureApply(ctx, b, p.SQL)}
	}
	applied := 0
	unknown := false
	failed := false
	for i, x := range executions {
		if i >= len(p.SQL) {
			unknown = true
			break
		}
		switch x.State {
		case "applied":
			applied++
		case "unknown":
			unknown = true
		case "failed", "notStarted", "rolledBack":
			failed = true
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
	s.plan = nil
	s.baseline = nil
	if p.DroppedTarget && s.outcome.State == "applied" {
		s.outcome.DroppedTarget = true
		return Reply{Outcome: s.outcome}, nil
	}
	observe := b.Target
	if p.ResultTarget != nil && s.outcome.State == "applied" {
		observe = *p.ResultTarget
	}
	observe.Create = false
	if ctx.Err() == nil {
		fresh, err := a.StructureLoad(ctx, observe)
		if err == nil && ValidBaseline(fresh) {
			fresh.ID = Token()
			s.outcome.Observed = &fresh
		} else {
			s.outcome.RefreshError = "The resulting structure could not be refreshed. Reconcile before another edit."
		}
	} else {
		s.outcome.RefreshError = "Refresh was cancelled. Reconcile before another edit."
	}
	return Reply{Outcome: s.outcome}, nil
}
func (s *Store) Status() Reply { return Reply{Outcome: s.outcome, Validation: s.validation} }
func (s *Store) Close()        { s.baseline = nil; s.plan = nil; s.validation = nil }
