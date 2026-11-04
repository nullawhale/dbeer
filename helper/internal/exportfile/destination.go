package exportfile

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"dbeer/helper/internal/protocol"
)

// Destination contains retained identities, never diagnostic or result data.
type destination struct {
	ctx        context.Context
	path       string
	parent     *os.File
	parentInfo os.FileInfo
	parentReal string
	file       *os.File
	info       os.FileInfo
	stamp      protocol.ExportDestination
}

func CaptureDestination(path string) (protocol.ExportDestination, error) {
	return CaptureDestinationContext(context.Background(), path)
}
func CaptureDestinationContext(ctx context.Context, path string) (protocol.ExportDestination, error) {
	d, err := captureDestinationContext(ctx, path)
	if err != nil {
		return protocol.ExportDestination{}, err
	}
	defer d.close()
	return d.stamp, nil
}
func captureDestination(path string) (*destination, error) {
	return captureDestinationContext(context.Background(), path)
}
func captureDestinationContext(ctx context.Context, path string) (*destination, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if !filepath.IsAbs(path) {
		return nil, ErrIO
	}
	parentPath := filepath.Dir(path)
	real, err := filepath.EvalSymlinks(parentPath)
	if err != nil {
		return nil, ErrIO
	}
	parent, err := openDestinationParent(parentPath)
	if err != nil {
		return nil, ErrIO
	}
	d := &destination{ctx: ctx, path: path, parent: parent, parentReal: real}
	d.parentInfo, err = parent.Stat()
	if err != nil || !d.parentInfo.IsDir() {
		d.close()
		return nil, ErrIO
	}
	parentIdentity, err := fileIdentity(parent)
	if err != nil {
		d.close()
		return nil, ErrIO
	}
	d.stamp.ParentIdentity = &parentIdentity
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		if err := ctx.Err(); err != nil {
			d.close()
			return nil, err
		}
		return d, nil
	}
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		d.close()
		return nil, ErrIO
	}
	d.file, err = openDestination(path)
	if err != nil {
		d.close()
		return nil, ErrIO
	}
	d.info, err = d.file.Stat()
	if err != nil || !os.SameFile(info, d.info) {
		d.close()
		return nil, ErrIO
	}
	hash := sha256.New()
	if _, err = io.Copy(hash, destinationReader{ctx: ctx, in: d.file}); err != nil {
		d.close()
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, ErrIO
	}
	if err := ctx.Err(); err != nil {
		d.close()
		return nil, err
	}
	after, err := d.file.Stat()
	named, nameErr := os.Lstat(path)
	if err != nil || nameErr != nil || !os.SameFile(after, named) || after.Size() != d.info.Size() || !after.ModTime().Equal(d.info.ModTime()) {
		d.close()
		return nil, ErrIO
	}
	modified := strconv.FormatInt(d.info.ModTime().UnixNano(), 10)
	identity, err := fileIdentity(d.file)
	if err != nil {
		d.close()
		return nil, ErrIO
	}
	d.stamp = protocol.ExportDestination{Identity: &identity, ParentIdentity: &parentIdentity, Exists: true, Size: d.info.Size(), SHA256: hex.EncodeToString(hash.Sum(nil)), ModifiedNanoseconds: &modified}
	return d, nil
}
func stampsMatch(a, b protocol.ExportDestination) bool {
	return (b.Identity == nil || a.Identity != nil && *a.Identity == *b.Identity) && (b.ParentIdentity == nil || a.ParentIdentity != nil && *a.ParentIdentity == *b.ParentIdentity) && a.Exists == b.Exists && a.Size == b.Size && a.SHA256 == b.SHA256 && (b.ModifiedNanoseconds == nil || a.ModifiedNanoseconds != nil && *a.ModifiedNanoseconds == *b.ModifiedNanoseconds)
}
func (d *destination) valid() bool {
	if d.ctx.Err() != nil {
		return false
	}
	parent, err := os.Stat(filepath.Dir(d.path))
	if err != nil || !os.SameFile(parent, d.parentInfo) {
		return false
	}
	// Retain the chosen parent resolution; later component retargeting is refused.
	real, err := filepath.EvalSymlinks(filepath.Dir(d.path))
	if err != nil || !samePath(real, d.parentReal) {
		return false
	}
	current, err := captureDestinationContext(d.ctx, d.path)
	if err != nil {
		return false
	}
	defer current.close()
	if d.info != nil && (current.info == nil || !os.SameFile(d.info, current.info) || d.info.Mode() != current.info.Mode()) {
		return false
	}
	return stampsMatch(current.stamp, d.stamp)
}

// Hashes remain cancellable while the retained writer lock is held.
type destinationReader struct {
	ctx context.Context
	in  io.Reader
}

func (reader destinationReader) Read(data []byte) (int, error) {
	if err := reader.ctx.Err(); err != nil {
		return 0, err
	}
	n, err := reader.in.Read(data)
	if cancellation := reader.ctx.Err(); cancellation != nil {
		return n, cancellation
	}
	return n, err
}
func (d *destination) close() {
	if d.file != nil {
		_ = d.file.Close()
	}
	if d.parent != nil {
		_ = d.parent.Close()
	}
}

func samePath(a, b string) bool {
	a, b = filepath.Clean(a), filepath.Clean(b)
	if runtime.GOOS == "windows" {
		a = strings.TrimPrefix(a, `\\?\`)
		b = strings.TrimPrefix(b, `\\?\`)
		return strings.EqualFold(a, b)
	}
	return a == b
}
