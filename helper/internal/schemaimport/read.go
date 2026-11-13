// Package schemaimport validates historical schema sources without connecting
// to a database server or granting permission to execute imported SQL.
package schemaimport

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/schemabundle"
	sc "dbeer/helper/internal/schemacompare"
	"golang.org/x/sys/unix"
)

var ErrInvalid = errors.New("invalid schema source")
var ErrLimit = errors.New("schema source limit")
var ErrChanged = errors.New("schema source changed")
var ErrUnsupported = errors.New("unsupported edited schema definition")

type Imported struct {
	Capture sc.Capture
	Summary schemabundle.ImportedSource
}
type SQLFile struct {
	Path    string
	Ref     *sc.Ref
	SQL     string
	Changed bool
	Missing bool
}
type fileVersion struct {
	info   os.FileInfo
	change any
}
type pinnedDirectory struct {
	file       *os.File
	parent     *os.File
	path       string
	info       os.FileInfo
	parentInfo os.FileInfo
	versions   map[string]fileVersion
	bytes      int64
}

func hash(data []byte) string { v := sha256.Sum256(data); return hex.EncodeToString(v[:]) }
func refKey(r sc.Ref) string  { data, _ := json.Marshal(r); return string(data) }
func changeTime(info os.FileInfo) any {
	v := reflect.ValueOf(info.Sys())
	if v.Kind() == reflect.Pointer && !v.IsNil() {
		v = v.Elem()
	}
	if v.Kind() == reflect.Struct {
		for _, name := range []string{"Ctim", "Ctimespec"} {
			f := v.FieldByName(name)
			if f.IsValid() && f.CanInterface() {
				return f.Interface()
			}
		}
	}
	return nil
}
func sameVersion(before fileVersion, after os.FileInfo) bool {
	return before.info != nil && after != nil && os.SameFile(before.info, after) && before.info.Size() == after.Size() && before.info.ModTime() == after.ModTime() && before.info.Mode() == after.Mode() && reflect.DeepEqual(before.change, changeTime(after))
}
func openDirectory(path string) (*pinnedDirectory, error) {
	path = filepath.Clean(path)
	parentFD, err := unix.Open(filepath.Dir(path), unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, ErrInvalid
	}
	parent := os.NewFile(uintptr(parentFD), "schema parent")
	parentInfo, err := parent.Stat()
	if err != nil || !parentInfo.IsDir() {
		parent.Close()
		return nil, ErrInvalid
	}
	fd, err := unix.Openat(parentFD, filepath.Base(path), unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		parent.Close()
		return nil, ErrInvalid
	}
	f := os.NewFile(uintptr(fd), "schema source")
	info, err := f.Stat()
	if err != nil || !info.IsDir() {
		f.Close()
		parent.Close()
		return nil, ErrInvalid
	}
	return &pinnedDirectory{file: f, parent: parent, parentInfo: parentInfo, path: path, info: info, versions: map[string]fileVersion{}}, nil
}
func leaf(s string) bool {
	return s != "" && s != "." && s != ".." && len(s) <= 255 && utf8.ValidString(s) && !strings.ContainsAny(s, "/\\\x00")
}
func (p *pinnedDirectory) read(ctx context.Context, name string, maximum int64) ([]byte, error) {
	if !leaf(name) || maximum < 0 || maximum > schemabundle.MaxBytes {
		return nil, ErrInvalid
	}
	fd, err := unix.Openat(int(p.file.Fd()), name, unix.O_RDONLY|unix.O_NONBLOCK|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, ErrChanged
	}
	f := os.NewFile(uintptr(fd), "schema file")
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > maximum {
		return nil, ErrLimit
	}
	version := fileVersion{info, changeTime(info)}
	if old, ok := p.versions[name]; ok && !sameVersion(old, info) {
		return nil, ErrChanged
	}
	data := make([]byte, 0, min(info.Size(), 1<<20))
	buffer := make([]byte, 65536)
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		n, err := f.Read(buffer[:min(int64(len(buffer)), maximum-int64(len(data))+1)])
		if n > 0 {
			data = append(data, buffer[:n]...)
			if int64(len(data)) > maximum {
				return nil, ErrLimit
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil || n == 0 {
			return nil, ErrChanged
		}
	}
	after, err := f.Stat()
	if err != nil || !sameVersion(version, after) || int64(len(data)) != info.Size() {
		return nil, ErrChanged
	}
	if _, ok := p.versions[name]; !ok {
		p.bytes += int64(len(data))
		if p.bytes > schemabundle.MaxBytes {
			return nil, ErrLimit
		}
		p.versions[name] = version
	}
	return data, nil
}
func (p *pinnedDirectory) names(ctx context.Context) ([]string, error) {
	fd, err := unix.Openat(int(p.file.Fd()), ".", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, ErrChanged
	}
	f := os.NewFile(uintptr(fd), "schema directory")
	defer f.Close()
	var names []string
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		part, e := f.Readdirnames(256)
		names = append(names, part...)
		if len(names) > schemabundle.MaxObjects+64 {
			return nil, ErrLimit
		}
		if e == io.EOF {
			break
		}
		if e != nil {
			return nil, ErrChanged
		}
	}
	sort.Strings(names)
	return names, nil
}
func (p *pinnedDirectory) check(ctx context.Context, names []string) error {
	parent, err := os.Lstat(filepath.Dir(p.path))
	if err != nil || !parent.IsDir() || !os.SameFile(p.parentInfo, parent) {
		return ErrChanged
	}
	current, err := os.Lstat(p.path)
	if err != nil || !current.IsDir() || !os.SameFile(p.info, current) {
		return ErrChanged
	}
	now, err := p.names(ctx)
	if err != nil || !reflect.DeepEqual(names, now) {
		return ErrChanged
	}
	for name, old := range p.versions {
		if err := ctx.Err(); err != nil {
			return err
		}
		fd, err := unix.Openat(int(p.file.Fd()), name, unix.O_RDONLY|unix.O_NONBLOCK|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if err != nil {
			return ErrChanged
		}
		f := os.NewFile(uintptr(fd), "schema recheck")
		info, err := f.Stat()
		f.Close()
		if err != nil || !sameVersion(old, info) {
			return ErrChanged
		}
	}
	return nil
}
func allowedExtra(name string) bool {
	return name == ".git" || name == ".gitignore" || name == ".gitattributes" || name == ".gitmodules" || name == ".DS_Store" || strings.EqualFold(name, "README") || strings.EqualFold(name, "README.md") || strings.EqualFold(name, "README.txt")
}
func validFile(f schemabundle.File) bool {
	return leaf(f.Path) && f.Bytes >= 0 && f.Bytes <= schemabundle.MaxBytes && schemabundle.DigestValid(f.SHA256)
}

// Read verifies source consistency; hashes establish byte identity, never a
// trusted producer. Definition validation is independent of manifest claims.
func Read(ctx context.Context, source schemabundle.Source, workdir string, render sc.DefinitionRenderer) (Imported, error) {
	var result Imported
	inspecting := source.Engine == "" && source.ManifestSHA256 == "" && source.ContentSHA256 == ""
	if !source.Valid(inspecting) || render == nil {
		return result, ErrInvalid
	}
	p, err := openDirectory(source.Path)
	if err != nil {
		return result, err
	}
	defer p.file.Close()
	defer p.parent.Close()
	names, err := p.names(ctx)
	if err != nil {
		return result, err
	}
	manifestBytes, err := p.read(ctx, "manifest.json", schemabundle.MaxManifestBytes)
	if err != nil {
		return result, err
	}
	if !inspecting && hash(manifestBytes) != source.ManifestSHA256 {
		return result, ErrChanged
	}
	var manifest schemabundle.Manifest
	if err = strictJSON(ctx, manifestBytes, &manifest); err != nil {
		return result, err
	}
	if manifest.FormatVersion != 1 || !schemabundle.SchemasValid(manifest.Engine, manifest.Schemas) || manifest.Capture.ID != "capture" || manifest.Capture.Path != "capture.json" || !validFile(manifest.Capture) || len(manifest.Objects) > schemabundle.MaxObjects {
		return result, ErrInvalid
	}
	if !inspecting && source.Engine != manifest.Engine {
		return result, ErrChanged
	}
	captureBytes, err := p.read(ctx, "capture.json", manifest.Capture.Bytes)
	if err != nil {
		return result, err
	}
	if int64(len(captureBytes)) != manifest.Capture.Bytes || hash(captureBytes) != manifest.Capture.SHA256 {
		return result, ErrInvalid
	}
	var capture sc.Capture
	if err = strictJSON(ctx, captureBytes, &capture); err != nil {
		return result, err
	}
	if capture.Context.Engine != manifest.Engine || capture.Context.Version != "" || capture.Context.Database != "" || capture.Context.StartedAt != "" || capture.Context.FinishedAt != "" || capture.Context.Origin != nil {
		return result, ErrInvalid
	}
	// Rebuild the baseline from typed facts. This proves the manifest's file
	// membership, statuses, original SQL checksums and dependency report agree.
	temporary, err := os.MkdirTemp(workdir, "schema-source-check-")
	if err != nil {
		return result, err
	}
	defer os.RemoveAll(temporary)
	baseline, err := schemabundle.Build(ctx, temporary, capture, manifest.Schemas, render)
	if err != nil {
		return result, ErrInvalid
	}
	defer baseline.Close()
	if !reflect.DeepEqual(baseline.Manifest, manifest) {
		return result, ErrInvalid
	}
	expected := map[string]schemabundle.File{"manifest.json": {ID: "manifest", Path: "manifest.json", Bytes: int64(len(manifestBytes)), SHA256: hash(manifestBytes)}, "capture.json": manifest.Capture}
	refs := map[string]sc.Ref{}
	for _, o := range manifest.Objects {
		if !validFile(o.File) || o.File.Bytes > 128<<10 {
			return result, ErrInvalid
		}
		if _, duplicate := expected[o.File.Path]; duplicate {
			return result, ErrInvalid
		}
		expected[o.File.Path] = o.File
		refs[o.File.Path] = o.Ref
	}
	present := map[string]bool{}
	actual := []schemabundle.File{expected["manifest.json"], expected["capture.json"]}
	files := []SQLFile{}
	modified := 0
	for _, name := range names {
		if allowedExtra(name) {
			continue
		}
		if name == "manifest.json" || name == "capture.json" {
			present[name] = true
			continue
		}
		declared, declaredOK := expected[name]
		if !declaredOK && (!source.AllowSQLChanges || !leaf(name) || !strings.HasSuffix(strings.ToLower(name), ".sql")) {
			return result, ErrInvalid
		}
		data, e := p.read(ctx, name, 128<<10)
		if e != nil {
			return result, e
		}
		if !utf8.Valid(data) || strings.ContainsRune(string(data), 0) {
			return result, ErrInvalid
		}
		current := schemabundle.File{ID: hash([]byte(name)), Path: name, Bytes: int64(len(data)), SHA256: hash(data)}
		actual = append(actual, current)
		present[name] = true
		changed := !declaredOK || current.Bytes != declared.Bytes || current.SHA256 != declared.SHA256
		if changed && !source.AllowSQLChanges {
			return result, ErrInvalid
		}
		file := SQLFile{Path: name, SQL: string(data), Changed: changed}
		if ref, ok := refs[name]; ok {
			file.Ref = &ref
		}
		files = append(files, file)
		if changed {
			modified++
		}
	}
	for path := range expected {
		if present[path] {
			continue
		}
		if !source.AllowSQLChanges || path == "manifest.json" || path == "capture.json" {
			return result, ErrInvalid
		}
		ref := refs[path]
		files = append(files, SQLFile{Path: path, Ref: &ref, Changed: true, Missing: true})
		modified++
	}
	sort.Slice(actual, func(i, j int) bool { return actual[i].Path < actual[j].Path })
	identityBytes, _ := json.Marshal(actual)
	identity := hash(identityBytes)
	if !inspecting && identity != source.ContentSHA256 {
		return result, ErrChanged
	}
	// Restore canonical empty optional collections after JSON decoding; omitted
	// nil and empty arrays have the same portable representation.
	capture, err = schemabundle.Canonical(ctx, capture)
	if err != nil {
		return result, ErrInvalid
	}
	imported, manual, err := importDefinitions(ctx, capture, manifest, files, render)
	if err != nil {
		return result, err
	}
	imported, manual, err = reconcile(ctx, imported)
	if err != nil {
		return result, err
	}
	imported, err = schemabundle.Canonical(ctx, imported)
	if err != nil {
		return result, err
	}
	if err = p.check(ctx, names); err != nil {
		return result, err
	}
	schemas := make([]string, 0, len(imported.Inventories))
	for _, i := range imported.Inventories {
		schemas = append(schemas, i.Schema)
	}
	sort.Strings(schemas)
	label := filepath.Base(p.path)
	if len(label) > 256 {
		label = "Schema bundle"
	}
	result.Capture = imported
	result.Summary = schemabundle.ImportedSource{Source: schemabundle.Source{Path: p.path, AllowSQLChanges: source.AllowSQLChanges, Engine: manifest.Engine, ManifestSHA256: hash(manifestBytes), ContentSHA256: identity}, Label: label, Schemas: schemas, ModifiedSQL: modified, ManualObjects: manual, Complete: manifest.Complete && manual == 0}
	return result, nil
}
