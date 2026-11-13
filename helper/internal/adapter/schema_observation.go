package adapter

import (
	"context"
	"dbeer/helper/internal/protocol"
)

// SchemaObserver accepts fixed metadata observation requests on an idle,
// readonly monitor connection. Preview actions only return reviewed SQL text.
type SchemaObserver interface {
	ObserveSchema(context.Context, protocol.Command) protocol.Response
}
