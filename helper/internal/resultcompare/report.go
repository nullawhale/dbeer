package resultcompare

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"unicode/utf8"
)

const MaxPageBytes = 1024 * 1024
const MinPageBytes = 4096
const DefaultPageBytes = 256 * 1024
const MaxValueBytes = 1024 * 1024

func (r *Result) valueRef(report int64, side byte, mapping int) string {
	var data [17]byte
	binary.BigEndian.PutUint64(data[:], uint64(report))
	data[8] = side
	binary.BigEndian.PutUint64(data[9:], uint64(mapping))
	h := hmac.New(sha256.New, r.secret[:])
	h.Write(data[:])
	return base64.RawURLEncoding.EncodeToString(append(data[:], h.Sum(nil)...))
}
func (r *Result) preview(report int64, side byte, mapping int, value *string) *Preview {
	p := &Preview{IsNull: value == nil, ValueRef: r.valueRef(report, side, mapping)}
	if value != nil {
		p.TotalBytes = int64(len(*value))
		end := min(len(*value), 256)
		for end > 0 && !utf8.ValidString((*value)[:end]) {
			end--
		}
		p.Preview = (*value)[:end]
		p.Truncated = end < len(*value)
	}
	return p
}
func (r *Result) cells(report int64, lrow, rrow []*string, mapping int) Cell {
	m := r.options.Columns[mapping]
	cell := Cell{Mapping: mapping}
	if lrow != nil {
		cell.Left = r.preview(report, 0, mapping, lrow[m.Left])
	}
	if rrow != nil {
		cell.Right = r.preview(report, 1, mapping, rrow[m.Right])
	}
	if lrow != nil && rrow != nil {
		a, b := r.left.Metadata().Columns[m.Left], r.right.Metadata().Columns[m.Right]
		cell.Different = !sameType(a, b) || !sameValue(lrow[m.Left], rrow[m.Right])
		cell.Uncertain = !known(a) || !known(b)
	}
	return cell
}

// Page bounds the encoded JSON page, including cell previews. To inspect a wide
// row, repeat offset with limit=1 and its NextCellOffset. Every mapping remains
// reachable without embedding an entire valid 16MiB row in a protocol frame.
func (r *Result) Page(ctx context.Context, offset int64, limit, maxBytes, cellOffset int) (Page, error) {
	p := Page{Offset: offset, NextOffset: offset, Rows: []Row{}}
	if r.closed {
		return p, ErrClosed
	}
	if limit == 0 {
		limit = 100
	}
	if maxBytes == 0 {
		maxBytes = DefaultPageBytes
	}
	if offset < 0 || offset > r.summary.ReportRows || limit < 1 || limit > 1000 || maxBytes < MinPageBytes || maxBytes > MaxPageBytes || cellOffset < 0 || cellOffset >= len(r.options.Columns) {
		return p, ErrReference
	}
	for i := offset; i < r.summary.ReportRows && len(p.Rows) < limit; i++ {
		if e := ctx.Err(); e != nil {
			return p, e
		}
		kind, lref, rref, e := r.readReport(i)
		if e != nil {
			return p, e
		}
		row := Row{Index: i, Kind: kindNames[kind], Cells: []Cell{}, CellOffset: cellOffset, NextCellOffset: cellOffset, TotalCells: len(r.options.Columns)}
		var lrow, rrow []*string
		if lref.Index >= 0 {
			row.LeftIndex = &lref.Index
			lrow, e = r.left.ReadRow(ctx, lref)
			if e != nil {
				return p, safeSource(e)
			}
		}
		if rref.Index >= 0 {
			row.RightIndex = &rref.Index
			rrow, e = r.right.ReadRow(ctx, rref)
			if e != nil {
				return p, safeSource(e)
			}
		}
		if lrow != nil && len(lrow) != len(r.left.Metadata().Columns) || rrow != nil && len(rrow) != len(r.right.Metadata().Columns) {
			return p, ErrSource
		}
		p.Rows = append(p.Rows, row)
		last := len(p.Rows) - 1
		for mapping := cellOffset; mapping < len(r.options.Columns); mapping++ {
			cell := r.cells(i, lrow, rrow, mapping)
			p.Rows[last].Cells = append(p.Rows[last].Cells, cell)
			p.Rows[last].NextCellOffset = mapping + 1
			p.Rows[last].CellsTruncated = mapping+1 < len(r.options.Columns)
			data, e := json.Marshal(p)
			if e != nil {
				return p, e
			}
			if len(data) > maxBytes-128 {
				p.Rows[last].Cells = p.Rows[last].Cells[:len(p.Rows[last].Cells)-1]
				p.Rows[last].NextCellOffset = mapping
				p.Rows[last].CellsTruncated = true
				break
			}
		}
		if len(p.Rows[last].Cells) == 0 {
			p.Rows = p.Rows[:last]
			break
		}
		p.NextOffset = i + 1
		if p.Rows[last].CellsTruncated {
			break
		}
	}
	p.HasMore = p.NextOffset < r.summary.ReportRows
	return p, nil
}
func (r *Result) Value(ctx context.Context, reference string, offset int64, maxBytes int) (Value, error) {
	v := Value{ValueRef: reference, Offset: offset, NextOffset: offset}
	if r.closed {
		return v, ErrClosed
	}
	if maxBytes == 0 {
		maxBytes = 64 * 1024
	}
	if maxBytes < 1 || maxBytes > MaxValueBytes || offset < 0 {
		return v, ErrReference
	}
	raw, e := base64.RawURLEncoding.DecodeString(reference)
	if e != nil || len(raw) != 49 {
		return v, ErrReference
	}
	h := hmac.New(sha256.New, r.secret[:])
	h.Write(raw[:17])
	if !hmac.Equal(h.Sum(nil), raw[17:]) || raw[8] > 1 {
		return v, ErrReference
	}
	report := int64(binary.BigEndian.Uint64(raw[:8]))
	mapping := int64(binary.BigEndian.Uint64(raw[9:17]))
	if mapping < 0 || mapping >= int64(len(r.options.Columns)) {
		return v, ErrReference
	}
	_, left, right, e := r.readReport(report)
	if e != nil {
		return v, e
	}
	ref := left
	source := r.left
	column := r.options.Columns[mapping].Left
	if raw[8] == 1 {
		ref = right
		source = r.right
		column = r.options.Columns[mapping].Right
	}
	if ref.Index < 0 {
		return v, ErrReference
	}
	row, e := source.ReadRow(ctx, ref)
	if e != nil {
		return v, safeSource(e)
	}
	if column >= len(row) {
		return v, ErrSource
	}
	value := row[column]
	v.IsNull = value == nil
	if value == nil {
		if offset != 0 {
			return v, ErrReference
		}
		return v, nil
	}
	v.TotalBytes = int64(len(*value))
	if offset > v.TotalBytes {
		return v, ErrReference
	}
	end := min(v.TotalBytes, offset+int64(maxBytes))
	v.DataBase64 = base64.StdEncoding.EncodeToString([]byte((*value)[offset:end]))
	v.NextOffset = end
	v.HasMore = end < v.TotalBytes
	return v, nil
}
