package sqlite

import (
	"bufio"
	"bytes"
	"container/heap"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"dbeer/helper/internal/tableedit"
	lib "zombiezen.com/go/sqlite"
)

const structureDigestChunkRows = 65536
const structureDigestMergeWidth = 16
const structureDigestQuotaBytes int64 = 256 << 20

// ErrStructureDigestQuota identifies the bounded private disk-workspace limit.
var ErrStructureDigestQuota = errors.New("The structure verification workspace reached its disk limit.")
var errStructureDigestIO = errors.New("The private structure verification workspace is unavailable.")

// structureValueDigest hashes a canonical sorted multiset of typed row hashes.
// External sorting retains duplicate multiplicity without an in-memory row cap.
// Equality has the same SHA-256 collision assumption as table-edit fingerprints;
// order-independent XOR or sums are deliberately not used.
func (s *Session) structureValueDigest(ctx context.Context, table string, columns []tableedit.ObservedColumn) (string, int64, error) {
	return s.structureValueDigestAt(ctx, table, columns, "", structureDigestQuotaBytes)
}

func (s *Session) structureValueDigestAt(ctx context.Context, table string, columns []tableedit.ObservedColumn, parent string, quota int64) (string, int64, error) {
	if err := ctx.Err(); err != nil {
		return "", 0, err
	}
	if len(columns) == 0 || quota < sha256.Size {
		return "", 0, ErrStructureDigestQuota
	}
	dir, err := os.MkdirTemp(parent, "dbeer-sqlite-structure-")
	if err != nil {
		return "", 0, errStructureDigestIO
	}
	defer os.RemoveAll(dir)
	workspace := structureDigestWorkspace{dir: dir, quota: quota}
	names := make([]string, len(columns))
	for i, c := range columns {
		names[i] = quote(c.Name)
	}
	oldInternal := s.internal
	s.internal = true
	defer func() { s.internal = oldInternal }()
	previous := s.conn.SetInterrupt(ctx.Done())
	defer s.conn.SetInterrupt(previous)
	stmt, tail, err := s.conn.PrepareTransient("SELECT " + strings.Join(names, ",") + " FROM main." + quote(table))
	if err != nil {
		return "", 0, err
	}
	defer stmt.Finalize()
	if tail != 0 || stmt.ColumnCount() != len(columns) {
		return "", 0, errStructureDigestIO
	}
	chunk := make([][sha256.Size]byte, 0, structureDigestChunkRows)
	runs := []structureDigestRun{}
	buffer := make([]byte, 64<<10)
	var count int64
	for {
		if err := ctx.Err(); err != nil {
			return "", count, err
		}
		row, err := stmt.Step()
		if err != nil {
			return "", count, err
		}
		if !row {
			break
		}
		fingerprint, err := structureRowDigest(ctx, stmt, buffer)
		if err != nil {
			return "", count, err
		}
		count++
		chunk = append(chunk, fingerprint)
		if len(chunk) == structureDigestChunkRows {
			run, err := workspace.writeRun(ctx, chunk)
			if err != nil {
				return "", count, err
			}
			runs = append(runs, run)
			chunk = chunk[:0]
		}
	}
	if len(chunk) > 0 {
		run, err := workspace.writeRun(ctx, chunk)
		if err != nil {
			return "", count, err
		}
		runs = append(runs, run)
	}
	// Bound both open file descriptors and merge buffers independently of rows.
	for len(runs) > structureDigestMergeWidth {
		next := []structureDigestRun{}
		for i := 0; i < len(runs); i += structureDigestMergeWidth {
			group := runs[i:min(i+structureDigestMergeWidth, len(runs))]
			run, err := workspace.mergeRun(ctx, group)
			if err != nil {
				return "", count, err
			}
			next = append(next, run)
		}
		runs = next
	}
	h := sha256.New()
	_, _ = h.Write([]byte("DBeer/SQLite/structure-multiset/v1\x00"))
	writeStructureUint(h, uint64(count))
	if err := mergeStructureDigests(ctx, runs, h); err != nil {
		return "", count, err
	}
	return hex.EncodeToString(h.Sum(nil)), count, nil
}

func structureRowDigest(ctx context.Context, stmt *lib.Stmt, buffer []byte) ([sha256.Size]byte, error) {
	h := sha256.New()
	_, _ = h.Write([]byte("DBeer/SQLite/structure-row/v1\x00"))
	writeStructureUint(h, uint64(stmt.ColumnCount()))
	for i := 0; i < stmt.ColumnCount(); i++ {
		if err := ctx.Err(); err != nil {
			return [sha256.Size]byte{}, err
		}
		typ := stmt.ColumnType(i)
		_, _ = h.Write([]byte{byte(typ)})
		switch typ {
		case lib.TypeNull:
		case lib.TypeInteger:
			writeStructureUint(h, uint64(stmt.ColumnInt64(i)))
		case lib.TypeFloat:
			writeStructureUint(h, math.Float64bits(stmt.ColumnFloat(i)))
		case lib.TypeText, lib.TypeBlob:
			reader := stmt.ColumnReader(i)
			writeStructureUint(h, uint64(reader.Len()))
			for reader.Len() > 0 {
				if err := ctx.Err(); err != nil {
					return [sha256.Size]byte{}, err
				}
				n, err := reader.Read(buffer)
				if err != nil && err != io.EOF {
					return [sha256.Size]byte{}, err
				}
				_, _ = h.Write(buffer[:n])
			}
		default:
			return [sha256.Size]byte{}, errStructureDigestIO
		}
	}
	var digest [sha256.Size]byte
	copy(digest[:], h.Sum(nil))
	return digest, nil
}

