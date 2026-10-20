// Package exportfile writes a complete server execution to a private temporary
// file. Publishing is explicit and atomic, after confirmed SQL completion only.
package exportfile

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/csv"
	"encoding/json"
	"errors"
	"hash"
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"

	"dbeer/helper/internal/protocol"
)

var ErrNullCollision = errors.New("A text value equals the CSV NULL marker. Choose another marker and explicitly run the export again.")
var ErrMultipleResults = errors.New("CSV cannot represent multiple result sets. Choose JSON.")
var ErrPublicationUnknown = errors.New("Export publication could not be verified. Inspect the destination; do not rerun SQL to recover the save.")
var ErrIO = errors.New("The export file could not be written.")
var ErrInvalidRequest = errors.New("Invalid export settings.")
var ErrCancelled = errors.New("Export was cancelled before publishing.")

type Writer struct {
	file          *os.File
	csv           *csv.Writer
	request       protocol.ExportRequest
	columns       []protocol.Column
	current       int
	sets          int
	rows          int64
	total         int64
	open          bool
	published     atomic.Bool
	failure       error
	destination   *destination
	temporaryInfo os.FileInfo
	digest        hash.Hash
	publishMu     sync.Mutex
}

func New(request protocol.ExportRequest) (*Writer, error) {
	if !request.Valid() {
		return nil, ErrInvalidRequest
	}
	destination, err := captureDestination(request.Path)
	if err != nil {
		return nil, ErrIO
	}
	if request.Destination != nil && !stampsMatch(destination.stamp, *request.Destination) {
		destination.close()
		return nil, ErrIO
	}
	file, err := createTemporary(filepath.Dir(request.Path))
	if err != nil {
		destination.close()
		return nil, ErrIO
	}
	temporaryInfo, err := file.Stat()
	if err != nil {
		// Without retained identity no pathname is safe to unlink.
		_ = file.Close()
		destination.close()
		return nil, ErrIO
	}
	writer := &Writer{file: file, request: request, current: -1, destination: destination, temporaryInfo: temporaryInfo, digest: sha256.New()}
	if err := destination.lock(); err != nil {
		writer.Abort()
		return nil, ErrIO
	}
	if request.Format == "csv" {
		writer.csv = csv.NewWriter(output{writer})
	} else if err = writer.write([]byte(`{"version":1,"resultSets":[`)); err != nil {
		writer.Abort()
		return nil, ErrIO
	}
	return writer, nil
}

func (writer *Writer) fail(err error) error {
	if writer.failure == nil {
		writer.failure = err
	}
	return writer.failure
}

func (writer *Writer) write(data []byte) error {
	if writer.failure != nil {
		return writer.failure
	}
	if n, err := writer.file.Write(data); err != nil || n != len(data) {
		return writer.fail(ErrIO)
	}
	_, _ = writer.digest.Write(data)
	return nil
}

type output struct{ writer *Writer }

func (sink output) Write(data []byte) (int, error) {
	if err := sink.writer.write(data); err != nil {
		return 0, err
	}
	return len(data), nil
}

func (writer *Writer) Begin(index int, columns []protocol.Column) error {
	if writer.failure != nil {
		return writer.failure
	}
	if writer.open || index != writer.sets {
		return writer.fail(ErrIO)
	}
	if writer.csv != nil && index != 0 {
		return writer.fail(ErrMultipleResults)
	}
	writer.columns = append([]protocol.Column{}, columns...)
	writer.current, writer.rows, writer.open = index, 0, true
	writer.sets++
	if writer.csv != nil {
		header := make([]string, len(columns))
		for i, column := range columns {
			header[i] = column.Name
		}
		if writer.csv.Write(header) != nil {
			return writer.fail(ErrIO)
		}
		return nil
	}
	if index > 0 {
		if err := writer.write([]byte(",")); err != nil {
			return err
		}
	}
	return writer.write([]byte(`{"rows":[`))
}

func (writer *Writer) Row(index int, values []*string) error {
	if writer.failure != nil {
		return writer.failure
	}
	if !writer.open || index != writer.current || len(values) != len(writer.columns) {
		return writer.fail(ErrIO)
	}
	if writer.csv != nil {
		marker := `\N`
		if writer.request.NullMarker != nil {
			marker = *writer.request.NullMarker
		}
		row := make([]string, len(values))
		for i, value := range values {
			if value == nil {
				row[i] = marker
			} else if *value == marker {
				return writer.fail(ErrNullCollision)
			} else {
				row[i] = *value
			}
		}
		if writer.csv.Write(row) != nil {
			return writer.fail(ErrIO)
		}
	} else {
		if writer.rows > 0 {
			if err := writer.write([]byte(",")); err != nil {
				return err
			}
		}
		encoded, err := json.Marshal(values)
		if err != nil {
			return writer.fail(ErrIO)
		}
		if err = writer.write(encoded); err != nil {
			return err
		}
	}
	writer.rows++
	writer.total++
	return nil
}

