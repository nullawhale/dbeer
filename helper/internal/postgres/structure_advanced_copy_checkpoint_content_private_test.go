package postgres

import (
	"encoding/json"
	"errors"
	"math"
	"reflect"
	"testing"
	"time"

	"dbeer/helper/internal/tableedit"
)

func pgCheckpointBindingFixture() tableedit.Plan {
	target := tableedit.Target{Schema: "review_schema", Table: "parent"}
	reference := tableedit.Baseline{
		ID: "reference-preview", Engine: "postgresql", Target: target,
		Fingerprint: tableedit.Fingerprint("unchanged public fingerprint"),
		Scope:       "session-scope", Identity: "100", Guard: "catalog-guard", NativeDefinition: "native definition with exact whitespace\n",
		Attributes: map[string]map[string]any{"id": {"attstorage": "p", "attnum": float64(1), "attoptions": []any{"exact=1", "second=2"}}},
		Facts:      &tableedit.Facts{Proof: true, ServerVersion: 170000, TypeStorage: map[string]string{"text": "x", "integer": "p"}},
		AdvancedEvidence: &tableedit.AdvancedEvidence{
			Facts:   map[string]*tableedit.Facts{"100": {Proof: true, ServerVersion: 170000}},
			Targets: []tableedit.Target{target, {Schema: "review_schema", Table: "child"}},
			Rows:    map[string][]map[string]any{"100/class": {{"oid": "100", "relname": "parent", "native": "{VAR :varattno 1 :location 19}"}, {"oid": "101", "relname": "child"}}},
		},
		Columns: []tableedit.ObservedColumn{{Name: "id", NativeType: "integer"}},
	}
	column := tableedit.Column{Name: "id", Type: tableedit.DataType{Kind: "integer"}, Default: tableedit.Default{Kind: "none"}, PrimaryKeyName: "retained_key", Resolved: &tableedit.TypeGuard{Identity: "23", Storage: "p", RawExpressions: map[string]string{"default": "exact native expression", "domain": "exact check"}}}
	operationColumn := column
	operationResolved := *column.Resolved
	operationResolved.RawExpressions = map[string]string{"default": "exact native expression", "domain": "exact check"}
	operationColumn.Resolved = &operationResolved
	otherColumn := column
	otherColumn.Name = "note"
	otherColumn.Resolved = &tableedit.TypeGuard{Identity: "25", Storage: "x"}
	return tableedit.Plan{
		ID: "review-plan", Digest: tableedit.Fingerprint("reviewed digest"), BaselineID: "review-baseline", Target: target,
		Created: time.Date(2026, 11, 14, 12, 34, 56, 123456789, time.UTC), SQL: []string{"reviewed statement one", "reviewed statement two"},
		Risks: []string{"exclusive locks", "disk space"}, Destructive: true,
		Reconstruction: &tableedit.Reconstruction{Method: "copy", TemporaryTable: "review_copy", ColumnOrder: []string{"id", "note"}, ExpectedDefinition: "exact definition\n", RowID: "id", AdvancedDataTypes: []uint32{23, 25}, AdvancedDataProof: "data-proof"},
		Conditions:     []tableedit.Condition{{Operation: tableedit.Operation{Kind: "addColumn", Column: &operationColumn}, Columns: []tableedit.Column{column, otherColumn}, ColumnOrder: []string{"id", "note"}, AdvancedDataTypes: []uint32{23, 25}, AdvancedDataProof: "condition-proof"}, {Operation: tableedit.Operation{Kind: "reorder"}, ColumnOrder: []string{"note", "id"}}},
		Types:          []tableedit.TypeGuard{{Identity: "23", Storage: "p", RawExpressions: map[string]string{"a": "exact A", "z": "exact Z"}}},
		IndexGuards:    []tableedit.IndexGuard{{Kind: "opclass", Identity: "1978", Definition: "exact native index definition"}}, RenamedColumns: map[string]string{"old": "new", "older": "newer"},
		References: []tableedit.Baseline{reference, {ID: "second-reference", Fingerprint: reference.Fingerprint, Target: tableedit.Target{Schema: "review_schema", Table: "external"}, Scope: "session-scope", Identity: "200", Guard: "external-guard"}}, AdvancedProof: tableedit.CloneAdvancedEvidence(reference.AdvancedEvidence),
		ResultTarget: &tableedit.Target{Schema: "review_schema", Table: "renamed"},
	}
}

func pgCheckpointJSONClone[T any](t *testing.T, value T) T {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal("fixture clone serialization failed")
	}
	var out T
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal("fixture clone decoding failed")
	}
	return out
}