func writeStructureUint(w io.Writer, n uint64) {
	var encoded [8]byte
	binary.BigEndian.PutUint64(encoded[:], n)
	_, _ = w.Write(encoded[:])
}

type structureDigestRun struct {
	path string
	size int64
}

type structureDigestWorkspace struct {
	dir         string
	quota, used int64
	next        int
}

func (w *structureDigestWorkspace) create(size int64) (*os.File, structureDigestRun, error) {
	if size > w.quota-w.used {
		return nil, structureDigestRun{}, ErrStructureDigestQuota
	}
	w.next++
	path := filepath.Join(w.dir, "run-"+hex.EncodeToString(binary.BigEndian.AppendUint64(nil, uint64(w.next))))
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return nil, structureDigestRun{}, errStructureDigestIO
	}
	w.used += size
	return f, structureDigestRun{path: path, size: size}, nil
}

func (w *structureDigestWorkspace) writeRun(ctx context.Context, rows [][sha256.Size]byte) (structureDigestRun, error) {
	sort.Slice(rows, func(i, j int) bool { return bytes.Compare(rows[i][:], rows[j][:]) < 0 })
	if err := ctx.Err(); err != nil {
		return structureDigestRun{}, err
	}
	f, run, err := w.create(int64(len(rows)) * sha256.Size)
	if err != nil {
		return run, err
	}
	defer f.Close()
	writer := bufio.NewWriterSize(f, 64<<10)
	for _, row := range rows {
		if err := ctx.Err(); err != nil {
			return run, err
		}
		if _, err := writer.Write(row[:]); err != nil {
			return run, errStructureDigestIO
		}
	}
	if err := writer.Flush(); err != nil {
		return run, errStructureDigestIO
	}
	if err := f.Close(); err != nil {
		return run, errStructureDigestIO
	}
	return run, nil
}

func (w *structureDigestWorkspace) mergeRun(ctx context.Context, runs []structureDigestRun) (structureDigestRun, error) {
	var size int64
	for _, r := range runs {
		size += r.size
	}
	f, run, err := w.create(size)
	if err != nil {
		return run, err
	}
	defer f.Close()
	writer := bufio.NewWriterSize(f, 64<<10)
	if err := mergeStructureDigests(ctx, runs, writer); err != nil {
		return run, err
	}
	if err := writer.Flush(); err != nil {
		return run, errStructureDigestIO
	}
	if err := f.Close(); err != nil {
		return run, errStructureDigestIO
	}
	for _, r := range runs {
		if err := os.Remove(r.path); err != nil {
			return run, errStructureDigestIO
		}
		w.used -= r.size
	}
	return run, nil
}

type structureDigestItem struct {
	value  [sha256.Size]byte
	reader int
}
type structureDigestHeap []structureDigestItem

func (h structureDigestHeap) Len() int { return len(h) }
func (h structureDigestHeap) Less(i, j int) bool {
	return bytes.Compare(h[i].value[:], h[j].value[:]) < 0
}
func (h structureDigestHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }
func (h *structureDigestHeap) Push(x any)   { *h = append(*h, x.(structureDigestItem)) }
func (h *structureDigestHeap) Pop() any {
	old := *h
	x := old[len(old)-1]
	*h = old[:len(old)-1]
	return x
}

func mergeStructureDigests(ctx context.Context, runs []structureDigestRun, out io.Writer) error {
	files := []*os.File{}
	defer func() {
		for _, f := range files {
			_ = f.Close()
		}
	}()
	readers := make([]*bufio.Reader, len(runs))
	remaining := make([]int64, len(runs))
	items := structureDigestHeap{}
	read := func(i int) error {
		if remaining[i] == 0 {
			return nil
		}
		var digest [sha256.Size]byte
		_, err := io.ReadFull(readers[i], digest[:])
		if err != nil {
			return errStructureDigestIO
		}
		remaining[i] -= sha256.Size
		heap.Push(&items, structureDigestItem{value: digest, reader: i})
		return nil
	}
	for i, run := range runs {
		if err := ctx.Err(); err != nil {
			return err
		}
		f, err := os.Open(run.path)
		if err != nil {
			return errStructureDigestIO
		}
		files = append(files, f)
		info, err := f.Stat()
		if err != nil || run.size < 0 || run.size%sha256.Size != 0 || info.Size() != run.size {
			return errStructureDigestIO
		}
		readers[i] = bufio.NewReaderSize(f, 32<<10)
		remaining[i] = run.size
		if err := read(i); err != nil {
			return err
		}
	}
	for items.Len() > 0 {
		if err := ctx.Err(); err != nil {
			return err
		}
		item := heap.Pop(&items).(structureDigestItem)
		if _, err := out.Write(item.value[:]); err != nil {
			return errStructureDigestIO
		}
		if err := read(item.reader); err != nil {
			return err
		}
	}
	return nil
}
