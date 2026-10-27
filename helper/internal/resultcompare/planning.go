package resultcompare

import "context"

// MappedTypesCompatible checks every retained mapping, independently of the
// bounded schema-difference examples. Explicit names and excluded columns do
// not affect compatibility; unknown or different type identities always do.
func (r *Result) MappedTypesCompatible() bool {
	if r.closed || r.options.Mode != "key" {
		return false
	}
	left, right := r.left.Metadata(), r.right.Metadata()
	for _, mapping := range r.options.Columns {
		if mapping.Left < 0 || mapping.Left >= len(left.Columns) || mapping.Right < 0 || mapping.Right >= len(right.Columns) {
			return false
		}
		a, b := left.Columns[mapping.Left], right.Columns[mapping.Right]
		if !known(a) || !known(b) || !sameType(a, b) {
			return false
		}
	}
	return true
}

// OriginalDifference reads complete immutable rows for an owning planner. It is
// deliberately separate from paged display previews and exposes no file paths.
func (r *Result) OriginalDifference(ctx context.Context, index int64) (kind string, left, right []*string, err error) {
	if r.closed {
		return "", nil, nil, ErrClosed
	}
	if err = ctx.Err(); err != nil {
		return
	}
	k, a, b, err := r.readReport(index)
	if err != nil {
		return "", nil, nil, err
	}
	if int(k) >= len(kindNames) {
		return "", nil, nil, ErrSource
	}
	if a.Index >= 0 {
		left, err = r.left.ReadRow(ctx, a)
		if err != nil || len(left) != len(r.left.Metadata().Columns) {
			return "", nil, nil, ErrSource
		}
	}
	if b.Index >= 0 {
		right, err = r.right.ReadRow(ctx, b)
		if err != nil || len(right) != len(r.right.Metadata().Columns) {
			return "", nil, nil, ErrSource
		}
	}
	return kindNames[k], left, right, nil
}
