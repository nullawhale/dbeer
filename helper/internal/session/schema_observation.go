package session

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func runSchemaObservation(ctx context.Context, physical adapter.Session, command protocol.Command, engine string) protocol.Response {
	failure := func(category, message string) protocol.Response {
		r := protocol.ErrorResponse(command, category, message)
		r.Connected, r.TransactionStatus = true, physical.TransactionStatus()
		return r
	}
	observer, ok := physical.(adapter.SchemaObserver)
	if !ok || engine != "postgresql" && engine != "mysql" {
		return failure("capability", "Schema observation is unavailable for this adapter.")
	}
	if command.SchemaObservation == nil || !command.SchemaObservation.Valid() {
		return failure("protocol", "Invalid schema observation request.")
	}
	if physical.TransactionStatus() != "idle" {
		return failure("policy", "Schema observation requires an idle dedicated readonly connection.")
	}
	if ctx.Err() != nil {
		return failure("cancelled", "Schema observation was stopped before collection.")
	}
	r := observer.ObserveSchema(ctx, command)
	if r.Type == "error" {
		return r
	}
	if r.Type != "monitor.schema.result" || r.SchemaObservation == nil || !r.SchemaObservation.Valid() || r.SchemaObservation.Engine != engine || r.SchemaObservation.Action != command.SchemaObservation.Action || !r.Connected || r.TransactionStatus != "idle" {
		return failure("protocol", "The schema observer returned an invalid observation.")
	}
	return r
}
