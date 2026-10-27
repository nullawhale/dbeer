// Package resultartifact reads immutable managed result snapshots. It deliberately
// has no protocol dependency: callers choose the managed store, never a wire path.
package resultartifact

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

const (
	DefaultQuotaBytes    int64 = 1 << 30
	MaximumRowBytes            = 16 << 20
	MaximumManifestBytes       = 16 << 20
	maximumSettingsBytes       = 4096
)

var (
	ErrInvalidID   = errors.New("invalid snapshot identifier")
	ErrUnavailable = errors.New("snapshot store is unavailable")
	ErrNotFound    = errors.New("snapshot is no longer available")
	ErrCorrupt     = errors.New("snapshot is damaged or uses an unsupported format")
	ErrClosed      = errors.New("snapshot reader is closed")
)

// Column preserves positional identity, native type, and wire encoding. TypeOID
// is provenance only and cannot establish type equality across database servers.
type Column struct {
	Index        int    `json:"index"`
	Name         string `json:"name"`
	Engine       string `json:"engine"`
	NativeType   string `json:"nativeType"`
	TypeIdentity string `json:"typeIdentity,omitempty"`
	TypeOID      uint32 `json:"typeOid"`
	Encoding     string `json:"encoding,omitempty"`
}

type Metadata struct {
	Version        int
	ID             string
	Title          string
	CapturedAt     float64
	Engine         string
	SQL            string
	ProfileID      *string
	ProfileName    *string
	Environment    string
	Outcome        string
	Columns        []Column
	RowCount       int64
	SourceRowCount *int64
	Truncated      bool
	Partial        bool
	CommandTag     string
	RowsBytes      int64
	RowsSHA256     string
}

func (m Metadata) Complete() bool {
	return !m.Truncated && !m.Partial && m.Outcome == "succeeded" &&
		(m.SourceRowCount == nil || *m.SourceRowCount == m.RowCount)
}

func (m Metadata) IsComplete() bool { return m.Complete() }

// RowRef identifies an encoded row in the pinned file. Digest authenticates both
// coordinates and bytes for this open reader, permitting bounded disk indexes
// without granting the ability to read arbitrary offsets or other artifacts.
type RowRef struct {
	Index  int64
	Offset int64
	Length int
	Digest [sha256.Size]byte
}

// Artifact is reusable and safe for concurrent reads. A successful Scan verifies
// the entire stream; callers must discard a scan's output when it returns an
// error. RowRef values remain valid until Close. Callbacks must not call Close.
type Artifact interface {
	Metadata() Metadata
	Scan(context.Context, func(RowRef, []*string) error) error
	ReadRow(context.Context, RowRef) ([]*string, error)
	Close() error
}

type Store struct{ root string }

// NewStore injects a trusted managed root for tests and internal callers. This
// path must never come from a comparison protocol request.
func NewStore(root string) *Store { return &Store{root: root} }

func DefaultRoot() (string, error) {
	root, err := os.UserConfigDir()
	if err != nil {
		return "", ErrUnavailable
	}
	return filepath.Join(root, "DBeer", "Snapshots"), nil
}

func NewDefaultStore() (*Store, error) {
	root, err := DefaultRoot()
	if err != nil {
		return nil, err
	}
	return NewStore(root), nil
}

// ValidID accepts only the canonical lower-case UUID directory spelling.
func ValidID(id string) bool {
	if len(id) != 36 {
		return false
	}
	for index, character := range []byte(id) {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			if character != '-' {
				return false
			}
		} else if !(character >= '0' && character <= '9' || character >= 'a' && character <= 'f') {
			return false
		}
	}
	return true
}

