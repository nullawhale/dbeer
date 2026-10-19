// Package exportfile writes a complete server execution to a private temporary
// file. Publishing is explicit and atomic, after confirmed SQL completion only.
package exportfile

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"

	"dbeer/helper/internal/protocol"
)

var ErrNullCollision = errors.New("A text value equals the CSV NULL marker. Choose another marker and explicitly run the export again.")
var ErrMultipleResults = errors.New("CSV cannot represent multiple result sets. Choose JSON.")
var ErrIO = errors.New("The export file could not be written.")
var ErrInvalidRequest = errors.New("Invalid export settings.")
var ErrCancelled = errors.New("Export was cancelled before publishing.")

type Writer struct {
	file      *os.File
	csv       *csv.Writer
	request   protocol.ExportRequest
	columns   []protocol.Column
	current   int
	sets      int
	rows      int64
	total     int64
	open      bool
	published atomic.Bool
	failure   error
}

func New(request protocol.ExportRequest) (*Writer, error) {
	if !request.Valid() {
		return nil, ErrInvalidRequest
	}
	file, err := os.CreateTemp(filepath.Dir(request.Path), ".dbeer-export-*")
	if err != nil {
		return nil, ErrIO
	}
	writer := &Writer{file: file, request: request, current: -1}
	if request.Format == "csv" {
		writer.csv = csv.NewWriter(file)
	} else if _, err = file.WriteString(`{"version":1,"resultSets":[`); err != nil {
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
	if _, err := writer.file.Write(data); err != nil {
		return writer.fail(ErrIO)
	}
	return nil
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
	if writer.file.Close() != nil {
		writer.Abort()
		return ErrIO
	}
	if ctx.Err() != nil {
		writer.Abort()
		return ErrCancelled
	}
	if os.Rename(writer.file.Name(), writer.request.Path) != nil {
		writer.Abort()
		return ErrIO
	}
	writer.published.Store(true)
	return nil
}

func (writer *Writer) Abort() {
	if writer.file != nil && !writer.published.Load() {
		_ = writer.file.Close()
		_ = os.Remove(writer.file.Name())
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
