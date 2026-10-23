package resultcompare

import (
	"context"
	"dbeer/helper/internal/textdiff"
	"encoding/base64"
	"strings"
)

// TextDiff reads the original immutable row on demand. Column encoding controls
// binary handling; base64 payloads must never be presented as textual values.
func (r *Result) TextDiff(ctx context.Context, report int64, mapping int) (textdiff.Diff, error) {
	if r.closed {
		return textdiff.Diff{}, ErrClosed
	}
	if mapping < 0 || mapping >= len(r.options.Columns) {
		return textdiff.Diff{}, ErrReference
	}
	if err := ctx.Err(); err != nil {
		return textdiff.Diff{}, err
	}
	_, left, right, err := r.readReport(report)
	if err != nil {
		return textdiff.Diff{}, err
	}
	read := func(source Source, ref RowRef, column int) (textdiff.Input, error) {
		if ref.Index < 0 {
			return textdiff.Input{Kind: "absent"}, nil
		}
		row, e := source.ReadRow(ctx, ref)
		if e != nil {
			return textdiff.Input{}, safeSource(e)
		}
		if column < 0 || column >= len(row) || column >= len(source.Metadata().Columns) {
			return textdiff.Input{}, ErrSource
		}
		if row[column] == nil {
			return textdiff.Input{Kind: "null"}, nil
		}
		if source.Metadata().Columns[column].Encoding == "base64" {
			value := *row[column]
			size := base64.StdEncoding.DecodedLen(len(value))
			if strings.HasSuffix(value, "==") {
				size -= 2
			} else if strings.HasSuffix(value, "=") {
				size--
			}
			return textdiff.Input{Kind: "binary", TotalBytes: int64(max(0, size))}, nil
		}
		return textdiff.Text(*row[column]), nil
	}
	m := r.options.Columns[mapping]
	a, err := read(r.left, left, m.Left)
	if err != nil {
		return textdiff.Diff{}, err
	}
	b, err := read(r.right, right, m.Right)
	if err != nil {
		return textdiff.Diff{}, err
	}
	return textdiff.Compare(ctx, a, b)
}
