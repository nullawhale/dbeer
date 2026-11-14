package postgres

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"time"

	"dbeer/helper/internal/tableedit"
)

type pgAdvancedCopyCheckpointPrivateColumn struct {
	PrimaryKeyName string
	Resolved       *tableedit.TypeGuard
}

type pgAdvancedCopyCheckpointPrivateCondition struct {
	Condition       tableedit.Condition
	OperationColumn *pgAdvancedCopyCheckpointPrivateColumn
	Columns         []pgAdvancedCopyCheckpointPrivateColumn
}

type pgAdvancedCopyCheckpointPrivateReference struct {
	Public           tableedit.Baseline
	Scope            string
	Identity         string
	Guard            string
	NativeDefinition string
	Attributes       map[string]map[string]any
	Facts            *tableedit.Facts
	AdvancedEvidence *tableedit.AdvancedEvidence
}

func pgAdvancedCopyCheckpointPrivateContent(p tableedit.Plan) string {
	var refs []pgAdvancedCopyCheckpointPrivateReference
	if p.References != nil {
		refs = make([]pgAdvancedCopyCheckpointPrivateReference, len(p.References))
	}
	for i, r := range p.References {
		refs[i] = pgAdvancedCopyCheckpointPrivateReference{r, r.Scope, r.Identity, r.Guard, r.NativeDefinition, r.Attributes, r.Facts, r.AdvancedEvidence}
	}
	var conditions []pgAdvancedCopyCheckpointPrivateCondition
	if p.Conditions != nil {
		conditions = make([]pgAdvancedCopyCheckpointPrivateCondition, len(p.Conditions))
	}
	for i, c := range p.Conditions {
		conditions[i].Condition = c
		if c.Operation.Column != nil {
			conditions[i].OperationColumn = &pgAdvancedCopyCheckpointPrivateColumn{c.Operation.Column.PrimaryKeyName, c.Operation.Column.Resolved}
		}
		if c.Columns != nil {
			conditions[i].Columns = make([]pgAdvancedCopyCheckpointPrivateColumn, len(c.Columns))
		}
		for j, column := range c.Columns {
			conditions[i].Columns[j] = pgAdvancedCopyCheckpointPrivateColumn{column.PrimaryKeyName, column.Resolved}
		}
	}
	// AdvancedProof alone may be rebound by the separately verified acknowledged
	// checkpoint hook. Public JSON omits the other private execution evidence.
	content := struct {
		Public         tableedit.Plan
		Created        time.Time
		Reconstruction *tableedit.Reconstruction
		Conditions     []pgAdvancedCopyCheckpointPrivateCondition
		Types          []tableedit.TypeGuard
		IndexGuards    []tableedit.IndexGuard
		RenamedColumns map[string]string
		References     []pgAdvancedCopyCheckpointPrivateReference
	}{p, p.Created, p.Reconstruction, conditions, p.Types, p.IndexGuards, p.RenamedColumns, refs}
	raw, err := json.Marshal(content)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func pgAdvancedCopyCheckpointPlanMatches(cp *pgAdvancedCopyCheckpoint, p tableedit.Plan) bool {
	if cp == nil || !tableedit.ID(p.ID) || !tableedit.IsDigest(p.Digest) || !tableedit.IsDigest(cp.ContentDigest) || cp.PlanID != p.ID || cp.PlanDigest != p.Digest {
		return false
	}
	content := pgAdvancedCopyCheckpointPrivateContent(p)
	return tableedit.IsDigest(content) && cp.ContentDigest == content
}
