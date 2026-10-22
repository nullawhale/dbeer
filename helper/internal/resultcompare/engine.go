package resultcompare

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"io"
	"os"
)

const refBytes = 56
const reportBytes = 1 + 2*refBytes

var noRef = RowRef{Index: -1}
var kindNames = []string{"added", "deleted", "changed", "ambiguous", "uncertain"}

type Result struct {
	left, right    Source
	options        Options
	summary        Summary
	scratch        *scratch
	reports, index *diskFile
	secret         [32]byte
	closed         bool
}

// Compare consumes both sources using bounded memory. The caller owns sources;
// they must stay open until Result.Close, including during page/value reads.
// Failure removes all scratch. Sources are never executed or modified.
func Compare(ctx context.Context, left, right Source, o Options) (result *Result, err error) {
	s, err := validate(left.Metadata(), right.Metadata(), o)
	if err != nil {
		return nil, err
	}
	if o.QuotaBytes == 0 {
		o.QuotaBytes = DefaultQuotaBytes
	}
	if o.MemoryBytes == 0 {
		o.MemoryBytes = DefaultMemoryBytes
	}
	if o.FanIn == 0 {
		o.FanIn = defaultFanIn
	}
	if o.QuotaBytes < 1 || o.MemoryBytes < 1 || o.FanIn < 2 || o.FanIn > 32 {
		return nil, ErrConfiguration
	}
	if err = os.MkdirAll(o.ScratchDir, 0700); err != nil {
		return nil, err
	}
	if err = os.Chmod(o.ScratchDir, 0700); err != nil {
		return nil, err
	}
	r := &Result{left: left, right: right, options: o, summary: s, scratch: &scratch{dir: o.ScratchDir, quota: o.QuotaBytes, files: make(map[*diskFile]bool)}}
	defer func() {
		if err != nil {
			_ = r.Close()
		}
	}()
	if _, err = rand.Read(r.secret[:]); err != nil {
		return nil, err
	}
	if r.reports, err = r.scratch.create(); err != nil {
		return nil, err
	}
	if r.index, err = r.scratch.create(); err != nil {
		return nil, err
	}
	if o.Mode == "rowOrder" {
		err = r.rowOrder(ctx)
	} else {
		err = r.byKey(ctx)
	}
	if err != nil {
		return nil, err
	}
	r.summary.FullEquality = r.summary.Complete && r.summary.SchemaDifferenceCount == 0 && r.summary.AddedRows == 0 && r.summary.DeletedRows == 0 && r.summary.ChangedRows == 0 && r.summary.AmbiguousRows == 0 && r.summary.UncertainRows == 0
	return r, nil
}
func (r *Result) Summary() Summary {
	s := r.summary
	s.SchemaDifferences = append([]SchemaDifference{}, s.SchemaDifferences...)
	s.Warnings = append([]string{}, s.Warnings...)
	return s
}
func (r *Result) Close() error {
	if r.closed {
		return nil
	}
	r.closed = true
	if r.reports != nil {
		_ = r.reports.Close()
	}
	if r.index != nil {
		_ = r.index.Close()
	}
	for f := range r.scratch.files {
		_ = f.Close()
	}
	return os.RemoveAll(r.scratch.dir)
}
func putRef(b []byte, r RowRef) {
	binary.BigEndian.PutUint64(b, uint64(r.Index))
	binary.BigEndian.PutUint64(b[8:], uint64(r.Offset))
	binary.BigEndian.PutUint64(b[16:], uint64(r.Length))
	copy(b[24:], r.Digest[:])
}
func getRef(b []byte) RowRef {
	r := RowRef{Index: int64(binary.BigEndian.Uint64(b)), Offset: int64(binary.BigEndian.Uint64(b[8:])), Length: int(binary.BigEndian.Uint64(b[16:]))}
	copy(r.Digest[:], b[24:])
	return r
}
func (r *Result) emit(ctx context.Context, kind byte, left, right RowRef) error {
	var b [reportBytes]byte
	b[0] = kind
	putRef(b[1:], left)
	putRef(b[1+refBytes:], right)
	var offset [8]byte
	binary.BigEndian.PutUint64(offset[:], uint64(r.reports.size))
	if e := writeContext(ctx, r.reports, b[:]); e != nil {
		return e
	}
	if e := writeContext(ctx, r.index, offset[:]); e != nil {
		return e
	}
	r.summary.ReportRows++
	switch kind {
	case 0:
		r.summary.AddedRows++
	case 1:
		r.summary.DeletedRows++
	case 2:
		r.summary.ChangedRows++
	case 3:
		r.summary.AmbiguousRows++
	case 4:
		r.summary.UncertainRows++
	}
	return nil
}
func (r *Result) comparePair(ctx context.Context, lref, rref RowRef, lrow, rrow []*string) error {
	if len(lrow) != len(r.left.Metadata().Columns) || len(rrow) != len(r.right.Metadata().Columns) {
		return ErrSource
	}
	different, uncertain := false, false
	for _, m := range r.options.Columns {
		a, b := r.left.Metadata().Columns[m.Left], r.right.Metadata().Columns[m.Right]
		different = different || !sameType(a, b) || !sameValue(lrow[m.Left], rrow[m.Right])
		uncertain = uncertain || !known(a) || !known(b)
	}
	if different {
		if uncertain {
			r.summary.UncertainRows++
		}
		return r.emit(ctx, 2, lref, rref)
	}
	if uncertain {
		return r.emit(ctx, 4, lref, rref)
	}
	r.summary.EqualRows++
	return nil
}