func (s *Store) Open(ctx context.Context, id string) (Artifact, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if !ValidID(id) {
		return nil, ErrInvalidID
	}
	if s == nil || !filepath.IsAbs(s.root) || filepath.Clean(s.root) == string(filepath.Separator) || strings.ContainsRune(s.root, 0) {
		return nil, ErrUnavailable
	}
	root, err := openManagedRoot(s.root)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	quota, err := readQuota(ctx, root)
	if err != nil {
		return nil, err
	}
	directory, err := openArtifactDirectory(root, id)
	if err != nil {
		return nil, err
	}
	defer directory.Close()
	if err := checkArtifactEntries(directory); err != nil {
		return nil, err
	}
	manifest, manifestInfo, err := openRegular(directory, "manifest.json")
	if err != nil {
		return nil, err
	}
	defer manifest.Close()
	if manifestInfo.Size() <= 0 || manifestInfo.Size() > MaximumManifestBytes || manifestInfo.Size() > quota {
		return nil, ErrCorrupt
	}
	data, err := readBounded(ctx, manifest, manifestInfo.Size())
	if err != nil {
		return nil, err
	}
	if err := unchanged(manifest, manifestInfo); err != nil {
		return nil, err
	}
	metadata, err := decodeManifest(data, id)
	if err != nil {
		return nil, err
	}
	if metadata.RowsBytes > quota-manifestInfo.Size() {
		return nil, ErrCorrupt
	}
	rows, rowsInfo, err := openRegular(directory, "rows.jsonl")
	if err != nil {
		return nil, err
	}
	if rowsInfo.Size() != metadata.RowsBytes {
		rows.Close()
		return nil, ErrCorrupt
	}
	r := &reader{file: rows, info: rowsInfo, metadata: metadata}
	if _, err := rand.Read(r.key[:]); err != nil {
		rows.Close()
		return nil, ErrUnavailable
	}
	if err := r.Scan(ctx, nil); err != nil {
		r.Close()
		return nil, err
	}
	if err := checkArtifactEntries(directory); err != nil {
		r.Close()
		return nil, err
	}
	return r, nil
}

func readQuota(ctx context.Context, root *os.Root) (int64, error) {
	file, info, err := openRegular(root, "settings.json")
	if errors.Is(err, ErrNotFound) {
		return DefaultQuotaBytes, nil
	}
	if err != nil {
		return 0, err
	}
	defer file.Close()
	if info.Size() <= 0 || info.Size() > maximumSettingsBytes {
		return 0, ErrCorrupt
	}
	data, err := readBounded(ctx, file, info.Size())
	if err != nil {
		return 0, err
	}
	if err := unchanged(file, info); err != nil {
		return 0, err
	}
	object, err := decodeObject(data)
	var version int
	var quota int64
	if err != nil || !decodeRequired(object, "version", &version) || version != 1 ||
		!decodeRequired(object, "quotaBytes", &quota) || quota < 1 {
		return 0, ErrCorrupt
	}
	return quota, nil
}

type reader struct {
	mu       sync.RWMutex
	file     *os.File
	info     os.FileInfo
	metadata Metadata
	key      [sha256.Size]byte
}

func (r *reader) Metadata() Metadata {
	// A caller cannot change subsequent validation by mutating a returned slice.
	m := r.metadata
	m.Columns = append([]Column(nil), m.Columns...)
	if m.SourceRowCount != nil {
		value := *m.SourceRowCount
		m.SourceRowCount = &value
	}
	if m.ProfileID != nil {
		value := *m.ProfileID
		m.ProfileID = &value
	}
	if m.ProfileName != nil {
		value := *m.ProfileName
		m.ProfileName = &value
	}
	return m
}

func (r *reader) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.file == nil {
		return nil
	}
	err := r.file.Close()
	r.file = nil
	if err != nil {
		return ErrUnavailable
	}
	return nil
}