func (writer *Writer) End(index int, summary protocol.ResultSet) error {
	if writer.failure != nil {
		return writer.failure
	}
	if !writer.open || index != writer.current {
		return writer.fail(ErrIO)
	}
	writer.open = false
	if writer.csv != nil {
		return nil
	}
	metadata := struct {
		Columns           []protocol.Column `json:"columns"`
		CommandTag        string            `json:"commandTag"`
		RowCount          int64             `json:"rowCount"`
		DisplayedRowCount int64             `json:"displayedRowCount"`
		Truncated         bool              `json:"truncated"`
	}{writer.columns, summary.CommandTag, summary.RowCount, writer.rows, false}
	encoded, err := json.Marshal(metadata)
	if err != nil {
		return writer.fail(ErrIO)
	}
	if err = writer.write([]byte(`],"metadata":`)); err != nil {
		return err
	}
	if err = writer.write(encoded); err != nil {
		return err
	}
	return writer.write([]byte("}"))
}

func (writer *Writer) Commit() error {
	return writer.CommitContext(context.Background())
}

func (writer *Writer) CommitContext(ctx context.Context) error {
	if writer.published.Load() {
		return nil
	}
	if ctx.Err() != nil {
		writer.Abort()
		return ErrCancelled
	}
	if writer.failure != nil {
		writer.Abort()
		return writer.failure
	}
	if writer.open || writer.sets == 0 {
		writer.Abort()
		return ErrIO
	}
	if writer.csv != nil {
		writer.csv.Flush()
		if writer.csv.Error() != nil {
			writer.Abort()
			return ErrIO
		}
	} else if err := writer.write([]byte("]}")); err != nil {
		writer.Abort()
		return err
	}
	if writer.file.Sync() != nil {
		writer.Abort()
		return ErrIO
	}
	if !writer.validTemporary() {
		writer.Abort()
		return ErrIO
	}
	if writer.file.Close() != nil {
		writer.Abort()
		return ErrIO
	}
	if ctx.Err() != nil {
		writer.Abort()
		return ErrCancelled
	}
	writer.publishMu.Lock()
	defer writer.publishMu.Unlock()
	if ctx.Err() != nil {
		writer.abortUnlocked()
		return ErrCancelled
	}
	if err := writer.destination.publish(writer.file.Name()); err != nil {
		writer.abortUnlocked()
		if errors.Is(err, ErrPublicationUnknown) {
			return ErrPublicationUnknown
		}
		return ErrIO
	}
	writer.published.Store(true)
	writer.destination.close()
	// A directory sync failure after observed publication must not be reported as SQL/save failure.
	if parent, err := os.Open(filepath.Dir(writer.request.Path)); err == nil {
		_ = parent.Sync()
		_ = parent.Close()
	}
	return nil
}

func (writer *Writer) validTemporary() bool {
	named, err := os.Lstat(writer.file.Name())
	if err != nil || !named.Mode().IsRegular() || !os.SameFile(named, writer.temporaryInfo) {
		return false
	}
	if _, err := writer.file.Seek(0, 0); err != nil {
		return false
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, writer.file); err != nil {
		return false
	}
	after, err := writer.file.Stat()
	if err != nil || after.Size() != named.Size() || !after.ModTime().Equal(named.ModTime()) {
		return false
	}
	return bytes.Equal(hash.Sum(nil), writer.digest.Sum(nil))
}

func (writer *Writer) Abort() {
	writer.publishMu.Lock()
	defer writer.publishMu.Unlock()
	writer.abortUnlocked()
}
func (writer *Writer) abortUnlocked() {
	if writer.destination != nil {
		writer.destination.close()
	}
	if writer.file != nil {
		_ = writer.file.Close()
		if named, err := os.Lstat(writer.file.Name()); err == nil && os.SameFile(named, writer.temporaryInfo) {
			_ = os.Remove(writer.file.Name())
		}
	}
}

// Cancellation unlinks the private temporary file immediately, even while a
// database worker is still recovering. os.File permits concurrent Close/Write;
// a published destination is never removed by this cleanup path.
func (writer *Writer) CancelOn(ctx context.Context) func() {
	done := make(chan struct{})
	var once sync.Once
	go func() {
		select {
		case <-ctx.Done():
			writer.Abort()
		case <-done:
		}
	}()
	return func() { once.Do(func() { close(done) }) }
}

func (writer *Writer) RowCount() int64 { return writer.total }
