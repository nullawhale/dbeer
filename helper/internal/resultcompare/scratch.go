package resultcompare

import (
	"context"
	"io"
	"os"
	"path/filepath"
)

const DefaultQuotaBytes int64 = 8 * 1024 * 1024 * 1024
const DefaultMemoryBytes = 32 * 1024 * 1024
const defaultFanIn = 8

type scratch struct {
	dir         string
	quota, used int64
	sequence    int
	files       map[*diskFile]bool
}
type diskFile struct {
	*os.File
	owner *scratch
	size  int64
}

func (s *scratch) create() (*diskFile, error) {
	f, e := os.OpenFile(filepath.Join(s.dir, fmtName(s.sequence)), os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
	s.sequence++
	if e != nil {
		return nil, e
	}
	df := &diskFile{File: f, owner: s}
	s.files[df] = true
	return df, nil
}
func fmtName(n int) string {
	const digits = "0123456789abcdef"
	var b [16]byte
	for i := range b {
		b[len(b)-1-i] = digits[n&15]
		n >>= 4
	}
	return string(b[:]) + ".bin"
}
func (f *diskFile) Write(p []byte) (int, error) {
	if int64(len(p)) > f.owner.quota-f.owner.used {
		return 0, ErrQuota
	}
	n, e := f.File.Write(p)
	f.owner.used += int64(n)
	f.size += int64(n)
	return n, e
}
func (s *scratch) remove(f *diskFile) error {
	_ = f.Close()
	e := os.Remove(f.Name())
	if e == nil {
		s.used -= f.size
		delete(s.files, f)
	}
	return e
}
func writeContext(ctx context.Context, w io.Writer, p []byte) error {
	for len(p) > 0 {
		if e := ctx.Err(); e != nil {
			return e
		}
		n := min(len(p), 64*1024)
		written, e := w.Write(p[:n])
		if e != nil {
			return e
		}
		if written != n {
			return io.ErrShortWrite
		}
		p = p[n:]
	}
	return nil
}

func (f *diskFile) reopen() error {
	file, e := os.OpenFile(f.Name(), os.O_RDWR, 0600)
	if e != nil {
		return e
	}
	_ = f.Close()
	f.File = file
	return nil
}
