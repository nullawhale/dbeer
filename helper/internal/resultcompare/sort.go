package resultcompare

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"sort"
)

type entry struct {
	key  []byte
	ref  RowRef
	side byte
}
type runReader struct {
	file    *diskFile
	current entry
	valid   bool
}

func less(a, b entry) bool {
	if c := bytes.Compare(a.key, b.key); c != 0 {
		return c < 0
	}
	if a.side != b.side {
		return a.side < b.side
	}
	return a.ref.Index < b.ref.Index
}
func tagged(dst []byte, s string) []byte {
	var length [8]byte
	binary.BigEndian.PutUint64(length[:], uint64(len(s)))
	dst = append(dst, length[:]...)
	return append(dst, s...)
}
func (r *Result) key(row []*string, side byte) ([]byte, bool) {
	columns := r.left.Metadata().Columns
	if side == 1 {
		columns = r.right.Metadata().Columns
	}
	var key []byte
	for _, m := range r.options.Columns {
		if !m.Key {
			continue
		}
		index := m.Left
		if side == 1 {
			index = m.Right
		}
		c := columns[index]
		if !known(c) {
			return nil, false
		}
		key = tagged(key, c.Engine)
		key = tagged(key, c.NativeType)
		key = tagged(key, effectiveIdentity(c))
		key = tagged(key, c.Encoding)
		if row[index] == nil {
			key = append(key, 0)
		} else {
			key = append(key, 1)
			key = tagged(key, *row[index])
		}
	}
	return key, true
}
func writeEntry(ctx context.Context, f *diskFile, e entry) error {
	var header [9 + refBytes]byte
	binary.BigEndian.PutUint64(header[:], uint64(len(e.key)))
	header[8] = e.side
	putRef(header[9:], e.ref)
	if err := writeContext(ctx, f, header[:]); err != nil {
		return err
	}
	return writeContext(ctx, f, e.key)
}
func (rr *runReader) advance() error {
	var b [9 + refBytes]byte
	n, e := io.ReadFull(rr.file, b[:])
	if e == io.EOF && n == 0 {
		rr.valid = false
		rr.current = entry{}
		return nil
	}
	if e != nil {
		return e
	}
	// Keys originated in validated source rows; reject corrupt scratch lengths
	// without allocating more than the entire private quota.
	length := binary.BigEndian.Uint64(b[:])
	if length > uint64(rr.file.owner.quota) || length > uint64(rr.file.size) {
		return ErrSource
	}
	key := make([]byte, int(length))
	if e := readFull(rr.file, key); e != nil {
		return e
	}
	rr.current = entry{key: key, side: b[8], ref: getRef(b[9:])}
	rr.valid = true
	return nil
}
func (r *Result) sorted(ctx context.Context) (*diskFile, error) {
	var runs []*diskFile
	var entries []entry
	size := 0
	flush := func() error {
		if len(entries) == 0 {
			return nil
		}
		if e := ctx.Err(); e != nil {
			return e
		}
		sort.Slice(entries, func(i, j int) bool { return less(entries[i], entries[j]) })
		f, e := r.scratch.create()
		if e != nil {
			return e
		}
		for _, v := range entries {
			if e := writeEntry(ctx, f, v); e != nil {
				_ = f.Close()
				return e
			}
		}
		if e := f.Close(); e != nil {
			return e
		}
		runs = append(runs, f)
		entries = nil
		size = 0
		return nil
	}
	for side, source := range []Source{r.left, r.right} {
		var count int64
		e := source.Scan(ctx, func(ref RowRef, row []*string) error {
			if e := ctx.Err(); e != nil {
				return e
			}
			if ref.Index != count {
				return ErrSource
			}
			count++
			if len(row) != len(source.Metadata().Columns) {
				return ErrSource
			}
			key, ok := r.key(row, byte(side))
			if !ok {
				if side == 0 {
					return r.emit(ctx, 4, ref, noRef)
				}
				return r.emit(ctx, 4, noRef, ref)
			}
			if len(entries) > 0 && size+len(key)+128 > r.options.MemoryBytes {
				if e := flush(); e != nil {
					return e
				}
			}
			entries = append(entries, entry{key: key, ref: ref, side: byte(side)})
			size += len(key) + 128
			if size >= r.options.MemoryBytes {
				return flush()
			}
			return nil
		})
		if e != nil {
			return nil, e
		}
		if count != source.Metadata().RowCount {
			return nil, ErrSource
		}
	}
	if e := flush(); e != nil {
		return nil, e
	}
	if len(runs) == 0 {
		return r.scratch.create()
	}
	for len(runs) > 1 {
		var next []*diskFile
		for start := 0; start < len(runs); start += r.options.FanIn {
			end := min(start+r.options.FanIn, len(runs))
			merged, e := r.merge(ctx, runs[start:end])
			if e != nil {
				return nil, e
			}
			next = append(next, merged)
		}
		runs = next
	}
	if e := runs[0].reopen(); e != nil {
		return nil, e
	}
	if _, e := runs[0].Seek(0, io.SeekStart); e != nil {
		return nil, e
	}
	return runs[0], nil
}
func (r *Result) merge(ctx context.Context, inputs []*diskFile) (*diskFile, error) {
	out, e := r.scratch.create()
	if e != nil {
		return nil, e
	}
	readers := make([]runReader, len(inputs))
	for i, f := range inputs {
		if e := f.reopen(); e != nil {
			return nil, e
		}
		if _, e := f.Seek(0, io.SeekStart); e != nil {
			return nil, e
		}
		readers[i].file = f
		if e := readers[i].advance(); e != nil {
			return nil, e
		}
	}
	for {
		if e := ctx.Err(); e != nil {
			return nil, e
		}
		best := -1
		for i := range readers {
			if readers[i].valid && (best < 0 || less(readers[i].current, readers[best].current)) {
				best = i
			}
		}
		if best < 0 {
			break
		}
		if e := writeEntry(ctx, out, readers[best].current); e != nil {
			return nil, e
		}
		if e := readers[best].advance(); e != nil {
			return nil, e
		}
	}
	for _, f := range inputs {
		if e := r.scratch.remove(f); e != nil {
			return nil, e
		}
	}
	if e := out.Close(); e != nil {
		return nil, e
	}
	return out, nil
}
func (r *Result) byKey(ctx context.Context) error {
	f, e := r.sorted(ctx)
	if e != nil {
		return e
	}
	rr := runReader{file: f}
	if e = rr.advance(); e != nil {
		return e
	}
	for rr.valid {
		if e := ctx.Err(); e != nil {
			return e
		}
		key := rr.current.key
		first := rr.current
		var second *entry
		duplicate := false
		emitAmbiguous := func(v entry) error {
			if v.side == 0 {
				return r.emit(ctx, 3, v.ref, noRef)
			}
			return r.emit(ctx, 3, noRef, v.ref)
		}
		if e = rr.advance(); e != nil {
			return e
		}
		for rr.valid && bytes.Equal(key, rr.current.key) {
			v := rr.current
			if !duplicate && second == nil && v.side != first.side {
				second = &v
			} else {
				if !duplicate {
					duplicate = true
					if e = emitAmbiguous(first); e != nil {
						return e
					}
					if second != nil {
						if e = emitAmbiguous(*second); e != nil {
							return e
						}
					}
				}
				if e = emitAmbiguous(v); e != nil {
					return e
				}
			}
			if e = rr.advance(); e != nil {
				return e
			}
		}
		if duplicate {
			continue
		}
		if second == nil {
			if first.side == 0 {
				e = r.emit(ctx, 1, first.ref, noRef)
			} else {
				e = r.emit(ctx, 0, noRef, first.ref)
			}
		} else {
			lrow, er := r.left.ReadRow(ctx, first.ref)
			if er != nil {
				return safeSource(er)
			}
			rrow, er := r.right.ReadRow(ctx, second.ref)
			if er != nil {
				return safeSource(er)
			}
			e = r.comparePair(ctx, first.ref, second.ref, lrow, rrow)
		}
		if e != nil {
			return e
		}
	}
	return r.scratch.remove(f)
}
