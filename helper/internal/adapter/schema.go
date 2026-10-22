package adapter

import (
	"context"
	"dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tablecapture"
)

// SchemaReader belongs to the dedicated comparison worker, never an SQL tab.
type SchemaReader interface {
	ReadSchema(context.Context, schemacompare.CaptureSpec, schemacompare.Sink) error
}

// TableDataReader is optional and exclusively owned by a data comparison worker.
type TableDataReader = tablecapture.Reader