func pgCheckpointClonePlan(t *testing.T, p tableedit.Plan) tableedit.Plan {
	t.Helper()
	out := pgCheckpointJSONClone(t, p)
	out.Created = p.Created
	out.Reconstruction = pgCheckpointJSONClone(t, p.Reconstruction)
	out.AdvancedProof = pgCheckpointJSONClone(t, p.AdvancedProof)
	out.Types = pgCheckpointJSONClone(t, p.Types)
	out.IndexGuards = pgCheckpointJSONClone(t, p.IndexGuards)
	out.RenamedColumns = pgCheckpointJSONClone(t, p.RenamedColumns)
	out.Conditions = pgCheckpointJSONClone(t, p.Conditions)
	cloneColumn := func(c tableedit.Column) tableedit.Column {
		v := pgCheckpointJSONClone(t, c)
		v.PrimaryKeyName, v.Resolved = c.PrimaryKeyName, pgCheckpointJSONClone(t, c.Resolved)
		return v
	}
	for i, c := range p.Conditions {
		if c.Operation.Column != nil {
			v := cloneColumn(*c.Operation.Column)
			out.Conditions[i].Operation.Column = &v
		}
		for j, column := range c.Columns {
			out.Conditions[i].Columns[j] = cloneColumn(column)
		}
	}
	out.References = pgCheckpointJSONClone(t, p.References)
	for i, r := range p.References {
		out.References[i].Scope, out.References[i].Identity, out.References[i].Guard, out.References[i].NativeDefinition = r.Scope, r.Identity, r.Guard, r.NativeDefinition
		out.References[i].Attributes = pgCheckpointJSONClone(t, r.Attributes)
		out.References[i].Facts = pgCheckpointJSONClone(t, r.Facts)
		out.References[i].AdvancedEvidence = pgCheckpointJSONClone(t, r.AdvancedEvidence)
	}
	return out
}

