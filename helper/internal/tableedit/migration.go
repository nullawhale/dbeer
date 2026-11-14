package tableedit

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"slices"
	"sort"
	"strings"
	"time"

	sc "dbeer/helper/internal/schemacompare"
)

const MigrationCapability = "tableStructureMigrationsV1"
const MaxMigrationObjects = 32
const MaxMigrationSteps = 96

// Portable intent contains no connection, authorization, captured facts or SQL.
type MigrationDraft struct {
	Version int               `json:"version"`
	Objects []MigrationObject `json:"objects"`
	Repairs []MigrationRepair `json:"repairs"`
}
type MigrationObject struct {
	ID     string   `json:"id"`
	Target Target   `json:"target"`
	Draft  Draft    `json:"draft"`
	After  []string `json:"after"`
}
type MigrationRepair struct {
	ID          string   `json:"id"`
	Target      Target   `json:"target"`
	Key         string   `json:"key"`
	Action      string   `json:"action"`
	Replacement *KeyEdit `json:"replacement,omitempty"`
}

func (d MigrationDraft) Valid() bool {
	if d.Version != 1 || len(d.Objects) == 0 || len(d.Objects) > 16 || len(d.Repairs) > 16 {
		return false
	}
	ids, targets, repairs := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, o := range d.Objects {
		if !ID(o.ID) || ids[o.ID] || !o.Target.Valid() || o.Target.Reconcile || !o.Draft.Valid() || len(o.After) > 16 || targets[migrationTarget(o.Target)] {
			return false
		}
		ids[o.ID], targets[migrationTarget(o.Target)] = true, true
	}
	for _, o := range d.Objects {
		seen := map[string]bool{}
		for _, id := range o.After {
			if !ids[id] || id == o.ID || seen[id] {
				return false
			}
			seen[id] = true
		}
	}
	for _, r := range d.Repairs {
		key := migrationTarget(r.Target) + "\x00" + r.Key
		if !ID(r.ID) || ids[r.ID] || repairs[key] || !r.Target.Valid() || r.Target.Create || r.Target.Reconcile || !Identifier(r.Key) {
			return false
		}
		if r.Action == "drop" {
			if r.Replacement != nil {
				return false
			}
		} else if r.Action == "replace" {
			if r.Replacement == nil || r.Replacement.Action != "add" || r.Replacement.Kind != "foreign" || r.Replacement.Name != r.Key || !(Draft{Columns: []Column{}, Keys: []KeyEdit{*r.Replacement}}).Valid() {
				return false
			}
		} else {
			return false
		}
		ids[r.ID], repairs[key] = true, true
	}
	raw, err := json.Marshal(d)
	return err == nil && len(raw) <= MaxSQLBytes
}

type MigrationRequest struct {
	Draft *MigrationDraft `json:"draft,omitempty"`
	Apply *Apply          `json:"apply,omitempty"`
}

func (r MigrationRequest) Valid(command string) bool {
	switch command {
	case "structure.migration.preview":
		return r.Draft != nil && r.Draft.Valid() && r.Apply == nil
	case "structure.migration.apply", "structure.migration.export":
		return r.Draft == nil && r.Apply != nil && r.Apply.Valid()
	case "structure.migration.status", "structure.migration.reconcile", "structure.migration.close":
		return r.Draft == nil && r.Apply == nil
	}
	return false
}

type MigrationExpectation struct {
	Target             Target   `json:"target"`
	InitialFingerprint string   `json:"initialFingerprint"`
	IdentityDigest     string   `json:"identityDigest"`
	AfterSteps         []string `json:"afterSteps"`
}
type MigrationStep struct {
	ID           string                 `json:"id"`
	ObjectID     string                 `json:"objectId"`
	Phase        string                 `json:"phase"`
	Target       Target                 `json:"target"`
	Draft        Draft                  `json:"draft"`
	SQL          []string               `json:"sql"`
	Digest       string                 `json:"digest"`
	Before       []MigrationExpectation `json:"before"`
	After        []MigrationExpectation `json:"after"`
	Risks        []string               `json:"risks"`
	Consequences []Consequence          `json:"consequences,omitempty"`
	Atomic       bool                   `json:"atomic"`
}
type MigrationPlan struct {
	ID          string          `json:"id"`
	Digest      string          `json:"digest"`
	Engine      string          `json:"engine"`
	Draft       MigrationDraft  `json:"draft"`
	Baselines   []Baseline      `json:"baselines"`
	Steps       []MigrationStep `json:"steps"`
	Risks       []string        `json:"risks"`
	Destructive bool            `json:"destructive"`
	created     time.Time
	prepared    []Plan
	initial     map[string]Baseline
}
type MigrationObservation struct {
	Target         Target `json:"target"`
	Fingerprint    string `json:"fingerprint"`
	IdentityDigest string `json:"identityDigest"`
}
type MigrationStepOutcome struct {
	ID         string                 `json:"id"`
	State      string                 `json:"state"`
	Statements []StepOutcome          `json:"statements"`
	Message    string                 `json:"message,omitempty"`
	Observed   []MigrationObservation `json:"observed,omitempty"`
}
type MigrationOutcome struct {
	PlanID                 string                 `json:"planId"`
	ExecutionID            string                 `json:"executionId"`
	State                  string                 `json:"state"`
	Steps                  []MigrationStepOutcome `json:"steps"`
	ReconciliationRequired bool                   `json:"reconciliationRequired"`
}
type MigrationExport struct {
	Version int            `json:"version"`
	Draft   MigrationDraft `json:"draft"`
	SQL     string         `json:"sql"`
}
type MigrationReply struct {
	Plan     *MigrationPlan    `json:"plan,omitempty"`
	Draft    *MigrationDraft   `json:"draft,omitempty"`
	Outcome  *MigrationOutcome `json:"outcome,omitempty"`
	Observed []Baseline        `json:"observed,omitempty"`
	Export   *MigrationExport  `json:"export,omitempty"`
}
type MigrationAdapter interface {
	Adapter
	AdvancedAdapter
	StructurePrepareMigration(context.Context, Baseline, Draft, func(Target) (Baseline, error)) (Prepared, error)
}

