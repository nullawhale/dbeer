package adapter

import (
	"context"
	"dbeer/helper/internal/schemacompare"
)

// SchemaReader belongs to the dedicated comparison worker, never an SQL tab.
type SchemaReader interface {
	ReadSchema(context.Context, schemacompare.CaptureSpec, schemacompare.Sink) error
}
