package postgres

import "dbeer/helper/internal/tableedit"

// These descriptors come only from the retained migration's projected loader.
// The original complete catalog remains separate from its expected removals.
type pgAdvancedCopyRepair struct {
	Source       tableedit.Target
	SourceID     string
	ConstraintID string
	Name         string
	ReferenceID  string
}

// Session-private acknowledged execution evidence. It contains metadata only;
// portable intent and the client protocol cannot supply or consume it.
type pgAdvancedCopyCheckpoint struct {
	PlanID, PlanDigest, ContentDigest string
	BackendPID                        uint32
	Before, After                     tableedit.Baseline
	CombinedBefore, CombinedAfter     tableedit.Baseline
	Orders                            map[string][]string
	Replaced                          map[string]bool
	Repairs                           []pgAdvancedCopyRepair
}