// A private acknowledged-unit observation, never portable execution authority.
type MigrationCheckpoint struct {
	Plan   Plan
	Target Target
	Draft  Draft
	Before []Baseline
	After  []Baseline
}
type MigrationCheckpointAdapter interface {
	StructureMigrationCheckpoint(context.Context, MigrationCheckpoint) ([]Target, error)
	StructureBindMigrationCheckpoint(context.Context, Baseline, Plan, Draft, func(Target) (Baseline, error)) (Plan, error)
}

func migrationCheckpointBindingMatches(original, bound Plan) bool {
	if original.AdvancedProof == nil || bound.AdvancedProof == nil || !reflect.DeepEqual(original.AdvancedProof.Targets, bound.AdvancedProof.Targets) {
		return false
	}
	unchanged := bound
	unchanged.AdvancedProof = original.AdvancedProof
	return reflect.DeepEqual(unchanged, original)
}
func migrationCheckpointBaselines(values map[string]Baseline) []Baseline {
	out := []Baseline{}
	for _, key := range migrationKeys(values) {
		out = append(out, migrationClone(values[key]))
	}
	return out
}

type MigrationStore struct {
	targets   map[string]Target
	plan      *MigrationPlan
	draft     *MigrationDraft
	outcome   *MigrationOutcome
	reconcile bool
}

func migrationTarget(t Target) string { return t.Schema + "\x00" + t.Table }
func migrationClone(b Baseline) Baseline {
	b.Facts = cloneFacts(b.Facts)
	b.Attributes = copyAttrs(b.Attributes)
	b.Columns = slices.Clone(b.Columns)
	b.Keys = slices.Clone(b.Keys)
	for i := range b.Keys {
		b.Keys[i].Columns = slices.Clone(b.Keys[i].Columns)
		b.Keys[i].ReferenceColumns = slices.Clone(b.Keys[i].ReferenceColumns)
	}
	b.Indexes = slices.Clone(b.Indexes)
	for i := range b.Indexes {
		b.Indexes[i].Columns = slices.Clone(b.Indexes[i].Columns)
	}
	return b
}
func migrationKeys(m map[string]Baseline) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
func migrationCapture(ctx context.Context, a Adapter, t Target, baselines map[string]Baseline) (Baseline, error) {
	key := migrationTarget(t)
	if b, ok := baselines[key]; ok {
		if b.Target.Create != t.Create {
			return Baseline{}, ErrInvalid
		}
		return b, nil
	}
	if len(baselines) >= MaxMigrationObjects {
		return Baseline{}, errors.New("The migration captures at most 32 tables, including every incoming owner and referenced table. Split this migration explicitly.")
	}
	b, err := a.StructureLoad(ctx, t)
	if err != nil {
		return b, err
	}
	if !ValidBaseline(b) {
		return b, ErrUnsupported
	}
	if len(baselines) > 0 {
		for _, old := range baselines {
			if old.Engine != b.Engine {
				return b, ErrUnsupported
			}
			break
		}
	}
	b.ID = Token()
	if b.ID == "" {
		return b, ErrInvalid
	}
	baselines[key] = b
	return b, nil
}
func migrationRepairKey(b Baseline, name string) (Key, error) {
	for _, k := range b.Keys {
		if k.Name == name {
			if !k.Supported || k.Kind != "foreign" || k.Reference == nil || b.Facts == nil {
				return Key{}, ErrUnsupported
			}
			for _, c := range b.Facts.Table.Constraints.Items {
				if c.Ref.Name == name {
					// Recreating a summarized FK must not erase native semantics.
					if c.Deferrable.Value == nil || *c.Deferrable.Value || c.InitiallyDeferred.Value == nil || *c.InitiallyDeferred.Value || c.Validated.Value == nil || !*c.Validated.Value || c.Enforced.Value == nil || !*c.Enforced.Value || c.Inherited.Value == nil || *c.Inherited.Value || len(c.SetColumns.Items) > 0 || c.Match.Value == nil || *c.Match.Value != "SIMPLE" && *c.Match.Value != "NONE" && *c.Match.Value != "s" {
						return Key{}, errors.New("The selected foreign key has unexposed, deferred, unvalidated or nondefault MATCH semantics; preserve it in a separately reviewed manual migration.")
					}
					return k, nil
				}
			}
		}
	}
	return Key{}, errors.New("The individually selected foreign key is absent or cannot be preserved.")
}
func migrationDropKey(b Baseline, name string) Baseline {
	b = migrationClone(b)
	keys := []Key{}
	for _, k := range b.Keys {
		if k.Name != name {
			keys = append(keys, k)
		}
	}
	b.Keys = keys
	if b.Facts != nil {
		cs := []sc.Constraint{}
		for _, c := range b.Facts.Table.Constraints.Items {
			if c.Ref.Name != name {
				cs = append(cs, c)
			}
		}
		b.Facts.Table.Constraints.Items = cs
		b.Facts.Table.Dependencies = sc.DerivedDependencies(b.Facts.Table)
	}
	return b
}
func migrationIncoming(b Baseline, source Target, k KeyEdit, add bool) Baseline {
	if b.Facts == nil || k.Reference == nil || migrationTarget(b.Target) != migrationTarget(*k.Reference) {
		return b
	}
	b = migrationClone(b)
	out := []Incoming{}
	for _, x := range b.Facts.Incoming {
		if x.Schema != source.Schema || x.Table != source.Table || x.Name != k.Name {
			out = append(out, x)
		}
	}
	if add {
		out = append(out, Incoming{Schema: source.Schema, Table: source.Table, Name: k.Name, Columns: append([]string(nil), k.ReferenceColumns...)})
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].Schema+"\x00"+out[i].Table+"\x00"+out[i].Name < out[j].Schema+"\x00"+out[j].Table+"\x00"+out[j].Name
	})
	b.Facts.Incoming = out
	return b
}

