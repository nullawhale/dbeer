package exportfile

import (
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
	path       string
	parent     *os.File
	parentInfo os.FileInfo
	parentReal string
	file       *os.File
	info       os.FileInfo
	stamp      protocol.ExportDestination
}

func CaptureDestination(path string) (protocol.ExportDestination, error) {
	d, err := captureDestination(path)
	if err != nil {
		return protocol.ExportDestination{}, err
	}
	defer d.close()
	return d.stamp, nil
}
func captureDestination(path string) (*destination, error) {
	if !filepath.IsAbs(path) {
		return nil, ErrIO
	}
	parentPath := filepath.Dir(path)
	real, err := filepath.EvalSymlinks(parentPath)
	if err != nil {
		return nil, ErrIO
	}
	parent, err := os.Open(parentPath)
	if err != nil {
		return nil, ErrIO
	}
	d := &destination{path: path, parent: parent, parentReal: real}
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
	if _, err = io.Copy(hash, d.file); err != nil {
		d.close()
		return nil, ErrIO
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
	parent, err := os.Stat(filepath.Dir(d.path))
	if err != nil || !os.SameFile(parent, d.parentInfo) {
		return false
	}
	// Retain the chosen parent resolution; later component retargeting is refused.
	real, err := filepath.EvalSymlinks(filepath.Dir(d.path))
	if err != nil || !samePath(real, d.parentReal) {
		return false
	}
	current, err := captureDestinationUnlocked(d.path)
	if err != nil {
		return false
	}
	defer current.close()
	if d.info != nil && (current.info == nil || !os.SameFile(d.info, current.info) || d.info.Mode() != current.info.Mode()) {
		return false
	}
	return stampsMatch(current.stamp, d.stamp)
}

// Revalidation uses a normal read handle while the retained writer lock remains held.
func captureDestinationUnlocked(path string) (*destination, error) { return captureDestination(path) }
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
