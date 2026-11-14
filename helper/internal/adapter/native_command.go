package adapter

import (
	"context"
	"dbeer/helper/internal/protocol"
)

// NativeCommandSession guarantees exact native result matrices for every reply.
// SQL adapters do not implement it. Unknown classifications require write
// permission and confirmation, never readonly. Classification is local and has
// no side effects; execution errors contain safe diagnostics.
type NativeCommandSession interface {
	ClassifyNativeCommand(protocol.NativeCommand) string
	ExecuteNativeCommand(context.Context, protocol.Command) protocol.Response
}