// Only this server-derived projection is used for subsequent metadata planning.
// Runtime never accepts its synthetic fingerprints as observation evidence.
func migrationProject(b Baseline, d Draft) (Baseline, error) {
	b = migrationClone(b)
	if b.Facts == nil {
		if d.RenameTable != nil {
			b.Target.Table = *d.RenameTable
		}
		b.Target.Create = d.DropTable
		return b, nil
	}
	b = PlanningSource(b, d, b.Engine)
	for _, c := range d.Columns {
		b.Columns = append(b.Columns, ObservedColumn{Name: c.Name, Nullable: c.Nullable})
	}
	for _, e := range d.Keys {
		if e.Action != "add" {
			b = migrationDropKey(b, e.Name)
		}
	}
	for _, e := range d.Keys {
		if e.Action == "drop" {
			continue
		}
		k := Key{Kind: e.Kind, Name: e.Name, Columns: e.Columns, Reference: e.Reference, ReferenceColumns: e.ReferenceColumns, OnUpdate: e.OnUpdate, OnDelete: e.OnDelete, Supported: true}
		b.Keys = append(b.Keys, k)
	}
	cols := []sc.Column{}
	for _, c := range b.Facts.Table.Columns.Items {
		drop := false
		for _, x := range d.Changes {
			drop = drop || x.Name == c.Ref.Name && x.Drop
		}
		if !drop {
			cols = append(cols, c)
		}
	}
	b.Facts.Table.Columns.Items = cols

	for _, c := range d.Changes {
		if c.RenameTo != nil {
			renameFacts(b.Facts, b.Target, c.Name, *c.RenameTo)
			for i := range b.Columns {
				if b.Columns[i].Name == c.Name {
					b.Columns[i].Name = *c.RenameTo
				}
			}
			if attrs, ok := b.Attributes[c.Name]; ok {
				delete(b.Attributes, c.Name)
				b.Attributes[*c.RenameTo] = attrs
				if _, exists := attrs["attname"]; exists {
					attrs["attname"] = *c.RenameTo
				}
			}
			for i := range b.Keys {
				for j, n := range b.Keys[i].Columns {
					if n == c.Name {
						b.Keys[i].Columns[j] = *c.RenameTo
					}
				}
			}
			for i := range b.Indexes {
				for j, n := range b.Indexes[i].Columns {
					if n == c.Name {
						b.Indexes[i].Columns[j] = *c.RenameTo
					}
				}
			}
		}
	}
	if d.RenameTable != nil {
		renameFacts(b.Facts, b.Target, "", *d.RenameTable)
		b.Target.Table = *d.RenameTable
	}
	b.Target.Create = d.DropTable
	return b, nil
}

