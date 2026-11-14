package postgres

import (
	"context"
	"errors"

	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
)

func pgAdvancedCopyCheckpointContent(p tableedit.Plan) string {
	return pgAdvancedCopyCheckpointPrivateContent(p)
}

func (s *Session) pgAdvancedCopyConsumeCheckpoint(p tableedit.Plan) (*pgAdvancedCopyCheckpoint, error) {
	cp := s.advancedCopyCheckpoint
	s.advancedCopyCheckpoint = nil
	if cp == nil || s.conn == nil || s.conn.IsClosed() || s.conn.PgConn().PID() != cp.BackendPID || !pgAdvancedCopyCheckpointPlanMatches(cp, p) {
		return nil, tableedit.ErrStale
	}
	return cp, nil
}

func pgAdvancedCopyCheckpointBaseline(b tableedit.Baseline) tableedit.Baseline {
	evidence := tableedit.CloneAdvancedEvidence(b.AdvancedEvidence)
	return tableedit.Baseline{Target: b.Target, Engine: b.Engine, Scope: b.Scope, Identity: b.Identity, Guard: b.Guard, Fingerprint: b.Fingerprint, AdvancedEvidence: evidence, Facts: evidence.Facts[b.Identity]}
}

func pgAdvancedCopyAcknowledgedCheckpoint(p tableedit.Plan, backend uint32, before, after, combinedBefore, combinedAfter tableedit.Baseline, layout *pgAdvancedCopyLayout, repairs []pgAdvancedCopyRepair) *pgAdvancedCopyCheckpoint {
	content := pgAdvancedCopyCheckpointContent(p)
	if !tableedit.ID(p.ID) || !tableedit.IsDigest(p.Digest) || !tableedit.IsDigest(content) || backend == 0 || layout == nil || before.AdvancedEvidence == nil || after.AdvancedEvidence == nil || combinedBefore.AdvancedEvidence == nil || combinedAfter.AdvancedEvidence == nil {
		return nil
	}
	cp := &pgAdvancedCopyCheckpoint{PlanID: p.ID, PlanDigest: p.Digest, ContentDigest: content, BackendPID: backend, Before: pgAdvancedCopyCheckpointBaseline(before), After: pgAdvancedCopyCheckpointBaseline(after), CombinedBefore: pgAdvancedCopyCheckpointBaseline(combinedBefore), CombinedAfter: pgAdvancedCopyCheckpointBaseline(combinedAfter), Orders: map[string][]string{}, Replaced: map[string]bool{}, Repairs: append([]pgAdvancedCopyRepair(nil), repairs...)}
	cp.CombinedBefore.Scope, cp.CombinedAfter.Scope = cp.Before.Scope, cp.After.Scope
	for id, order := range layout.Orders {
		cp.Orders[id] = append([]string(nil), order...)
	}
	for id, replaced := range layout.Replaced {
		cp.Replaced[id] = replaced
	}
	return cp
}

func pgAdvancedCopyCheckpointPreserved(cp *pgAdvancedCopyCheckpoint, observedFamily, observedCombined tableedit.Baseline) error {
	if cp == nil || !tableedit.ID(cp.PlanID) || !tableedit.IsDigest(cp.PlanDigest) || !tableedit.IsDigest(cp.ContentDigest) || cp.BackendPID == 0 || cp.After.Target != observedFamily.Target || cp.After.Scope != observedFamily.Scope || cp.After.Identity != observedFamily.Identity || cp.After.Guard != observedFamily.Guard || observedCombined.Target != observedFamily.Target {
		return tableedit.ErrStale
	}
	if err := pgAdvancedCopyRepairPropertiesPreserved(cp.Before, cp.After, cp.CombinedBefore, cp.CombinedAfter, cp.Orders, cp.Replaced); err != nil {
		return err
	}
	if err := pgAdvancedCopyRepairOwnersPreserved(cp.CombinedBefore.AdvancedEvidence, cp.CombinedAfter.AdvancedEvidence, cp.Before.AdvancedEvidence, cp.After.AdvancedEvidence); err != nil {
		return err
	}
	if tableedit.Fingerprint(cp.After.AdvancedEvidence) != tableedit.Fingerprint(observedFamily.AdvancedEvidence) || tableedit.Fingerprint(cp.CombinedAfter.AdvancedEvidence) != tableedit.Fingerprint(observedCombined.AdvancedEvidence) {
		return errors.New("The acknowledged copy checkpoint's complete native metadata changed before the next migration unit.")
	}
	return nil
}

// Reobserve the public checkpoint first, then capture its complete private
// native catalog in a local fixed context. No rows or expressions are evaluated.
func (s *Session) pgAdvancedCopyObserveCheckpoint(ctx context.Context, observed tableedit.Baseline, cp *pgAdvancedCopyCheckpoint) (tableedit.Baseline, tableedit.Baseline, error) {
	if cp == nil || s.conn == nil || s.conn.IsClosed() || s.conn.PgConn().PID() != cp.BackendPID || s.TransactionStatus() != "idle" {
		return tableedit.Baseline{}, tableedit.Baseline{}, tableedit.ErrStale
	}
	tx, err := s.conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return tableedit.Baseline{}, tableedit.Baseline{}, err
	}
	defer structureRollback(tx)
	current, err := readStructure(ctx, tx, observed.Target)
	if err != nil || current.Fingerprint != observed.Fingerprint || current.Scope != observed.Scope || current.Identity != observed.Identity || current.Guard != observed.Guard {
		return tableedit.Baseline{}, tableedit.Baseline{}, tableedit.ErrStale
	}
	if _, err = tx.Exec(ctx, "SET LOCAL search_path=pg_catalog"); err != nil {
		return tableedit.Baseline{}, tableedit.Baseline{}, err
	}
	family, err := pgAdvancedCopyRepairLoad(ctx, tx, observed.Target)
	if err != nil {
		return tableedit.Baseline{}, tableedit.Baseline{}, err
	}
	combined, err := pgAdvancedCopyRepairCapture(ctx, tx, family, cp.Repairs)
	if err != nil {
		return tableedit.Baseline{}, tableedit.Baseline{}, err
	}
	family.Scope, combined.Scope = current.Scope, current.Scope
	if err = tx.Commit(ctx); err != nil {
		closeConnection(s.conn)
		return tableedit.Baseline{}, tableedit.Baseline{}, err
	}
	return family, combined, nil
}