type sourceRow struct {
	ref RowRef
	row []*string
	err error
}

func stream(ctx context.Context, s Source) (<-chan sourceRow, <-chan struct{}) {
	out := make(chan sourceRow)
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer close(out)
		e := s.Scan(ctx, func(ref RowRef, row []*string) error {
			clone := make([]*string, len(row))
			for i, p := range row {
				if p != nil {
					v := *p
					clone[i] = &v
				}
			}
			select {
			case out <- sourceRow{ref: ref, row: clone}:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		})
		if e != nil {
			select {
			case out <- sourceRow{err: e}:
			case <-ctx.Done():
			}
		}
	}()
	return out, done
}
func next(ctx context.Context, ch <-chan sourceRow) (sourceRow, bool, error) {
	select {
	case v, ok := <-ch:
		return v, ok, v.err
	case <-ctx.Done():
		return sourceRow{}, false, ctx.Err()
	}
}
func (r *Result) rowOrder(ctx context.Context) error {
	ctx, cancel := context.WithCancel(ctx)
	var leftCount, rightCount int64
	lch, ldone := stream(ctx, r.left)
	rch, rdone := stream(ctx, r.right)
	defer func() { cancel(); <-ldone; <-rdone }()
	for {
		l, lok, e := next(ctx, lch)
		if e != nil {
			return e
		}
		v, rok, e := next(ctx, rch)
		if e != nil {
			return e
		}
		if !lok && !rok {
			if leftCount != r.left.Metadata().RowCount || rightCount != r.right.Metadata().RowCount {
				return ErrSource
			}
			return nil
		}
		if lok {
			if l.ref.Index != leftCount {
				return ErrSource
			}
			leftCount++
		}
		if rok {
			if v.ref.Index != rightCount {
				return ErrSource
			}
			rightCount++
		}
		if lok && len(l.row) != len(r.left.Metadata().Columns) || rok && len(v.row) != len(r.right.Metadata().Columns) {
			return ErrSource
		}
		if !lok {
			e = r.emit(ctx, 0, noRef, v.ref)
		} else if !rok {
			e = r.emit(ctx, 1, l.ref, noRef)
		} else {
			e = r.comparePair(ctx, l.ref, v.ref, l.row, v.row)
		}
		if e != nil {
			return e
		}
	}
}
func (r *Result) readReport(index int64) (byte, RowRef, RowRef, error) {
	if r.closed {
		return 0, noRef, noRef, ErrClosed
	}
	if index < 0 || index >= r.summary.ReportRows {
		return 0, noRef, noRef, ErrReference
	}
	var offset [8]byte
	if _, e := r.index.ReadAt(offset[:], index*8); e != nil {
		return 0, noRef, noRef, e
	}
	var b [reportBytes]byte
	if _, e := r.reports.ReadAt(b[:], int64(binary.BigEndian.Uint64(offset[:]))); e != nil {
		return 0, noRef, noRef, e
	}
	if int(b[0]) >= len(kindNames) {
		return 0, noRef, noRef, ErrSource
	}
	return b[0], getRef(b[1:]), getRef(b[1+refBytes:]), nil
}
func safeSource(err error) error {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return err
	}
	if err != nil {
		return ErrSource
	}
	return nil
}
func readFull(r io.Reader, p []byte) error { _, e := io.ReadFull(r, p); return e }
