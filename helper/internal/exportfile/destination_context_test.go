package exportfile

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

type cancelDuringHash struct {
	context.Context
	cancel context.CancelFunc
	checks atomic.Int32
}

func (ctx *cancelDuringHash) Err() error {
	// Entry check, first Read check, then cancellation after that actual read.
	if ctx.checks.Add(1) == 3 {
		ctx.cancel()
	}
	return ctx.Context.Err()
}

func TestDestinationCaptureAndBinaryPreparationCancelDuringHash(t *testing.T) {
	path := filepath.Join(t.TempDir(), "backup.dump")
	if os.WriteFile(path, make([]byte, 1024*1024), 0600) != nil {
		t.Fatal("cannot create destination hash fixture")
	}
	stamp, err := CaptureDestination(path)
	if err != nil {
		t.Fatal("cannot capture destination fixture")
	}
	for _, binary := range []bool{false, true} {
		t.Run(map[bool]string{false: "capture", true: "binary"}[binary], func(t *testing.T) {
			parent, cancel := context.WithCancel(context.Background())
			defer cancel()
			ctx := &cancelDuringHash{Context: parent, cancel: cancel}
			if binary {
				writer, err := NewBinaryWriterContext(ctx, path, stamp)
				if writer != nil {
					writer.Abort()
				}
				if err == nil {
					t.Fatal("cancelled destination hash admitted a binary writer")
				}
			} else if _, err := CaptureDestinationContext(ctx, path); !errors.Is(err, context.Canceled) {
				t.Fatal("destination hash did not observe cancellation during its read")
			}
			if parent.Err() == nil || ctx.checks.Load() < 3 {
				t.Fatal("fixture did not reach hash cancellation")
			}
			info, err := os.Stat(path)
			if err != nil || info.Size() != 1024*1024 {
				t.Fatal("cancelled hash modified its destination")
			}
		})
	}
}

func TestBinaryPublicationRetainsCancellableDestinationRevalidation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "backup.dump")
	if os.WriteFile(path, []byte("keep"), 0600) != nil {
		t.Fatal("cannot create destination fixture")
	}
	stamp, err := CaptureDestination(path)
	if err != nil {
		t.Fatal("cannot capture destination fixture")
	}
	ctx, cancel := context.WithCancel(context.Background())
	writer, err := NewBinaryWriterContext(ctx, path, stamp)
	if err != nil {
		cancel()
		t.Fatal("cannot prepare binary writer")
	}
	defer writer.Abort()
	if _, err := writer.Write([]byte("replacement")); err != nil {
		t.Fatal("cannot write binary fixture")
	}
	cancel()
	if writer.Publish(context.Background()) == nil {
		t.Fatal("cancelled destination lifetime published a replacement")
	}
	unchanged(t, path)
}
