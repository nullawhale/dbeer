package exportfile

import (
	"context"
	"crypto/sha256"
	"errors"
	"os"
	"path/filepath"

	"dbeer/helper/internal/protocol"
)

// BinaryWriter preserves the destination identity/publication protections for
// native utility output without formatting or interpreting its bytes.
type BinaryWriter struct{ writer *Writer }

func NewBinaryWriter(path string, expected protocol.ExportDestination) (*BinaryWriter, error) {
	return NewBinaryWriterContext(context.Background(), path, expected)
}
func NewBinaryWriterContext(ctx context.Context, path string, expected protocol.ExportDestination) (*BinaryWriter, error) {
	d, err := captureDestinationContext(ctx, path)
	if err != nil {
		return nil, ErrIO
	}
	if !stampsMatch(d.stamp, expected) || d.lock() != nil {
		d.close()
		return nil, ErrIO
	}
	f, err := createTemporary(filepath.Dir(path))
	if err != nil {
		d.close()
		return nil, ErrIO
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		d.close()
		return nil, ErrIO
	}
	return &BinaryWriter{writer: &Writer{file: f, destination: d, temporaryInfo: info, digest: sha256.New(), request: protocol.ExportRequest{Path: path}}}, nil
}
func (w *BinaryWriter) Write(data []byte) (int, error) {
	if err := w.writer.write(data); err != nil {
		return 0, err
	}
	return len(data), nil
}
func (w *BinaryWriter) Abort() { w.writer.Abort() }
func (w *BinaryWriter) Publish(ctx context.Context) error {
	w.writer.publishMu.Lock()
	defer w.writer.publishMu.Unlock()
	if w.writer.published.Load() {
		return nil
	}
	if ctx.Err() != nil {
		w.writer.abortUnlocked()
		return ErrCancelled
	}
	if w.writer.failure != nil || w.writer.file.Sync() != nil || !w.writer.validTemporary() || w.writer.file.Close() != nil {
		w.writer.abortUnlocked()
		return ErrIO
	}
	if ctx.Err() != nil {
		w.writer.abortUnlocked()
		return ErrCancelled
	}
	if err := w.writer.destination.publish(w.writer.file.Name()); err != nil {
		w.writer.abortUnlocked()
		if errors.Is(err, ErrPublicationUnknown) {
			return err
		}
		return ErrIO
	}
	w.writer.published.Store(true)
	w.writer.destination.close()
	if parent, err := os.Open(filepath.Dir(w.writer.request.Path)); err == nil {
		_ = parent.Sync()
		_ = parent.Close()
	}
	return nil
}