func TestPGAdvancedCopyCheckpointPrivateBindingMutations(t *testing.T) {
	mutations := map[string]func(*tableedit.Plan){
		"reference scope":                 func(p *tableedit.Plan) { p.References[0].Scope += " changed" },
		"reference identity":              func(p *tableedit.Plan) { p.References[0].Identity = "200" },
		"reference guard":                 func(p *tableedit.Plan) { p.References[0].Guard += " changed" },
		"reference attributes":            func(p *tableedit.Plan) { p.References[0].Attributes["id"]["attstorage"] = "x" },
		"reference native definition":     func(p *tableedit.Plan) { p.References[0].NativeDefinition += " " },
		"created":                         func(p *tableedit.Plan) { p.Created = p.Created.Add(time.Nanosecond) },
		"condition column key":            func(p *tableedit.Plan) { p.Conditions[0].Columns[0].PrimaryKeyName += " changed" },
		"condition column resolved":       func(p *tableedit.Plan) { p.Conditions[0].Columns[0].Resolved.Storage = "x" },
		"operation column key":            func(p *tableedit.Plan) { p.Conditions[0].Operation.Column.PrimaryKeyName += " changed" },
		"operation column resolved":       func(p *tableedit.Plan) { p.Conditions[0].Operation.Column.Resolved.Identity = "25" },
		"plan target":                     func(p *tableedit.Plan) { p.Target.Table = "other" },
		"result target":                   func(p *tableedit.Plan) { p.ResultTarget.Table = "other" },
		"baseline ID":                     func(p *tableedit.Plan) { p.BaselineID += "-changed" },
		"SQL":                             func(p *tableedit.Plan) { p.SQL[0] += " changed" },
		"SQL order":                       func(p *tableedit.Plan) { p.SQL[0], p.SQL[1] = p.SQL[1], p.SQL[0] },
		"risks":                           func(p *tableedit.Plan) { p.Risks[0] += " changed" },
		"destructive":                     func(p *tableedit.Plan) { p.Destructive = false },
		"reconstruction method":           func(p *tableedit.Plan) { p.Reconstruction.Method = "update" },
		"reconstruction temporary target": func(p *tableedit.Plan) { p.Reconstruction.TemporaryTable += "_other" },
		"reconstruction order": func(p *tableedit.Plan) {
			p.Reconstruction.ColumnOrder[0], p.Reconstruction.ColumnOrder[1] = p.Reconstruction.ColumnOrder[1], p.Reconstruction.ColumnOrder[0]
		},
		"reconstruction native definition": func(p *tableedit.Plan) { p.Reconstruction.ExpectedDefinition += " " },
		"reconstruction row ID":            func(p *tableedit.Plan) { p.Reconstruction.RowID = "note" },
		"reconstruction data proof":        func(p *tableedit.Plan) { p.Reconstruction.AdvancedDataProof += " changed" },
		"reconstruction data types":        func(p *tableedit.Plan) { p.Reconstruction.AdvancedDataTypes[0] = 25 },
		"condition operation":              func(p *tableedit.Plan) { p.Conditions[0].Operation.Kind = "create" },
		"condition order":                  func(p *tableedit.Plan) { p.Conditions[0], p.Conditions[1] = p.Conditions[1], p.Conditions[0] },
		"condition column order": func(p *tableedit.Plan) {
			p.Conditions[0].Columns[0], p.Conditions[0].Columns[1] = p.Conditions[0].Columns[1], p.Conditions[0].Columns[0]
		},
		"condition data proof":     func(p *tableedit.Plan) { p.Conditions[0].AdvancedDataProof += " changed" },
		"condition data types":     func(p *tableedit.Plan) { p.Conditions[0].AdvancedDataTypes[0] = 25 },
		"type guard":               func(p *tableedit.Plan) { p.Types[0].Identity = "25" },
		"index guard":              func(p *tableedit.Plan) { p.IndexGuards[0].Definition += " " },
		"renamed columns":          func(p *tableedit.Plan) { p.RenamedColumns["old"] = "other" },
		"reference public target":  func(p *tableedit.Plan) { p.References[0].Target.Table = "other" },
		"reference public columns": func(p *tableedit.Plan) { p.References[0].Columns[0].NativeType = "bigint" },
		"reference facts":          func(p *tableedit.Plan) { p.References[0].Facts.ServerVersion++ },
		"reference evidence facts": func(p *tableedit.Plan) { p.References[0].AdvancedEvidence.Facts["100"].ServerVersion++ },
		"reference exact native evidence": func(p *tableedit.Plan) {
			p.References[0].AdvancedEvidence.Rows["100/class"][0]["native"] = "{VAR :varattno 1 :location 20}"
		},
		"reference row order": func(p *tableedit.Plan) {
			rows := p.References[0].AdvancedEvidence.Rows["100/class"]
			rows[0], rows[1] = rows[1], rows[0]
		},
		"reference order": func(p *tableedit.Plan) { p.References[0], p.References[1] = p.References[1], p.References[0] },
		"reference target order": func(p *tableedit.Plan) {
			targets := p.References[0].AdvancedEvidence.Targets
			targets[0], targets[1] = targets[1], targets[0]
		},
		"nil reconstruction":     func(p *tableedit.Plan) { p.Reconstruction = nil },
		"nil references":         func(p *tableedit.Plan) { p.References = nil },
		"nil reference facts":    func(p *tableedit.Plan) { p.References[0].Facts = nil },
		"nil reference evidence": func(p *tableedit.Plan) { p.References[0].AdvancedEvidence = nil },
		"nil column resolved":    func(p *tableedit.Plan) { p.Conditions[0].Columns[0].Resolved = nil },
		"nil operation column":   func(p *tableedit.Plan) { p.Conditions[0].Operation.Column = nil },
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			p := pgCheckpointBindingFixture()
			cp := &pgAdvancedCopyCheckpoint{PlanID: p.ID, PlanDigest: p.Digest, ContentDigest: pgAdvancedCopyCheckpointContent(p)}
			publicFingerprint := p.References[0].Fingerprint
			mutate(&p)
			if p.ID != cp.PlanID || p.Digest != cp.PlanDigest || len(p.References) > 0 && p.References[0].Fingerprint != publicFingerprint {
				t.Fatal("mutation changed immutable public authority controls")
			}
			if cp.ContentDigest == pgAdvancedCopyCheckpointContent(p) || pgAdvancedCopyCheckpointPlanMatches(cp, p) {
				t.Fatal("mutated execution evidence retained checkpoint authority")
			}
		})
	}
}

