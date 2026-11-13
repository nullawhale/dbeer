package adapter

import (
	"context"
	"dbeer/helper/internal/protocol"
)

// CatalogMetadataReader streams metadata before display truncation. The
// returned consistency describes one completed collection observation.
type CatalogMetadataReader interface {
	ReadCatalogMetadata(context.Context, protocol.Command, ResultSink) (protocol.Response, string)
}
