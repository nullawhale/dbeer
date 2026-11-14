package postgres

import (
	"context"
	"errors"
	"testing"
	"time"

	"dbeer/helper/internal/tableedit"
)

func TestAdvancedCopyAcknowledgedCheckpointLive(t *testing.T) {
	for _, mode := range []string{"ConsumeOnce", "WrongPlan", "OtherBackend", "FreshDrift", "UnknownCommit", "InvalidContent"} {
		t.Run(mode, func(t *testing.T) {
			f := newChangeFixture(t)
			ctx := context.Background()
			s := &Session{conn: f.conn}
			f.exec("CREATE TABLE " + f.table("secured") + "(id integer,payload text)")
			f.exec("ALTER TABLE " + f.table("secured") + " ENABLE ROW LEVEL SECURITY")
			f.exec("ALTER TABLE " + f.table("secured") + " FORCE ROW LEVEL SECURITY")
			f.exec("CREATE POLICY retained ON " + f.table("secured") + " USING(id>0)")
			f.exec("INSERT INTO " + f.table("secured") + " VALUES(1,''),(1,''),(2,'NULL'),(3,NULL)")
			target := tableedit.Target{Schema: f.schema, Table: "secured"}
			before, err := s.StructureLoad(ctx, target)
			if err != nil {
				t.Fatal("checkpoint source capture unavailable")
			}
			prepared, err := s.preparePGAdvancedCopy(ctx, before, []string{"payload", "id"})
			if err != nil {
				t.Fatal(err)
			}
			plan := tableedit.Plan{ID: tableedit.Token(), Digest: tableedit.Fingerprint(prepared.SQL), Target: target, SQL: prepared.SQL, Reconstruction: prepared.Reconstruction, Created: time.Now()}
			if mode == "InvalidContent" {
				plan.References = []tableedit.Baseline{{Attributes: map[string]map[string]any{"id": {"invalid": make(chan int)}}}}
			}
			attempted := false
			if mode == "UnknownCommit" {
				s.structureCommitOverride = func(commit func() error) error {
					attempted = true
					if err := commit(); err != nil {
						return err
					}
					return errors.New("synthetic lost acknowledgement")
				}
			}
			s.advancedCopyCheckpoint = &pgAdvancedCopyCheckpoint{}
			steps := s.applyPGAdvancedCopy(ctx, before, plan)
			for _, step := range steps {
				want := "applied"
				if mode == "UnknownCommit" {
					want = "unknown"
				}
				if step.State != want {
					t.Fatalf("checkpoint copy outcome state=%s message=%s", step.State, step.Message)
				}
			}
			var oid uint32
			var count int
			// The observer confirms the actual committed identity and duplicate rows,
			// including when only the COMMIT acknowledgement was lost.
			if f.observer.QueryRow(ctx, "SELECT pg_catalog.to_regclass($1)::pg_catalog.oid", pgPhysicalName(target)).Scan(&oid) != nil || pgPhysicalOID(oid) == before.Identity || f.observer.QueryRow(ctx, "SELECT count(*) FROM "+f.table("secured")).Scan(&count) != nil || count != 4 {
				t.Fatal("actual committed checkpoint identity or row multiplicity was not observed")
			}
			if mode == "UnknownCommit" {
				if !attempted || !f.conn.IsClosed() || s.advancedCopyCheckpoint != nil {
					t.Fatal("uncertain COMMIT produced a checkpoint or retained replay authority")
				}
				return
			}
			if mode == "InvalidContent" {
				if s.advancedCopyCheckpoint != nil || f.conn.IsClosed() {
					t.Fatal("a known acknowledged COMMIT became uncertain or exposed an invalid checkpoint")
				}
				return
			}
			if s.advancedCopyCheckpoint == nil {
				t.Fatal("acknowledged copy emitted no checkpoint")
			}
			if mode == "OtherBackend" {
				other := &Session{conn: f.observer, advancedCopyCheckpoint: s.advancedCopyCheckpoint}
				if _, err = other.pgAdvancedCopyConsumeCheckpoint(plan); err == nil || other.advancedCopyCheckpoint != nil {
					t.Fatal("checkpoint escaped its owning physical backend")
				}
				return
			}
			if mode == "WrongPlan" {
				plan.Created = plan.Created.Add(time.Second)
				if _, err = s.pgAdvancedCopyConsumeCheckpoint(plan); err == nil || s.advancedCopyCheckpoint != nil {
					t.Fatal("mutated private plan intent consumed an acknowledged checkpoint")
				}
				return
			}
			cp, err := s.pgAdvancedCopyConsumeCheckpoint(plan)
			if err != nil || cp == nil {
				t.Fatal("acknowledged checkpoint could not be consumed")
			}
			if _, err = s.pgAdvancedCopyConsumeCheckpoint(plan); err == nil {
				t.Fatal("checkpoint was consumed more than once")
			}
			if mode == "FreshDrift" {
				f.exec("ALTER POLICY retained ON " + f.table("secured") + " USING(id>1)")
			}
			fresh, err := s.StructureLoad(ctx, target)
			if err != nil {
				t.Fatal("checkpoint observation unavailable")
			}
			family, combined, err := s.pgAdvancedCopyObserveCheckpoint(ctx, fresh, cp)
			if err != nil {
				t.Fatal("fixed-context checkpoint capture unavailable")
			}
			err = pgAdvancedCopyCheckpointPreserved(cp, family, combined)
			if (mode == "FreshDrift") == (err == nil) {
				t.Fatal("fresh complete-catalog checkpoint comparison accepted drift or refused exact metadata")
			}
		})
	}
}
