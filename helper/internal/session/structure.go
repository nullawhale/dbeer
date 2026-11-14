package session

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"strings"
)

func isStructure(t string) bool { return strings.HasPrefix(t, "structure.") }
func (owner *owner) runStructure(ctx context.Context, physical adapter.Session, c protocol.Command) protocol.Response {
	if strings.HasPrefix(c.Type, "structure.physical.") {
		return owner.runPhysical(ctx, physical, c)
	}
	if owner.physicalDDL.NeedsReconciliation() && c.Type != "structure.status" {
		return rejectedCommand(c, "policy", "Reconcile retained physical execution before another structure operation.")
	}
	if strings.HasPrefix(c.Type, "structure.migration.") {
		return owner.runMigration(ctx, physical, c)
	}
	reject := func(category, message string) protocol.Response {
		r := rejectedCommand(c, category, message)
		r.Connected = physical.TransactionStatus() != "unknown"
		r.TransactionStatus = physical.TransactionStatus()
		return r
	}
	a, ok := physical.(tableedit.Adapter)
	if !ok {
		return reject("unsupported", "This database does not support structure editing.")
	}
	r := protocol.Response{Type: c.Type + ".result", Connected: true, TransactionStatus: physical.TransactionStatus()}
	if c.Structure == nil || !c.Structure.Valid(c.Type) {
		return reject("protocol", "Invalid structure request.")
	}
	if !owner.structureOnly {
		return reject("policy", "Open a separate idle session for structure editing.")
	}
	// Status reads retained execution evidence without touching the database.
	// It remains available if the original DDL connection has an unknown state.
	if c.Type != "structure.status" && physical.TransactionStatus() != "idle" {
		return reject("policy", "Open a separate idle session for structure editing.")
	}
	var result tableedit.Reply
	var err error
	switch c.Type {
	case "structure.load":
		if owner.migration.NeedsReconciliation() {
			return reject("policy", "Reconcile retained migration execution before loading another structure draft.")
		}
		owner.migration.Close()
		owner.invalidateGrant()
		result, err = owner.structure.Load(ctx, a, *c.Structure.Target)
	case "structure.preview":
		if owner.migration.NeedsReconciliation() {
			return reject("policy", "Reconcile retained migration execution before preparing another structure draft.")
		}
		owner.migration.Close()
		owner.invalidateGrant()
		result, err = owner.structure.PreviewContext(ctx, a, c.Structure.BaselineID, *c.Structure.Draft)
	case "structure.validate":
		result, err = owner.structure.Validate(ctx, a, *c.Structure.Validation)
	case "structure.apply":
		result, err = owner.structure.Apply(ctx, a, *c.Structure.Apply)
	case "structure.status":
		result = owner.structure.Status()
	case "structure.close":
		owner.invalidateGrant()
		owner.structure.Close()
	default:
		return reject("protocol", "Unknown structure operation.")
	}
	if err != nil {
		r = rejectedCommand(c, "validation", err.Error())
		r.Connected = physical.TransactionStatus() != "unknown"
	}
	r.TransactionStatus = physical.TransactionStatus()
	r.Connected = r.TransactionStatus != "unknown"
	if err == nil {
		r.Structure = &result
	}
	encoded, encodeErr := json.Marshal(r)
	if encodeErr != nil || len(encoded) > 8<<20 {
		if r.Structure != nil && r.Structure.Outcome != nil {
			r.Structure.Outcome.Observed = nil
			r.Structure.Outcome.RefreshError = "Observation exceeded the response size limit. Execution acknowledgement is retained; reconcile explicitly."
		} else {
			return reject("limit", "Structure metadata exceeds the response size limit.")
		}
	}
	return r
}
