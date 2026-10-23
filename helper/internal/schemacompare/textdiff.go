package schemacompare

import (
	"bytes"
	"context"
	"dbeer/helper/internal/textdiff"
	"encoding/json"
	"io"
)

// MetadataTextDiff resolves full captured properties, rather than the 256-byte previews.
// Scalar strings are decoded for readable expressions; structured properties
// retain their JSON representation and receive line-oriented formatting.
func (r *Result) MetadataTextDiff(ctx context.Context, index int64) (textdiff.Diff, error) {
	if index < 0 || index >= int64(len(r.Report.Differences)) {
		return textdiff.Diff{}, ErrInvalid
	}
	if err := ctx.Err(); err != nil {
		return textdiff.Diff{}, err
	}
	if r.file == nil {
		return textdiff.Diff{}, ErrInvalid
	}
	read := func(p *Preview) (textdiff.Input, error) {
		if p == nil {
			return textdiff.Input{Kind: "absent"}, nil
		}
		s, ok := r.values[p.ValueRef]
		if !ok {
			return textdiff.Input{}, ErrInvalid
		}
		b := make([]byte, min(s.size, int64(textdiff.MaxTextBytes)))
		if _, err := r.file.ReadAt(b, s.offset); err != nil && err != io.EOF {
			return textdiff.Input{}, err
		}
		if s.size > int64(len(b)) {
			// Do not decode a partial JSON escape sequence or misrepresent it as
			// the full property. Compare marks this representation as limited.
			return textdiff.Input{Kind: "text", Text: string(bytes.ToValidUTF8(b, nil)), TotalBytes: s.size, Limited: true}, nil
		}
		if bytes.Equal(b, []byte("null")) {
			return textdiff.Input{Kind: "null"}, nil
		}
		var scalar string
		if json.Unmarshal(b, &scalar) == nil {
			return textdiff.Text(scalar), nil
		}
		var pretty bytes.Buffer
		if json.Indent(&pretty, b, "", "  ") != nil {
			return textdiff.Input{}, ErrInvalid
		}
		return textdiff.Text(pretty.String()), nil
	}
	difference := r.Report.Differences[index]
	a, err := read(difference.SourcePreview)
	if err != nil {
		return textdiff.Diff{}, err
	}
	b, err := read(difference.TargetPreview)
	if err != nil {
		return textdiff.Diff{}, err
	}
	return textdiff.Compare(ctx, a, b)
}