func migrationOrder(d MigrationDraft, baselines ...map[string]Baseline) ([]MigrationObject, error) {
	byTarget := map[string]string{}
	byID := map[string]MigrationObject{}
	deps := map[string]map[string]bool{}
	for _, o := range d.Objects {
		byTarget[migrationTarget(o.Target)] = o.ID
		if o.Draft.RenameTable != nil {
			t := o.Target
			t.Table = *o.Draft.RenameTable
			byTarget[migrationTarget(t)] = o.ID
		}
		byID[o.ID] = o
		deps[o.ID] = map[string]bool{}
		for _, id := range o.After {
			deps[o.ID][id] = true
		}
	}
	for _, o := range d.Objects {
		for _, k := range o.Draft.Keys {
			if k.Action != "drop" && k.Reference != nil {
				id := byTarget[migrationTarget(*k.Reference)]
				if id != "" && id != o.ID {
					deps[o.ID][id] = true
				}
			}
		}
	}
	if len(baselines) > 0 {
		for _, o := range d.Objects {
			if !o.Draft.DropTable {
				continue
			}
			b := baselines[0][migrationTarget(o.Target)]
			if b.Facts == nil {
				continue
			}
			for _, incoming := range b.Facts.Incoming {
				id := byTarget[migrationTarget(Target{Schema: incoming.Schema, Table: incoming.Table})]
				if child, ok := byID[id]; ok && id != o.ID && child.Draft.DropTable {
					deps[o.ID][id] = true
				}
			}
		}
	}
	out := []MigrationObject{}
	done := map[string]bool{}
	for len(out) < len(d.Objects) {
		next := ""
		for id := range byID {
			if done[id] {
				continue
			}
			ready := true
			for dep := range deps[id] {
				ready = ready && done[dep]
			}
			if ready && (next == "" || id < next) {
				next = id
			}
		}
		if next == "" {
			return nil, errors.New("The migration dependency graph is cyclic. Create cyclic tables without cyclic foreign keys, reconcile, then author the explicit foreign keys in a new migration.")
		}
		done[next] = true
		out = append(out, byID[next])
	}
	return out, nil
}
func (s *MigrationStore) Preview(ctx context.Context, a MigrationAdapter, d MigrationDraft) (MigrationReply, error) {
	s.plan = nil
	if s.reconcile {
		return s.Status(), errors.New("Reconcile retained execution evidence before preparing another migration. Failed and unstarted intent is never replayed.")
	}
	if !d.Valid() {
		return MigrationReply{}, ErrInvalid
	}
	raw, _ := json.Marshal(d)
	_ = json.Unmarshal(raw, &d)
	s.draft = &d
	initial := map[string]Baseline{}
	for _, o := range d.Objects {
		if _, err := migrationCapture(ctx, a, o.Target, initial); err != nil {
			return s.Status(), err
		}
	}
	for _, o := range d.Objects {
		if o.Draft.RenameTable != nil {
			dest := Target{Schema: o.Target.Schema, Table: *o.Draft.RenameTable, Create: true}
			if _, err := migrationCapture(ctx, a, dest, initial); err != nil {
				return s.Status(), errors.New("The reviewed rename destination is occupied or unprovable.")
			}
		}
	}
	captureReference := func(target Target) error {
		for _, o := range d.Objects {
			final := migrationFinalTarget(o.Target, d)
			if migrationTarget(final) == migrationTarget(target) {
				return nil
			}
		}
		_, err := migrationCapture(ctx, a, target, initial)
		return err
	}
	oldKeys := map[string]Key{}
	for _, r := range d.Repairs {
		b, err := migrationCapture(ctx, a, r.Target, initial)
		if err != nil {
			return s.Status(), err
		}
		k, err := migrationRepairKey(b, r.Key)
		if err != nil {
			return s.Status(), err
		}
		oldKeys[r.ID] = k
		if _, err = migrationCapture(ctx, a, *k.Reference, initial); err != nil {
			return s.Status(), err
		}
		if r.Replacement != nil {
			if err = captureReference(*r.Replacement.Reference); err != nil {
				return s.Status(), err
			}
		}
		for _, o := range d.Objects {
			if migrationTarget(o.Target) == migrationTarget(r.Target) {
				for _, e := range o.Draft.Keys {
					if e.Name == r.Key {
						return s.Status(), errors.New("A selected repair key cannot also be edited in its object's draft.")
					}
				}
			}
		}
	}
	// Capture owners as guards, never as automatically selected repairs.
	seeds := migrationKeys(initial)
	for _, key := range seeds {
		b := initial[key]
		if b.Facts == nil {
			continue
		}
		for _, x := range b.Facts.Incoming {
			if _, err := migrationCapture(ctx, a, Target{Schema: x.Schema, Table: x.Table}, initial); err != nil {
				return s.Status(), err
			}
		}
		for _, k := range b.Keys {
			if k.Reference != nil {
				if err := captureReference(*k.Reference); err != nil {
					return s.Status(), err
				}
			}
		}
	}
	for _, o := range d.Objects {
		for _, k := range o.Draft.Keys {
			if k.Reference != nil {
				if err := captureReference(*k.Reference); err != nil {
					return s.Status(), err
				}
			}
		}
	}
	for _, o := range d.Objects {
		b := initial[migrationTarget(o.Target)]
		if o.Draft.RenameTable == nil {
			renames := false
			for _, c := range o.Draft.Changes {
				renames = renames || c.RenameTo != nil
			}
			if !renames {
				continue
			}
		}
		if b.Facts == nil {
			continue
		}
		selected := func(t Target, name string) bool {
			for _, r := range d.Repairs {
				if migrationTarget(r.Target) == migrationTarget(t) && r.Key == name {
					return true
				}
			}
			return false
		}
		affected := func(columns []string) bool {
			if o.Draft.RenameTable != nil {
				return true
			}
			for _, c := range o.Draft.Changes {
				if c.RenameTo != nil {
					for _, name := range columns {
						if name == c.Name {
							return true
						}
					}
				}
			}
			return false
		}
		for _, incoming := range b.Facts.Incoming {
			if affected(incoming.Columns) && !selected(Target{Schema: incoming.Schema, Table: incoming.Table}, incoming.Name) {
				return s.Status(), fmt.Errorf("Rename requires an individually selected repair for incoming foreign key %s.%s.%s, with an explicitly authored replacement mapping or permanent DROP.", incoming.Schema, incoming.Table, incoming.Name)
			}
		}
		for _, k := range b.Keys {
			if k.Kind == "foreign" && affected(k.Columns) && !selected(b.Target, k.Name) {
				return s.Status(), fmt.Errorf("Rename requires an individually selected repair for source foreign key %s; author its replacement columns explicitly.", k.Name)
			}
		}
	}
	for _, o := range d.Objects {
		b := initial[migrationTarget(o.Target)]
		if b.Engine == "postgresql" && b.Advanced == nil && (o.Draft.Reconstruct || len(o.Draft.ColumnOrder) > 0) {
			temp := Target{Schema: b.Target.Schema, Table: "__dbeer_rebuild_" + b.Fingerprint[:12], Create: true}
			if _, err := migrationCapture(ctx, a, temp, initial); err != nil {
				return s.Status(), errors.New("The reviewed reconstruction temporary destination is occupied or unprovable.")
			}
		}
	}
	order, err := migrationOrder(d, initial)
	if err != nil {
		return s.Status(), err
	}
	p := &MigrationPlan{ID: Token(), Draft: d, Steps: []MigrationStep{}, Baselines: []Baseline{}, initial: initial, created: time.Now(), Risks: []string{"This migration is not atomic. Every displayed SQL execution unit and selected repair requires this exact review. Earlier acknowledged units survive later failure or Stop; no unit is retried or reconnected automatically.", "Selected foreign-key removals create a referential-integrity gap until their reviewed replacements succeed. Concurrent writes may make replacement fail. A permanent DROP repair intentionally leaves that constraint absent. Unselected dependencies are never removed, CASCADE is never added, and checks are never disabled by migration orchestration.", "Expected intermediate structures are the captured identity/fingerprint plus exactly the displayed prior typed transitions, with all other facts preserved. Server-generated fingerprints are observed after acknowledgement, never predicted or accepted from a client. Preview reads catalogs only; it does not evaluate expressions or read user rows.", "SQL export is for manual execution outside guarded Apply: it does not carry freshness checks, preservation verification, authorization or outcome tracking. Portable intent contains no credentials or grants and requires a new connected Preview."}}
	if p.ID == "" {
		return s.Status(), ErrInvalid
	}
	virtual := map[string]Baseline{}
	for _, key := range migrationKeys(initial) {
		b := initial[key]
		virtual[key] = migrationClone(b)
		p.Baselines = append(p.Baselines, b)
		p.Engine = b.Engine
	}
	checkpoints := []string{}
	expectation := func() []MigrationExpectation {
		out := []MigrationExpectation{}
		for _, key := range migrationKeys(initial) {
			b := initial[key]
			out = append(out, MigrationExpectation{Target: b.Target, InitialFingerprint: b.Fingerprint, IdentityDigest: Fingerprint([]string{b.Scope, b.Identity, b.Guard}), AfterSteps: append([]string{}, checkpoints...)})
		}
		return out
	}
	bytesSQL := 0
	appendStep := func(id, object, phase string, t Target, draft Draft) error {
		if len(p.Steps) >= MaxMigrationSteps {
			return ErrInvalid
		}
		b, ok := virtual[migrationTarget(t)]
		if !ok || b.Target.Create != t.Create {
			return ErrInvalid
		}
		projected, e := migrationProject(b, draft)
		if e != nil {
			return e
		}
		load := func(target Target) (Baseline, error) {
			if found, ok := virtual[migrationTarget(target)]; ok {
				if found.Target.Create != target.Create {
					return Baseline{}, ErrInvalid
				}
				return migrationClone(found), nil
			}
			return Baseline{}, errors.New("A referenced target was not captured in the bounded migration. Add its explicit object or repair intent before Preview.")
		}
		var single Store
		single.baseline = &b
		b.ID = Token()
		reply, e := single.PreviewContext(ctx, migrationPlanningAdapter{MigrationAdapter: a, load: load}, b.ID, draft)
		if e != nil {
			return fmt.Errorf("Migration step %s: %w", id, e)
		}
		prepared := *reply.Plan
		if len(prepared.SQL) == 0 {
			return ErrInvalid
		}
		for _, sql := range prepared.SQL {
			bytesSQL += len(sql)
		}
		if bytesSQL > MaxSQLBytes {
			return ErrInvalid
		}
		before := expectation()
		checkpoints = append(checkpoints, id)
		atomic := p.Engine == "sqlite"
		if reconstruction := prepared.Reconstruction; reconstruction != nil && p.Engine == "postgresql" {
			switch reconstruction.Method {
			case "postgresql-copy", "postgresql-native-cluster", "postgresql-advanced-copy":
				atomic = true
			}
		}
		step := MigrationStep{ID: id, ObjectID: object, Phase: phase, Target: t, Draft: draft, SQL: prepared.SQL, Before: before, After: expectation(), Risks: prepared.Risks, Consequences: prepared.Consequences, Atomic: atomic}
		step.Digest = Fingerprint([]any{step, prepared.Conditions, prepared.Reconstruction, prepared.Types, prepared.IndexGuards})
		p.Destructive = p.Destructive || prepared.Destructive
		p.Steps = append(p.Steps, step)
		p.prepared = append(p.prepared, prepared)
		virtual[migrationTarget(t)] = projected
		if projected.Target.Table != t.Table {
			old := migrationClone(b)
			old.Target = Target{Schema: t.Schema, Table: t.Table, Create: true}
			old.Identity = ""
			virtual[migrationTarget(t)] = old
			virtual[migrationTarget(projected.Target)] = projected
		}
		for _, edit := range draft.Keys {
			if edit.Kind != "foreign" {
				continue
			}
			if edit.Action != "add" {
				for _, old := range b.Keys {
					if old.Name == edit.Name {
						key := KeyEdit{Name: old.Name, Reference: old.Reference, ReferenceColumns: old.ReferenceColumns}
						for other, v := range virtual {
							virtual[other] = migrationIncoming(v, t, key, false)
						}
					}
				}
			}
			if edit.Action != "drop" {
				for other, v := range virtual {
					virtual[other] = migrationIncoming(v, t, edit, true)
				}
			}
		}
		if draft.DropTable {
			for _, old := range b.Keys {
				if old.Kind == "foreign" {
					key := KeyEdit{Name: old.Name, Reference: old.Reference}
					for other, v := range virtual {
						virtual[other] = migrationIncoming(v, t, key, false)
					}
				}
			}
		}
		return nil
	}
	repairs := append([]MigrationRepair(nil), d.Repairs...)
	sort.Slice(repairs, func(i, j int) bool { return repairs[i].ID < repairs[j].ID })
	for _, r := range repairs {
		k := oldKeys[r.ID]
		draft := Draft{Columns: []Column{}, Keys: []KeyEdit{{Action: "drop", Kind: "foreign", Name: k.Name}}, AllowDestructive: true}
		if err := appendStep(migrationStepID("drop", r.ID), r.ID, "repairDrop", r.Target, draft); err != nil {
			return s.Status(), err
		}
	}
	for _, o := range order {
		if err := appendStep(migrationStepID("object", o.ID), o.ID, "object", o.Target, o.Draft); err != nil {
			return s.Status(), err
		}
	}
	for _, r := range repairs {
		if r.Replacement != nil {
			draft := Draft{Columns: []Column{}, Keys: []KeyEdit{*r.Replacement}}
			if err := appendStep(migrationStepID("restore", r.ID), r.ID, "repairAdd", migrationFinalTarget(r.Target, d), draft); err != nil {
				return s.Status(), err
			}
		}
	}
	// The retained digest binds private captured evidence and every expected unit.
	p.Digest = Fingerprint([]any{p, p.prepared, func() []any {
		out := []any{}
		for _, key := range migrationKeys(initial) {
			b := initial[key]
			out = append(out, []any{b.Scope, b.Identity, b.Guard, b.Facts, b.Attributes})
		}
		return out
	}()})
	encoded, _ := json.Marshal(p)
	if len(encoded) > 6<<20 {
		return s.Status(), errors.New("The migration review exceeds the 6 MiB metadata limit. Split the migration explicitly.")
	}
	s.targets = map[string]Target{}
	for key, b := range initial {
		s.targets[key] = b.Target
	}
	s.plan = p
	return MigrationReply{Plan: p, Draft: s.draft, Outcome: s.outcome}, nil
}

