package tableedit

import (
	"encoding/json"
	"errors"
	"strings"
)

type AdvancedKindsAdapter interface{ SupportsAdvancedKinds() bool }

const AdvancedKindsCapability = "tableStructureAdvancedKindsV1"

// AdvancedKindSupport is observation, never execution authority. Operations are
// closed families; the existing typed planner still checks each concrete edit.
type AdvancedKindSupport struct {
	Relations        []AdvancedRelationFact  `json:"relations,omitempty"`
	Kinds            []string                `json:"kinds"`
	Scope            string                  `json:"scope"`
	FamilyCount      int                     `json:"familyCount"`
	Nontransactional bool                    `json:"nontransactional"`
	Operations       []AdvancedKindOperation `json:"operations"`
}
type AdvancedRelationFact struct {
	Target           Target               `json:"target"`
	Kind             string               `json:"kind"`
	Persistence      string               `json:"persistence"`
	PartitionMember  bool                 `json:"partitionMember"`
	StorageEngine    string               `json:"storageEngine,omitempty"`
	Parents          []Target             `json:"parents"`
	RowSecurity      bool                 `json:"rowSecurity"`
	ForceRowSecurity bool                 `json:"forceRowSecurity"`
	TypeBinding      *TypeReference       `json:"typeBinding,omitempty"`
	Policies         []AdvancedPolicyFact `json:"policies"`
}
type AdvancedPolicyFact struct {
	Name       string   `json:"name"`
	Command    string   `json:"command"`
	Permissive bool     `json:"permissive"`
	Roles      []string `json:"roles"`
}
type AdvancedKindOperation struct {
	Kind      string `json:"kind"`
	Available bool   `json:"available"`
	Reason    string `json:"reason"`
}
type AdvancedEvidence struct {
	Facts   map[string]*Facts
	Targets []Target
	Rows    map[string][]map[string]any
}

var AdvancedOperationKinds = []string{"renameTable", "renameColumn", "addColumn", "dropColumn", "default", "nullable", "type", "index", "key", "foreignKey", "generation", "reconstruction", "hierarchy"}

func (a *AdvancedKindSupport) Valid(engine string) bool {
	if a == nil {
		return true
	}
	if engine != "postgresql" && engine != "mysql" {
		return false
	}
	if a.Scope != "table" && a.Scope != "only" && a.Scope != "operation" || a.FamilyCount < 1 || a.FamilyCount > 64 || len(a.Kinds) < 1 || len(a.Kinds) > 6 || len(a.Operations) != len(AdvancedOperationKinds) {
		return false
	}
	allowed := map[string]bool{}
	for _, k := range []string{"inheritanceParent", "inheritanceChild", "partitionParent", "partitionMember", "rowSecurity", "typed", "unlogged", "mySQLPartitions", "myISAM"} {
		allowed[k] = true
	}
	if engine == "postgresql" && a.Nontransactional {
		return false
	}
	if engine == "mysql" {
		myisam := false
		for _, kind := range a.Kinds {
			myisam = myisam || kind == "myISAM"
		}
		if myisam != a.Nontransactional {
			return false
		}
	}
	seen := map[string]bool{}
	for _, k := range a.Kinds {
		if !allowed[k] || seen[k] || strings.HasPrefix(k, "my") != (engine == "mysql") {
			return false
		}
		seen[k] = true
	}
	if len(a.Relations) > 0 {
		if len(a.Relations) != a.FamilyCount {
			return false
		}
		seen := map[Target]bool{}
		for _, r := range a.Relations {
			if !r.Target.Valid() || r.Target.Create || r.Target.Reconcile || seen[r.Target] || r.Kind != "table" && r.Kind != "partitionedTable" || r.Persistence != "permanent" && r.Persistence != "unlogged" || len(r.Parents) > 64 || len(r.Policies) > 128 || r.TypeBinding != nil && !r.TypeBinding.Valid() {
				return false
			}
			seen[r.Target] = true
			for _, p := range r.Parents {
				if !p.Valid() || p.Create || p.Reconcile {
					return false
				}
			}
			for _, p := range r.Policies {
				if !Identifier(p.Name) || p.Command != "all" && p.Command != "select" && p.Command != "insert" && p.Command != "update" && p.Command != "delete" || len(p.Roles) > 2048 {
					return false
				}
				for _, role := range p.Roles {
					if !Identifier(role) {
						return false
					}
				}
			}
			if engine == "postgresql" && r.StorageEngine != "" {
				return false
			}
			if engine == "mysql" && (r.StorageEngine != "InnoDB" && r.StorageEngine != "MyISAM" || r.RowSecurity || r.ForceRowSecurity || r.TypeBinding != nil || len(r.Policies) > 0 || r.Persistence != "permanent") {
				return false
			}
		}
	}
	for i, o := range a.Operations {
		if o.Kind != AdvancedOperationKinds[i] || o.Reason == "" || len(o.Reason) > 4096 {
			return false
		}
	}
	return true
}
func (a *AdvancedKindSupport) Permits(kind string) bool {
	if a == nil {
		return true
	}
	for _, o := range a.Operations {
		if o.Kind == kind {
			return o.Available
		}
	}
	return false
}
func (a *AdvancedKindSupport) Reason(kind string) string {
	if a != nil {
		for _, o := range a.Operations {
			if o.Kind == kind {
				return o.Reason
			}
		}
	}
	return "This advanced operation has no preservation proof."
}
func NewAdvancedSupport(kinds []string, scope string, count int, nontransactional bool, reasons map[string]string) *AdvancedKindSupport {
	a := &AdvancedKindSupport{Kinds: kinds, Scope: scope, FamilyCount: count, Nontransactional: nontransactional, Operations: []AdvancedKindOperation{}}
	for _, kind := range AdvancedOperationKinds {
		reason, blocked := reasons[kind]
		if !blocked {
			reason = "Available when the concrete typed edit passes its property and dependency checks."
		}
		a.Operations = append(a.Operations, AdvancedKindOperation{Kind: kind, Available: !blocked, Reason: reason})
	}
	return a
}