func TestPGAdvancedCopyCheckpointPrivateBindingStable(t *testing.T) {
	p := pgCheckpointBindingFixture()
	clone := pgCheckpointClonePlan(t, p)
	if !reflect.DeepEqual(p, clone) {
		t.Fatal("fixture deep clone changed content")
	}
	digest := pgAdvancedCopyCheckpointContent(p)
	if !tableedit.IsDigest(digest) || digest != pgAdvancedCopyCheckpointContent(clone) {
		t.Fatal("equal deep clones did not seal equally")
	}
	clone.References[0].Attributes["id"] = map[string]any{"attoptions": []any{"exact=1", "second=2"}, "attnum": float64(1), "attstorage": "p"}
	clone.RenamedColumns = map[string]string{"older": "newer", "old": "new"}
	clone.Types[0].RawExpressions = map[string]string{"z": "exact Z", "a": "exact A"}
	for range 64 {
		if pgAdvancedCopyCheckpointContent(clone) != digest {
			t.Fatal("map insertion or iteration order changed sealing")
		}
	}
	if !reflect.DeepEqual(p, clone) {
		t.Fatal("sealing mutated source objects")
	}
	cp := &pgAdvancedCopyCheckpoint{PlanID: p.ID, PlanDigest: p.Digest, ContentDigest: digest}
	if !pgAdvancedCopyCheckpointPlanMatches(cp, clone) {
		t.Fatal("deep clone did not match the original checkpoint")
	}
	clone.AdvancedProof.Rows["100/class"][0]["native"] = "separately verified rebound proof"
	if !pgAdvancedCopyCheckpointPlanMatches(cp, clone) {
		t.Fatal("the separately authorized AdvancedProof rebind changed original intent binding")
	}
}

func TestPGAdvancedCopyCheckpointPrivateBindingMalformed(t *testing.T) {
	mutations := map[string]func(*tableedit.Plan){
		"unsupported attribute": func(p *tableedit.Plan) { p.References[0].Attributes["id"]["bad"] = make(chan int) },
		"nonfinite attribute":   func(p *tableedit.Plan) { p.References[0].Attributes["id"]["bad"] = math.NaN() },
		"cyclic evidence": func(p *tableedit.Plan) {
			row := p.References[0].AdvancedEvidence.Rows["100/class"][0]
			row["self"] = row
		},
		"invalid created": func(p *tableedit.Plan) { p.Created = time.Date(10000, 1, 1, 0, 0, 0, 0, time.UTC) },
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			p := pgCheckpointBindingFixture()
			mutate(&p)
			if pgAdvancedCopyCheckpointContent(p) != "" {
				t.Fatal("unserializable evidence minted a checkpoint digest")
			}
			cp := &pgAdvancedCopyCheckpoint{PlanID: p.ID, PlanDigest: p.Digest}
			if pgAdvancedCopyCheckpointPlanMatches(cp, p) {
				t.Fatal("empty or malformed digest retained checkpoint authority")
			}
			b := tableedit.Baseline{AdvancedEvidence: &tableedit.AdvancedEvidence{}}
			if pgAdvancedCopyAcknowledgedCheckpoint(p, 42, b, b, b, b, &pgAdvancedCopyLayout{}, nil) != nil {
				t.Fatal("unserializable evidence created an acknowledged checkpoint")
			}
		})
	}
}

func TestPGAdvancedCopyCheckpointPrivateBindingIdentityAndClear(t *testing.T) {
	p := pgCheckpointBindingFixture()
	cp := &pgAdvancedCopyCheckpoint{PlanID: p.ID, PlanDigest: p.Digest, ContentDigest: pgAdvancedCopyCheckpointContent(p), BackendPID: 42}
	if pgAdvancedCopyCheckpointPlanMatches(nil, p) {
		t.Fatal("nil checkpoint matched a plan")
	}
	for _, malformed := range []*pgAdvancedCopyCheckpoint{
		{},
		{PlanID: p.ID, PlanDigest: p.Digest},
		{PlanID: p.ID, PlanDigest: p.Digest, ContentDigest: "invalid"},
		{PlanID: p.ID, PlanDigest: "invalid", ContentDigest: cp.ContentDigest},
	} {
		if pgAdvancedCopyCheckpointPlanMatches(malformed, p) {
			t.Fatal("malformed checkpoint matched a plan")
		}
	}
	for _, changed := range []tableedit.Plan{{ID: p.ID, Digest: p.Digest}, {ID: "other", Digest: p.Digest}, {ID: p.ID, Digest: tableedit.Fingerprint("other")}} {
		if pgAdvancedCopyCheckpointPlanMatches(cp, changed) {
			t.Fatal("changed or incomplete plan retained checkpoint authority")
		}
	}
	// A missing connection must still consume the one-use artifact before
	// rejecting it; a live backend/acknowledged-COMMIT proof is outside this test.
	s := &Session{advancedCopyCheckpoint: cp}
	if got, err := s.pgAdvancedCopyConsumeCheckpoint(p); got != nil || !errors.Is(err, tableedit.ErrStale) || s.advancedCopyCheckpoint != nil {
		t.Fatal("failed consume retained a reusable artifact")
	}
	if got, err := s.pgAdvancedCopyConsumeCheckpoint(p); got != nil || !errors.Is(err, tableedit.ErrStale) {
		t.Fatal("cleared artifact became reusable")
	}
}
