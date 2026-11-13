package session

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/catalogmetadata"
	"dbeer/helper/internal/protocol"
	"errors"
)

func isCatalogMetadata(kind string) bool {
	return kind == "catalog.page" || kind == "catalog.batch" || kind == "catalog.close"
}

func (owner *owner) runCatalogMetadata(ctx context.Context, physical adapter.Session, command protocol.Command) protocol.Response {
	reader, ok := physical.(adapter.CatalogMetadataReader)
	if !ok {
		r := protocol.ErrorResponse(command, "capability", "Paged metadata is unavailable for this engine.")
		r.Connected, r.TransactionStatus = true, physical.TransactionStatus()
		return r
	}
	metadata, err := owner.metadata.Execute(ctx, reader, command)
	if err != nil {
		var readError *catalogmetadata.ReadError
		if errors.As(err, &readError) {
			return readError.Response
		}
		category, message := "catalog", err.Error()
		if errors.Is(err, context.Canceled) {
			category, message = "cancelled", "Metadata loading was cancelled."
		}
		if errors.Is(err, context.DeadlineExceeded) {
			category, message = "timeout", "Metadata loading timed out."
		}
		r := protocol.ErrorResponse(command, category, message)
		r.Connected, r.TransactionStatus = physical.TransactionStatus() != "unknown", physical.TransactionStatus()
		return r
	}
	return protocol.Response{Type: command.Type + ".result", CatalogMetadata: metadata, Connected: true, TransactionStatus: physical.TransactionStatus()}
}