// CheckAdvancedDraft precedes expression/type resolution and reconstruction, so
// a portable draft cannot bypass a kind-specific server-model restriction.
func CheckAdvancedDraft(b Baseline, d Draft) error {
	a := b.Advanced
	if a == nil {
		return nil
	}
	if !a.Valid(b.Engine) || b.AdvancedEvidence == nil {
		return ErrUnsupported
	}
	need := func(kind string) error {
		if !a.Permits(kind) {
			return errors.New(a.Reason(kind))
		}
		return nil
	}
	if d.DropTable {
		return errors.New("Advanced table deletion requires a separately reviewed hierarchy/security/type-aware migration; this editor never emits a hidden descendant DROP.")
	}
	if d.RenameTable != nil {
		if e := need("renameTable"); e != nil {
			return e
		}
	}
	if len(d.Columns) > 0 {
		if e := need("addColumn"); e != nil {
			return e
		}
		for _, c := range d.Columns {
			reviewedBackfill := false
			for _, backfill := range d.Backfills {
				reviewedBackfill = reviewedBackfill || backfill.Column == c.Name
			}
			if !c.Nullable && !reviewedBackfill || c.Default.Kind != "none" || c.Generated != nil || c.Identity != nil || c.Type.Reference != nil {
				return errors.New("Advanced-table append requires a built-in column without default, generation or identity; a required column also needs its explicitly reviewed backfill.")
			}
		}
	}
	for _, c := range d.Changes {
		for kind, present := range map[string]bool{"renameColumn": c.RenameTo != nil, "dropColumn": c.Drop, "default": c.Default != nil, "nullable": c.Nullable != nil, "type": c.Type != nil || c.Unsigned != nil || c.Charset != nil || c.Collation != nil, "generation": c.Generated != nil || c.Identity != nil} {
			if present {
				if e := need(kind); e != nil {
					return e
				}
			}
		}
		if c.Default != nil && c.Default.Kind == "expression" {
			return errors.New("Advanced-table defaults currently admit exact typed literals, SQL NULL and DROP DEFAULT; expressions require explicit user-function and hierarchy-effect proof.")
		}
	}
	if len(d.Indexes) > 0 {
		if e := need("index"); e != nil {
			return e
		}
	}
	for _, key := range d.Keys {
		if key.Kind == "foreign" {
			if err := need("foreignKey"); err != nil {
				return err
			}
		}
	}
	if len(d.Keys) > 0 {
		if e := need("key"); e != nil {
			return e
		}
	}
	if d.NeedsAuthoringV5() {
		if e := need("reconstruction"); e != nil {
			return e
		}
	}
	return nil
}
func CloneAdvancedEvidence(e *AdvancedEvidence) *AdvancedEvidence {
	if e == nil {
		return nil
	}
	raw, _ := json.Marshal(e)
	var out AdvancedEvidence
	_ = json.Unmarshal(raw, &out)
	return &out
}
