package session

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
)

func (o *owner) physicalStatus(c protocol.Command) protocol.Response {
	if c.Type != "structure.physical.status" || c.SessionID != o.id || !protocol.ValidID(c.RequestID) || !protocol.ValidID(c.QueryID) || !o.structureOnly || c.Structure == nil || !c.Structure.Valid(c.Type) {
		return rejectedCommand(c, "policy", "Use the original dedicated structure session.")
	}
	reply := o.physicalDDL.Status()
	return protocol.Response{Type: c.Type + ".result", RequestID: c.RequestID, SessionID: o.id, QueryID: c.QueryID, Structure: &tableedit.Reply{Physical: &reply}}
}
func (o *owner) runPhysical(ctx context.Context, a adapter.Session, c protocol.Command) protocol.Response {
	reject := func(message string) protocol.Response {
		r := rejectedCommand(c, "validation", message)
		r.TransactionStatus = a.TransactionStatus()
		r.Connected = r.TransactionStatus != "unknown"
		return r
	}
	if !o.structureOnly || c.Structure == nil || !c.Structure.Valid(c.Type) {
		return reject("Use the original dedicated structure session and a valid physical request.")
	}
	physical, ok := a.(tableedit.PhysicalAdapter)
	if !ok {
		return reject("This physical session does not support guarded physical operations.")
	}
	if c.Type != "structure.physical.status" && c.Type != "structure.physical.close" && a.TransactionStatus() != "idle" {
		return reject("Physical operations require the original idle session outside a user transaction. Retained status remains available; do not reconnect or replay an uncertain operation.")
	}
	var reply tableedit.PhysicalReply
	var e error
	switch c.Type {
	case "structure.physical.inspect":
		inspector, ok := a.(tableedit.PhysicalInspector)
		if !ok {
			return reject("Physical catalog inspection is unavailable.")
		}
		var inspection tableedit.PhysicalInspection
		inspection, e = inspector.PhysicalInspect(ctx, *c.Structure.Physical.Target)
		reply.Inspection = &inspection
	case "structure.physical.preview":
		if o.migration.NeedsReconciliation() {
			return reject("Reconcile retained migration execution first.")
		}
		o.invalidateGrant()
		o.structure.Close()
		o.migration.Close()
		reply, e = o.physicalDDL.Preview(ctx, physical, *c.Structure.Physical.Draft)
	case "structure.physical.apply":
		reply, e = o.physicalDDL.Apply(ctx, physical, *c.Structure.Physical.Apply)
	case "structure.physical.status":
		reply = o.physicalDDL.Status()
	case "structure.physical.reconcile":
		o.invalidateGrant()
		reply, e = o.physicalDDL.Reconcile(ctx, physical)
	case "structure.physical.close":
		o.invalidateGrant()
		if !o.physicalDDL.Close() {
			return reject("Physical execution evidence requires explicit reconciliation before closing.")
		}
		reply = o.physicalDDL.Status()
	default:
		return reject("Unknown physical request.")
	}
	if e != nil {
		return reject(e.Error())
	}
	r := protocol.Response{Type: c.Type + ".result", Connected: a.TransactionStatus() != "unknown", TransactionStatus: a.TransactionStatus(), Structure: &tableedit.Reply{Physical: &reply}}
	raw, err := json.Marshal(r)
	if err != nil || len(raw) > 8<<20 {
		return reject("Physical metadata exceeds the response limit. Retained execution status remains available.")
	}
	return r
}