type migrationPlanningAdapter struct {
	MigrationAdapter
	load func(Target) (Baseline, error)
}

func (a migrationPlanningAdapter) StructurePrepare(ctx context.Context, b Baseline, d Draft) (Prepared, error) {
	return a.StructurePrepareMigration(ctx, b, d, a.load)
}
func (s *MigrationStore) Resolve(r Apply) (*MigrationPlan, error) {
	if !r.Valid() || s.plan == nil || s.plan.ID != r.PlanID || s.plan.Digest != r.Digest || time.Since(s.plan.created) > 10*time.Minute || s.reconcile || s.outcome != nil && s.outcome.PlanID == r.PlanID {
		return nil, ErrStale
	}
	return s.plan, nil
}
func (s *MigrationStore) Status() MigrationReply {
	return MigrationReply{Draft: s.draft, Outcome: s.outcome}
}
func (s *MigrationStore) Close() { s.plan = nil }
func (s *MigrationStore) Export(r Apply) (MigrationReply, error) {
	p, err := s.Resolve(r)
	if err != nil {
		return s.Status(), err
	}
	var sql strings.Builder
	sql.WriteString("-- DBeer reviewed migration: MANUAL execution.\n-- No freshness guards, preservation verification, automatic rollback, grants or outcome tracking.\n-- Review the original plan and database context before executing. Never replay after partial or unknown completion.\n")
	for _, step := range p.Steps {
		sql.WriteString("\n-- " + step.ID + " " + step.Digest + "\n")
		for _, statement := range step.SQL {
			sql.WriteString(statement)
			sql.WriteByte('\n')
		}
	}
	return MigrationReply{Export: &MigrationExport{Version: 1, Draft: p.Draft, SQL: sql.String()}}, nil
}

