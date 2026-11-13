package session

import (
	"context"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	"testing"
)

type migrationPolicyAdapter struct{ identityEffectPolicyAdapter }

func (a migrationPolicyAdapter) StructurePrepareMigration(ctx context.Context, b tableedit.Baseline, d tableedit.Draft, _ func(tableedit.Target) (tableedit.Baseline, error)) (tableedit.Prepared, error) {
	return a.StructurePrepare(ctx, b, d)
}
func migrationPolicyPlan(t *testing.T, o *owner) tableedit.Apply {
	t.Helper()
	o.structureOnly = true
	d := tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{{ID: "table", Target: tableedit.Target{Schema: "fixture", Table: "samples"}, After: []string{}, Draft: tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", Identity: &tableedit.Identity{Kind: "autoIncrement"}}}}}}, Repairs: []tableedit.MigrationRepair{}}
	reply, err := o.migration.Preview(context.Background(), migrationPolicyAdapter{}, d)
	if err != nil {
		t.Fatal(err)
	}
	return tableedit.Apply{PlanID: reply.Plan.ID, Digest: reply.Plan.Digest, ExecutionID: "migration"}
}
func TestMigrationExactWholePlanGrantIsSingleUseAndReadonlyDenied(t *testing.T) {
	for _, readonly := range []bool{false, true} {
		o := &owner{id: "original"}
		apply := migrationPolicyPlan(t, o)
		policy := protocol.ExecutionPolicy{Environment: "development", ReadOnly: readonly}
		command := protocol.Command{Type: "structure.migration.apply", Structure: &tableedit.Request{Migration: &tableedit.MigrationRequest{Apply: &apply}}}
		if o.authorize(command, "postgresql", policy) {
			t.Fatal("migration bypassed exact grant")
		}
		response := o.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: command.Type, Structure: &apply}}}, "postgresql", policy)
		if response.Assessment == nil {
			t.Fatal("migration assessment missing")
		}
		if readonly {
			if response.Assessment.Decision != "deny" {
				t.Fatal("readonly migration admitted")
			}
			continue
		}
		if response.Assessment.Decision != "confirm" || response.Assessment.Operations[0].Kind != "destructive" {
			t.Fatal("migration consequences bypassed confirmation")
		}
		command.Authorization = response.Assessment.Authorization
		if !o.authorize(command, "postgresql", policy) || o.authorize(command, "postgresql", policy) {
			t.Fatal("whole migration grant was not exact and single-use")
		}
	}
}
func TestMigrationGrantRejectsOtherExecutionDigestAndOwner(t *testing.T) {
	for _, field := range []string{"execution", "digest", "owner"} {
		o := &owner{id: "original"}
		apply := migrationPolicyPlan(t, o)
		policy := protocol.ExecutionPolicy{Environment: "production"}
		response := o.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "structure.migration.apply", Structure: &apply}}}, "mysql", policy)
		changed := apply
		switch field {
		case "execution":
			changed.ExecutionID = "other"
		case "digest":
			changed.Digest = tableedit.Fingerprint("changed")
		case "owner":
			o = &owner{id: "other", structureOnly: true}
		}
		if o.authorize(protocol.Command{Type: "structure.migration.apply", Authorization: response.Assessment.Authorization, Structure: &tableedit.Request{Migration: &tableedit.MigrationRequest{Apply: &changed}}}, "mysql", policy) {
			t.Fatal("migration grant crossed its exact execution or owner binding")
		}
	}
}

type migrationStatusPhysical struct{ structureStatusSession }

func (a *migrationStatusPhysical) StructurePrepare(context.Context, tableedit.Baseline, tableedit.Draft) (tableedit.Prepared, error) {
	return tableedit.Prepared{SQL: []string{"synthetic migration statement"}}, nil
}
func (a *migrationStatusPhysical) StructurePrepareMigration(ctx context.Context, b tableedit.Baseline, d tableedit.Draft, _ func(tableedit.Target) (tableedit.Baseline, error)) (tableedit.Prepared, error) {
	return a.StructurePrepare(ctx, b, d)
}
func (a *migrationStatusPhysical) StructureApplySteps(context.Context, tableedit.Baseline, tableedit.Plan) []tableedit.Execution {
	return []tableedit.Execution{{State: "unknown"}}
}
func TestMigrationStatusRetainsUnknownIntentWithoutDatabaseWork(t *testing.T) {
	o := &owner{id: "original", structureOnly: true}
	physical := &migrationStatusPhysical{structureStatusSession: structureStatusSession{status: "idle"}}
	d := tableedit.MigrationDraft{Version: 1, Objects: []tableedit.MigrationObject{{ID: "table", Target: tableedit.Target{Schema: "fixture", Table: "samples", Create: true}, After: []string{}, Draft: tableedit.Draft{Columns: []tableedit.Column{{Name: "id", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}}}}, Repairs: []tableedit.MigrationRepair{}}
	preview, err := o.migration.Preview(context.Background(), physical, d)
	if err != nil {
		t.Fatal(err)
	}
	_, err = o.migration.Apply(context.Background(), physical, tableedit.Apply{PlanID: preview.Plan.ID, Digest: preview.Plan.Digest, ExecutionID: "lost"})
	if err != nil {
		t.Fatal(err)
	}
	loads := physical.loads
	physical.status = "unknown"
	status := o.runStructure(context.Background(), physical, protocol.Command{Type: "structure.migration.status", Structure: &tableedit.Request{Migration: &tableedit.MigrationRequest{}}})
	if status.Type != "structure.migration.status.result" || status.Connected || status.Structure.Migration.Outcome.State != "outcomeUnknown" || status.Structure.Migration.Draft == nil || physical.loads != loads {
		t.Fatal("retained unknown status touched database or erased intent")
	}
	reconcile := o.runStructure(context.Background(), physical, protocol.Command{Type: "structure.migration.reconcile", Structure: &tableedit.Request{Migration: &tableedit.MigrationRequest{}}})
	if reconcile.Type != "error" || physical.loads != loads {
		t.Fatal("unknown physical owner reconnected or observed implicitly")
	}
}
