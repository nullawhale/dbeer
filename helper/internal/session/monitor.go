package session

import (
	"context"
	"errors"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func runMonitor(ctx context.Context, physical adapter.Session, command protocol.Command, engine string) protocol.Response {
	failure := func(category, message string) protocol.Response {
		response := protocol.ErrorResponse(command, category, message)
		response.Connected, response.TransactionStatus = true, physical.TransactionStatus()
		return response
	}
	if ctx.Err() != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return failure("timeout", "Session monitoring timed out before it started.")
		}
		return failure("cancelled", "Session monitoring was cancelled before it started.")
	}
	monitor, ok := physical.(adapter.SessionMonitor)
	if !ok || engine != "postgresql" && engine != "mysql" {
		return failure("capability", "Session monitoring is unavailable for this adapter.")
	}
	if physical.TransactionStatus() != "idle" {
		return failure("policy", "Session monitoring requires an idle dedicated connection.")
	}
	response := monitor.MonitorSnapshot(ctx, command)
	if response.Type == "error" {
		return response
	}
	if response.Type != "monitor.result" || response.Monitor == nil || response.Monitor.Engine != engine || !response.Monitor.Valid() || !response.Connected || response.TransactionStatus != "idle" {
		return failure("protocol", "The session monitor returned an invalid or oversized observation.")
	}
	return response
}