func (r *reader) Scan(ctx context.Context, visit func(RowRef, []*string) error) error {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if r.file == nil {
		return ErrClosed
	}
	if err := unchanged(r.file, r.info); err != nil {
		return err
	}
	section := io.NewSectionReader(r.file, 0, r.metadata.RowsBytes)
	input := bufio.NewReaderSize(contextReader{ctx, section}, 64<<10)
	digest := sha256.New()
	var index, offset int64
	for {
		line, err := readRowLine(input)
		if err == io.EOF {
			break
		}
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return ErrCorrupt
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if index >= r.metadata.RowCount {
			return ErrCorrupt
		}
		row, err := decodeRow(line[:len(line)-1], r.metadata.Columns)
		if err != nil {
			return err
		}
		digest.Write(line)
		if visit != nil {
			ref := RowRef{Index: index, Offset: offset, Length: len(line)}
			ref.Digest = r.rowDigest(ref, line)
			if err := visit(ref, row); err != nil {
				return err
			}
		}
		offset += int64(len(line))
		index++
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if offset != r.metadata.RowsBytes || index != r.metadata.RowCount || hex.EncodeToString(digest.Sum(nil)) != r.metadata.RowsSHA256 {
		return ErrCorrupt
	}
	return unchanged(r.file, r.info)
}

func (r *reader) ReadRow(ctx context.Context, ref RowRef) ([]*string, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if r.file == nil {
		return nil, ErrClosed
	}
	if ref.Index < 0 || ref.Index >= r.metadata.RowCount || ref.Length < 2 || ref.Length > MaximumRowBytes+1 ||
		ref.Offset < 0 || int64(ref.Length) > r.metadata.RowsBytes || ref.Offset > r.metadata.RowsBytes-int64(ref.Length) {
		return nil, ErrCorrupt
	}
	if err := unchanged(r.file, r.info); err != nil {
		return nil, err
	}
	data, err := readBounded(ctx, io.NewSectionReader(r.file, ref.Offset, int64(ref.Length)), int64(ref.Length))
	if err != nil {
		return nil, err
	}
	digest := r.rowDigest(ref, data)
	if !hmac.Equal(digest[:], ref.Digest[:]) || data[len(data)-1] != '\n' {
		return nil, ErrCorrupt
	}
	row, err := decodeRow(data[:len(data)-1], r.metadata.Columns)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := unchanged(r.file, r.info); err != nil {
		return nil, err
	}
	return row, nil
}

func (r *reader) rowDigest(ref RowRef, data []byte) [sha256.Size]byte {
	digest := hmac.New(sha256.New, r.key[:])
	var coordinates [24]byte
	binary.BigEndian.PutUint64(coordinates[:8], uint64(ref.Index))
	binary.BigEndian.PutUint64(coordinates[8:16], uint64(ref.Offset))
	binary.BigEndian.PutUint64(coordinates[16:], uint64(ref.Length))
	digest.Write(coordinates[:])
	digest.Write(data)
	var result [sha256.Size]byte
	copy(result[:], digest.Sum(nil))
	return result
}

func readRowLine(input *bufio.Reader) ([]byte, error) {
	var line []byte
	for {
		fragment, err := input.ReadSlice('\n')
		if len(line)+len(fragment) > MaximumRowBytes+1 {
			return nil, ErrCorrupt
		}
		if len(line) == 0 && err == nil {
			return fragment, nil
		}
		line = append(line, fragment...)
		if err == nil {
			return line, nil
		}
		if err == io.EOF && len(line) == 0 {
			return nil, io.EOF
		}
		if err != bufio.ErrBufferFull {
			return nil, ErrCorrupt
		}
	}
}

type contextReader struct {
	ctx context.Context
	io.Reader
}

func (r contextReader) Read(data []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.Reader.Read(data)
}

func readBounded(ctx context.Context, input io.Reader, size int64) ([]byte, error) {
	if size < 0 || size > MaximumManifestBytes+1 {
		return nil, ErrCorrupt
	}
	data := make([]byte, int(size))
	for offset := 0; offset < len(data); {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		count, err := io.ReadFull(input, data[offset:min(offset+(64<<10), len(data))])
		if err != nil {
			return nil, ErrCorrupt
		}
		offset += count
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var extra [1]byte
	if count, err := input.Read(extra[:]); count != 0 || err != io.EOF {
		return nil, ErrCorrupt
	}
	return data, nil
}