func migrationReference(before, after, source Baseline, d Draft) bool {
	if before.Target != after.Target || before.Scope != after.Scope || before.Identity != after.Identity || before.Guard != after.Guard || !reflect.DeepEqual(before.Attributes, after.Attributes) || !reflect.DeepEqual(before.AdvancedEvidence, after.AdvancedEvidence) {
		return false
	}
	if before.Engine == "sqlite" {
		return reflect.DeepEqual(before.Columns, after.Columns) && reflect.DeepEqual(before.Keys, after.Keys) && reflect.DeepEqual(before.Indexes, after.Indexes)
	}
	expected := migrationClone(before)
	for _, edit := range d.Keys {
		if edit.Kind != "foreign" {
			continue
		}
		k := edit
		if edit.Action != "add" {
			for _, old := range source.Keys {
				if old.Name == edit.Name {
					k.Reference = old.Reference
					k.ReferenceColumns = old.ReferenceColumns
				}
			}
			expected = migrationIncoming(expected, source.Target, k, false)
		}
		if edit.Action != "drop" {
			expected = migrationIncoming(expected, source.Target, edit, true)
		}
	}
	if d.DropTable {
		for _, old := range source.Keys {
			if old.Kind == "foreign" {
				expected = migrationIncoming(expected, source.Target, KeyEdit{Name: old.Name, Reference: old.Reference}, false)
			}
		}
	}
	actual := cloneFacts(after.Facts)
	if expected.Facts != nil && actual != nil {
		expected.Facts.Incoming = append([]Incoming{}, expected.Facts.Incoming...)
		actual.Incoming = append([]Incoming{}, actual.Incoming...)
	}
	return reflect.DeepEqual(expected.Facts, actual)
}
func migrationReadCurrent(ctx context.Context, a Adapter, current map[string]Baseline) (map[string]Baseline, error) {
	fresh := map[string]Baseline{}
	for _, key := range migrationKeys(current) {
		b := current[key]
		x, err := a.StructureLoad(ctx, b.Target)
		if err != nil || !ValidBaseline(x) || x.Fingerprint != b.Fingerprint || x.Scope != b.Scope || x.Identity != b.Identity || x.Guard != b.Guard {
			return nil, ErrStale
		}
		x.ID = b.ID
		fresh[key] = x
	}
	return fresh, nil
}
func (s *MigrationStore) Apply(ctx context.Context, a MigrationAdapter, r Apply) (MigrationReply, error) {
	p, err := s.Resolve(r)
	if err != nil {
		return s.Status(), err
	}
	outcome := &MigrationOutcome{PlanID: p.ID, ExecutionID: r.ExecutionID, State: "applying", ReconciliationRequired: true, Steps: make([]MigrationStepOutcome, len(p.Steps))}
	s.outcome = outcome
	s.reconcile = true
	s.plan = nil
	for i, step := range p.Steps {
		outcome.Steps[i] = MigrationStepOutcome{ID: step.ID, State: "notStarted", Statements: make([]StepOutcome, len(step.SQL))}
		for j := range outcome.Steps[i].Statements {
			outcome.Steps[i].Statements[j].State = "notStarted"
		}
	}
	current := p.initial
	acknowledged := 0
	checkpointAdapter, hasCheckpointAdapter := a.(MigrationCheckpointAdapter)
	checkpointVerified := false
	stop := func(state string) MigrationReply { outcome.State = state; return s.Status() }
	for i, step := range p.Steps {
		if ctx.Err() != nil {
			if acknowledged > 0 {
				return stop("partiallyApplied"), nil
			}
			return stop("cancelled"), nil
		}
		fresh, e := migrationReadCurrent(ctx, a, current)
		if e != nil {
			outcome.Steps[i].Message = "A captured migration object changed or could not be observed. No next unit was dispatched; reconcile explicitly."
			if acknowledged > 0 {
				return stop("partiallyApplied"), nil
			}
			return stop("failed"), nil
		}
		current = fresh
		key := migrationTarget(step.Target)
		before := current[key]
		prepared := p.prepared[i]
		originalReferences := prepared.References
		prepared.References = nil
		if prepared.AdvancedProof != nil {
			for _, ref := range originalReferences {
				observed, exists := current[migrationTarget(ref.Target)]
				if !exists || observed.Target != ref.Target {
					outcome.Steps[i].Message = "An originally captured advanced reference is unavailable; no next unit was dispatched."
					if acknowledged == 0 {
						return stop("failed"), nil
					}
					return stop("partiallyApplied"), nil
				}
				prepared.References = append(prepared.References, observed)
			}
		} else {
			for _, other := range migrationKeys(current) {
				if other != key {
					prepared.References = append(prepared.References, current[other])
				}
			}
		}
		if prepared.AdvancedProof != nil && len(prepared.Conditions) == 1 && (prepared.Conditions[0].Operation.Kind == "addKey" || prepared.Conditions[0].Operation.Kind == "dropKey") && prepared.Conditions[0].Operation.Key != nil && prepared.Conditions[0].Operation.Key.Kind == "foreign" && checkpointVerified && hasCheckpointAdapter {
			load := func(t Target) (Baseline, error) {
				b, exists := current[migrationTarget(t)]
				if !exists || b.Target != t {
					return Baseline{}, ErrStale
				}
				return migrationClone(b), nil
			}
			bound, err := checkpointAdapter.StructureBindMigrationCheckpoint(ctx, before, prepared, step.Draft, load)
			if err != nil || !migrationCheckpointBindingMatches(prepared, bound) {
				outcome.Steps[i].Message = "The acknowledged native checkpoint no longer matches this exact reviewed foreign-key restoration; no next unit was dispatched."
				return stop("partiallyApplied"), nil
			}
			prepared = bound
		}
		xs := a.StructureApplySteps(ctx, before, prepared)
		unit := &outcome.Steps[i]
		ok, unknown, sent := len(xs) == len(step.SQL), false, false
		for j, x := range xs {
			if j >= len(unit.Statements) {
				unit.Statements[len(unit.Statements)-1] = StepOutcome{State: "unknown", Message: "The adapter returned inconsistent execution evidence; reconcile explicitly."}
				unknown = true
				break
			}
			switch x.State {
			case "applied":
				sent = true
				acknowledged++
			case "unknown":
				sent = true
				unknown = true
				ok = false
			case "failed", "rolledBack", "notStarted":
				ok = false
			default:
				x.State = "unknown"
				unknown = true
				sent = true
				ok = false
			}
			unit.Statements[j] = StepOutcome{State: x.State, Message: x.Message}
			if x.Message != "" && x.State == "applied" {
				ok = false
				unit.Message = x.Message
			}
		}
		if unknown {
			if retire, ok := a.(interface{ StructureMigrationRetire() }); ok {
				retire.StructureMigrationRetire()
			}
			unit.State = "outcomeUnknown"
			return stop("outcomeUnknown"), nil
		}
		if !ok {
			unit.State = "failed"
			if sent {
				unit.State = "partiallyApplied"
			}
			if acknowledged > 0 {
				return stop("partiallyApplied"), nil
			}
			if ctx.Err() != nil {
				return stop("cancelled"), nil
			}
			return stop("failed"), nil
		}
		unit.State = "applied"
		// Every affected object advances only from a positively checked observation.
		next := map[string]Baseline{}
		for _, other := range migrationKeys(current) {
			old := current[other]
			target := old.Target
			renamedDestination := prepared.ResultTarget != nil && other == migrationTarget(*prepared.ResultTarget) && other != key
			if renamedDestination {
				target = *prepared.ResultTarget
			}
			if other == key {
				target.Create = prepared.DroppedTarget
				if prepared.ResultTarget != nil {
					target = *prepared.ResultTarget
				}
			}
			observed, readErr := a.StructureLoad(ctx, target)
			if readErr != nil || !ValidBaseline(observed) {
				unit.Message = fmt.Sprintf("The SQL unit was acknowledged, but expected intermediate metadata for %s.%s could not be confirmed. Reconcile before continuing.", target.Schema, target.Table)
				return stop("partiallyApplied"), nil
			}
			observed.ID = old.ID
			if renamedDestination && observed.Engine != "sqlite" && observed.Identity != before.Identity {
				unit.Message = "Rename destination identity did not match the reviewed source."
				return stop("partiallyApplied"), nil
			}
			if other == key && target.Table != old.Target.Table {
				absent, e := a.StructureLoad(ctx, Target{Schema: old.Target.Schema, Table: old.Target.Table, Create: true})
				if e != nil || !ValidBaseline(absent) || !absent.Target.Create {
					unit.Message = "The rename was acknowledged but old-name absence could not be confirmed."
					return stop("partiallyApplied"), nil
				}
				absent.ID = old.ID
				next[other] = absent
				next[migrationTarget(target)] = observed
			} else if _, renamed := next[other]; !renamed {
				next[other] = observed
			}
			unit.Observed = append(unit.Observed, MigrationObservation{Target: observed.Target, Fingerprint: observed.Fingerprint, IdentityDigest: Fingerprint([]string{observed.Scope, observed.Identity, observed.Guard})})
		}
		covered := map[string]bool{}
		special := prepared.AdvancedProof != nil || prepared.Reconstruction != nil && (prepared.Reconstruction.Method == "postgresql-advanced-copy" || prepared.Reconstruction.Method == "postgresql-native-cluster")
		if special && hasCheckpointAdapter {
			verified, err := checkpointAdapter.StructureMigrationCheckpoint(ctx, MigrationCheckpoint{Plan: prepared, Target: step.Target, Draft: step.Draft, Before: migrationCheckpointBaselines(current), After: migrationCheckpointBaselines(next)})
			if err != nil {
				unit.Message = "The acknowledged unit's complete native checkpoint could not be confirmed. Reconcile before continuing."
				return stop("partiallyApplied"), nil
			}
			for _, target := range verified {
				k := migrationTarget(target)
				if !target.Valid() || target.Create || current[k].Target != target || next[k].Target != target || covered[k] {
					unit.Message = "The engine returned an invalid native checkpoint scope."
					return stop("partiallyApplied"), nil
				}
				covered[k] = true
			}
			if !covered[key] {
				unit.Message = "The engine did not prove the acknowledged source checkpoint."
				return stop("partiallyApplied"), nil
			}
			checkpointVerified = true
		}
		for _, other := range migrationKeys(current) {
			if other == key || covered[other] {
				continue
			}
			if prepared.ResultTarget != nil && other == migrationTarget(*prepared.ResultTarget) && other != key {
				continue
			}
			if !migrationReference(current[other], next[other], before, step.Draft) {
				unit.Message = "The acknowledged unit changed unselected captured metadata. Reconcile before continuing."
				return stop("partiallyApplied"), nil
			}
		}
		current = next
	}
	outcome.State = "applied"
	return s.Status(), nil
}
func (s *MigrationStore) Reconcile(ctx context.Context, a Adapter) (MigrationReply, error) {
	s.plan = nil
	if s.draft == nil {
		return s.Status(), ErrInvalid
	}
	observed := []Baseline{}
	targets := map[string]Target{}
	for key, t := range s.targets {
		targets[key] = t
	}
	for _, o := range s.draft.Objects {
		targets[migrationTarget(o.Target)] = o.Target
	}
	for _, r := range s.draft.Repairs {
		targets[migrationTarget(r.Target)] = r.Target
		if r.Replacement != nil {
			targets[migrationTarget(*r.Replacement.Reference)] = *r.Replacement.Reference
		}
	}
	// Include all previously captured reference/incoming owners, even if absent now.
	if s.outcome != nil {
		for _, step := range s.outcome.Steps {
			for _, b := range step.Observed {
				targets[migrationTarget(b.Target)] = b.Target
			}
		}
	}
	keys := []string{}
	for key := range targets {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		target := targets[key]
		target.Create = true
		target.Reconcile = true
		b, err := a.StructureLoad(ctx, target)
		if err != nil || !ValidBaseline(b) {
			return s.Status(), errors.New("Reconciliation could not observe every captured migration target. Execution intent and outcomes remain retained.")
		}
		b.ID = Token()
		observed = append(observed, b)
	}
	s.reconcile = false
	if s.outcome != nil {
		s.outcome.ReconciliationRequired = false
	}
	reply := s.Status()
	reply.Observed = observed
	return reply, nil
}

func (s *MigrationStore) NeedsReconciliation() bool { return s.reconcile }

func migrationFinalTarget(t Target, d MigrationDraft) Target {
	for _, o := range d.Objects {
		if migrationTarget(o.Target) == migrationTarget(t) && o.Draft.RenameTable != nil {
			t.Table = *o.Draft.RenameTable
			t.Create = false
			return t
		}
	}
	return t
}

func migrationStepID(phase, id string) string { return phase + "_" + Fingerprint(id)[:24] }
