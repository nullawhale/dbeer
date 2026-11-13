package session

import (
	"context"
	"encoding/json"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
)

func (owner *owner) runMigration(ctx context.Context, physical adapter.Session, c protocol.Command) protocol.Response {
	reject := func(category, message string) protocol.Response {
		r := rejectedCommand(c, category, message)
		r.TransactionStatus = physical.TransactionStatus()
		r.Connected = r.TransactionStatus != "unknown"
		return r
	}
	if !owner.structureOnly || c.Structure == nil || !c.Structure.Valid(c.Type) {
		return reject("policy", "Use the original dedicated structure session and a valid migration request.")
	}
	if c.Type != "structure.migration.status" && c.Type != "structure.migration.close" && physical.TransactionStatus() != "idle" {
		return reject("policy", "The original migration session is not idle. Retained status remains available; do not reconnect or replay uncertain writes.")
	}
	a, ok := physical.(tableedit.MigrationAdapter)
	if !ok {
		return reject("capability", "This adapter does not support guarded migrations.")
	}
	request := c.Structure.Migration
	var reply tableedit.MigrationReply
	var err error
	switch c.Type {
	case "structure.migration.preview":
		owner.invalidateGrant()
		owner.structure.Close()
		reply, err = owner.migration.Preview(ctx, a, *request.Draft)
	case "structure.migration.apply":
		reply, err = owner.migration.Apply(ctx, a, *request.Apply)
	case "structure.migration.export":
		reply, err = owner.migration.Export(*request.Apply)
	case "structure.migration.reconcile":
		owner.invalidateGrant()
		reply, err = owner.migration.Reconcile(ctx, a)
	case "structure.migration.status":
		reply = owner.migration.Status()
	case "structure.migration.close":
		owner.invalidateGrant()
		owner.migration.Close()
		reply = owner.migration.Status()
	default:
		return reject("protocol", "Unknown migration request.")
	}
	if err != nil {
		return reject("validation", err.Error())
	}
	r := protocol.Response{Type: c.Type + ".result", Connected: physical.TransactionStatus() != "unknown", TransactionStatus: physical.TransactionStatus(), Structure: &tableedit.Reply{Migration: &reply}}
	raw, encodeErr := json.Marshal(r)
	if encodeErr != nil || len(raw) > 8<<20 {
		return reject("limit", "Migration metadata exceeds the response limit. Retained status remains authoritative; reconcile explicitly.")
	}
	return r
}
