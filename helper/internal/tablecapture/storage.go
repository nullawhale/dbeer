package tablecapture

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"dbeer/helper/internal/resultartifact"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"os"
	"path/filepath"
	"sync"
	"unicode/utf8"
)

// Inputs share half the combined budget; the other half remains available for
// comparison runs/merge peaks. Final accounting passes only actual remaining bytes.
type Budget struct {
	mu          sync.Mutex
	Used, Limit int64
}

func (b *Budget) Reserve(n int64, final bool) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	headroom := int64(4 << 20)
	if final {
		headroom = 0
	}
	if n < 0 || n > b.Limit-headroom-b.Used {
		return ErrQuota
	}
	b.Used += n
	return nil
}
func (b *Budget) Bytes() int64 { b.mu.Lock(); defer b.mu.Unlock(); return b.Used }

type Writer struct {
	err           error
	ID, dir, root string
	file          *os.File
	hash          hash.Hash
	rows, bytes   int64
	budget        *Budget
	columns       []Column
	engine        string
	sealed        bool
}

func NewWriter(root string, columns []Column, engine string, budget *Budget) (*Writer, error) {
	var token [16]byte
	if _, e := rand.Read(token[:]); e != nil {
		return nil, e
	}
	token[6] = token[6]&15 | 64
	token[8] = token[8]&63 | 128
	id := fmt.Sprintf("%x-%x-%x-%x-%x", token[:4], token[4:6], token[6:8], token[8:10], token[10:])
	dir := filepath.Join(root, id+".pending")
	if e := os.Mkdir(dir, 0700); e != nil {
		return nil, e
	}
	file, e := os.OpenFile(filepath.Join(dir, "rows.jsonl"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return nil, e
	}
	return &Writer{ID: id, dir: dir, root: root, file: file, hash: sha256.New(), budget: budget, columns: columns, engine: engine}, nil
}
func (w *Writer) Row(row []*string) error {
	if w.sealed || len(row) != len(w.columns) {
		return ErrInvalid
	}
	for _, v := range row {
		if v != nil && !utf8.ValidString(*v) {
			return ErrUnsupported
		}
	}
	b, e := json.Marshal(row)
	if e != nil || len(b) > MaxRowBytes {
		return ErrUnsupported
	}
	b = append(b, '\n')
	if e = w.budget.Reserve(int64(len(b)), false); e != nil {
		return e
	}
	n, e := w.file.Write(b)
	if e != nil || n != len(b) {
		return ErrInvalid
	}
	w.hash.Write(b)
	w.rows++
	w.bytes += int64(n)
	return nil
}
func (w *Writer) Rows() int64    { return w.rows }
func (w *Writer) Digest() string { return hex.EncodeToString(w.hash.Sum(nil)) }
func (w *Writer) Close() {
	if w.file != nil {
		w.err = w.file.Sync()
		if e := w.file.Close(); w.err == nil {
			w.err = e
		}
		w.file = nil
	}
}
func (w *Writer) Publish(ctx context.Context, out Outcome) (resultartifact.Artifact, error) {
	if e := ctx.Err(); e != nil {
		return nil, e
	}
	w.Close()
	if w.err != nil {
		return nil, w.err
	}
	w.sealed = true
	columns := make([]resultartifact.Column, len(w.columns))
	for i, c := range w.columns {
		columns[i] = resultartifact.Column{Index: i, Name: c.Name, Engine: w.engine, NativeType: c.NativeType, Encoding: c.Encoding}
	}
	partial := len(out.PartialReasons) > 0
	manifest := map[string]any{"version": 1, "id": w.ID, "title": "Temporary table capture", "capturedAt": 0, "engine": w.engine, "sql": "", "environment": "unspecified", "outcome": "succeeded", "columns": columns, "rowCount": w.rows, "truncated": partial, "partial": partial, "commandTag": "", "rowsBytes": w.bytes, "rowsSHA256": w.Digest()}
	if !partial {
		manifest["sourceRowCount"] = w.rows
	}
	b, e := json.Marshal(manifest)
	if e != nil {
		return nil, e
	}
	if e = w.budget.Reserve(int64(len(b)), true); e != nil {
		return nil, e
	}
	if e = os.WriteFile(filepath.Join(w.dir, "manifest.json"), b, 0600); e != nil {
		return nil, e
	}
	if e = os.Rename(w.dir, filepath.Join(w.root, w.ID)); e != nil {
		return nil, e
	}
	return resultartifact.NewStore(w.root).Open(ctx, w.ID)
}
