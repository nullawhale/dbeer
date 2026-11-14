package session

import (
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	"slices"
)

// Versioned summary fields describe controls that the helper actually exposes.
// Project only a response copy: the Store retains its complete native facts,
// original fingerprint, preservation conditions and execution acknowledgement.
func structureWireReply(retained tableedit.Reply) tableedit.Reply {
	project := func(b *tableedit.Baseline) *tableedit.Baseline {
		if b != nil && b.Engine == "mariadb" && b.Advanced != nil && !slices.Contains(adapter.Capabilities(b.Engine), protocol.StructureAdvancedKindsCapability) {
			return nil
		}
		if b == nil || slices.Contains(adapter.Capabilities(b.Engine), protocol.StructureDestructiveCapability) {
			return b
		}
		projected := *b
		if b.Columns != nil {
			projected.Columns = make([]tableedit.ObservedColumn, len(b.Columns))
			copy(projected.Columns, b.Columns)
		}
		for i := range projected.Columns {
			projected.Columns[i].Unsigned = nil
			projected.Columns[i].Charset = nil
			projected.Columns[i].Collation = nil
		}
		return &projected
	}
	retained.Baseline = project(retained.Baseline)
	if retained.Outcome != nil {
		outcome := *retained.Outcome
		outcome.Observed = project(outcome.Observed)
		if retained.Outcome.Observed != nil && outcome.Observed == nil {
			outcome.RefreshError = "Advanced MariaDB observation is unavailable in this partial workflow. The retained execution acknowledgement is unchanged; reconcile explicitly."
		}
		retained.Outcome = &outcome
	}
	return retained
}
