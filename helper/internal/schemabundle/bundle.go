// Package schemabundle retains reproducible, scoped schema files for explicit export.
package schemabundle

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"reflect"
	"sort"
	"strings"
	"unicode/utf8"

	sc "dbeer/helper/internal/schemacompare"
	"golang.org/x/sys/unix"
)

const Version = 1
const MaxBytes int64 = 128 << 20
const MaxManifestBytes int64 = 8 << 20
const MaxObjects = 10000

var ErrInvalid = errors.New("invalid schema bundle")
var ErrLimit = errors.New("schema bundle limit")

type File struct {
	ID     string `json:"id"`
	Path   string `json:"path"`
	Bytes  int64  `json:"bytes"`
	SHA256 string `json:"sha256"`
}
type Dependency struct {
	Ref   sc.Ref `json:"ref"`
	State string `json:"state"`
}
type Object struct {
	Ref          sc.Ref       `json:"ref"`
	File         File         `json:"file"`
	State        string       `json:"state"`
	ReasonCodes  []string     `json:"reasonCodes"`
	Dependencies []Dependency `json:"dependencies"`
}
type Manifest struct {
	FormatVersion       int        `json:"formatVersion"`
	Engine              string     `json:"engine"`
	Schemas             []string   `json:"schemas"`
	Scope               string     `json:"scope"`
	ExcludedObjectKinds []string   `json:"excludedObjectKinds"`
	Capture             File       `json:"capture"`
	Objects             []Object   `json:"objects"`
	Issues              []sc.Issue `json:"issues"`
	Complete            bool       `json:"complete"`
}
type Summary struct {
	FormatVersion int      `json:"formatVersion"`
	Engine        string   `json:"engine"`
	Schemas       []string `json:"schemas"`
	Manifest      File     `json:"manifest"`
	Included      int      `json:"included"`
	Omitted       int      `json:"omitted"`
	Incomplete    int      `json:"incomplete"`
	TotalBytes    int64    `json:"totalBytes"`
}
type Result struct {
	Summary      Summary
	Manifest     Manifest
	files        map[string]os.FileInfo
	descriptions map[string]File
	directory    *os.File
	totalBytes   int64
}

func digest(b []byte) string   { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func refKey(ref sc.Ref) string { b, _ := json.Marshal(ref); return string(b) }
func id(ref sc.Ref) string     { return digest([]byte(refKey(ref))) }
func Supported(engine string) bool {
	return engine == "postgresql" || engine == "mysql" || engine == "mariadb" || engine == "sqlite"
}
func SchemasValid(engine string, schemas []string) bool {
	if !Supported(engine) || len(schemas) < 1 || len(schemas) > 32 {
		return false
	}
	seen := map[string]bool{}
	for _, s := range schemas {
		if !sc.ValidName(s) || seen[s] {
			return false
		}
		seen[s] = true
	}
	return engine != "sqlite" || len(schemas) == 1 && schemas[0] == "main"
}
func safePrefix(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
		if b.Len() >= 20 {
			break
		}
	}
	if b.Len() == 0 {
		return "object"
	}
	return b.String()
}
func objectPath(ref sc.Ref) string {
	return ref.Kind + "-" + safePrefix(ref.Name) + "-" + id(ref) + ".sql"
}
func jsonBytes(v any) ([]byte, error) {
	b, e := json.MarshalIndent(v, "", "  ")
	return append(b, '\n'), e
}

// Build owns only private helper files. Publication into a selected directory is
// a separate native operation, after every declared byte has been verified.
func Build(ctx context.Context, dir string, capture sc.Capture, schemas []string, render sc.DefinitionRenderer) (_ *Result, err error) {
	if !SchemasValid(capture.Context.Engine, schemas) || render == nil {
		return nil, ErrInvalid
	}
	c, err := Canonical(ctx, capture)
	if err != nil {
		return nil, err
	}
	selected := append([]string(nil), schemas...)
	sort.Strings(selected)
	selectedSet := map[string]bool{}
	for _, s := range selected {
		selectedSet[s] = true
	}
	inventories := map[string]bool{}
	for _, inventory := range c.Inventories {
		if !selectedSet[inventory.Schema] || inventories[inventory.Schema] {
			return nil, ErrInvalid
		}
		inventories[inventory.Schema] = true
	}
	if len(inventories) != len(selected) {
		return nil, ErrInvalid
	}
	descriptor, e := unix.Open(dir, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if e != nil {
		return nil, e
	}
	r := &Result{files: map[string]os.FileInfo{}, descriptions: map[string]File{}, directory: os.NewFile(uintptr(descriptor), "bundle")}
	defer func() {
		if err != nil {
			_ = r.Close()
		}
	}()
	r.Manifest = Manifest{FormatVersion: Version, Engine: c.Context.Engine, Schemas: selected, Scope: "supportedSchemaDefinitions", ExcludedObjectKinds: []string{"views", "routines", "triggers", "privileges", "statistics", "physicalContents", "sequenceCounters", "autoIncrementCounters"}, Objects: []Object{}, Issues: c.Issues, Complete: c.Context.Visibility == "complete"}
	if c.Context.Engine == "sqlite" {
		r.Manifest.ExcludedObjectKinds = []string{"views", "routines", "privileges", "statistics", "physicalContents", "sequenceCounters", "autoIncrementCounters"}
	}
	captures, err := jsonBytes(c)
	if err != nil {
		return nil, err
	}
	if r.Manifest.Capture, err = r.add(ctx, "capture", "capture.json", captures); err != nil {
		return nil, err
	}
	type root struct {
		ref     sc.Ref
		value   any
		missing bool
	}
	roots := []root{}
	for _, i := range c.Inventories {
		roots = append(roots, root{ref: sc.Ref{Kind: "schema", Name: i.Schema}, value: i})
	}
	for _, t := range c.Tables {
		if !selectedSet[t.Ref.Schema] {
			continue
		}
		roots = append(roots, root{ref: t.Ref, value: t})
	}
	for _, t := range c.Types {
		if t.Ref.RowType || !selectedSet[t.Ref.Schema] {
			continue
		}
		roots = append(roots, root{ref: t.Ref, value: t})
	}
	for _, s := range c.Sequences {
		if !selectedSet[s.Ref.Schema] {
			continue
		}
		roots = append(roots, root{ref: s.Ref, value: s})
	}
	available := map[string]bool{}
	for _, root := range roots {
		available[refKey(root.ref)] = true
	}
	for _, inventory := range c.Inventories {
		for _, refs := range [][]sc.Ref{inventory.Tables.Items, inventory.Types.Items} {
			for _, ref := range refs {
				if ref.RowType {
					continue
				}
				if !available[refKey(ref)] {
					roots = append(roots, root{ref: ref, value: ref, missing: true})
					available[refKey(ref)] = true
				}
			}
		}
	}
	if len(roots) > MaxObjects {
		return nil, ErrLimit
	}
	sort.Slice(roots, func(i, j int) bool { return refKey(roots[i].ref) < refKey(roots[j].ref) })
	present := map[string]int{}
	definitions := make([]string, len(roots))
	for _, root := range roots {
		if e := ctx.Err(); e != nil {
			return nil, e
		}
		ref := root.ref
		if !validRoot(ref, selected) {
			return nil, ErrInvalid
		}
		key := refKey(ref)
		if _, ok := present[key]; ok {
			return nil, ErrInvalid
		}
		present[key] = len(r.Manifest.Objects)
		definition, e := render(ctx, c, ref)
		if e != nil {
			return nil, e
		}
		object := Object{Ref: ref, State: "included", ReasonCodes: []string{}, Dependencies: []Dependency{}}
		if definition.Limited || len(definition.SQL) > 128<<10 || strings.TrimSpace(definition.SQL) == "" {
			object.State = "omitted"
			object.ReasonCodes = append(object.ReasonCodes, "definitionUnsupported")
		}
		if root.missing {
			object.State = "incomplete"
			object.ReasonCodes = append(object.ReasonCodes, "metadataMissing")
		}
		if incomplete(reflect.ValueOf(root.value)) {
			object.State = "incomplete"
			object.ReasonCodes = append(object.ReasonCodes, "metadataIncomplete")
		}
		for _, issue := range c.Issues {
			if issue.BlocksEquality && (issue.Ref == nil || rootRef(*issue.Ref) == ref) {
				object.State = "incomplete"
				object.ReasonCodes = append(object.ReasonCodes, "captureIssue")
				break
			}
		}
		refs := map[string]sc.Ref{}
		collectRefs(reflect.ValueOf(root.value), refs)
		for _, dependency := range refs {
			target := rootRef(dependency)
			if target == ref || target.Kind == "schema" || target.Name == "" {
				continue
			}
			object.Dependencies = append(object.Dependencies, Dependency{Ref: target})
		}
		sort.Slice(object.Dependencies, func(i, j int) bool { return refKey(object.Dependencies[i].Ref) < refKey(object.Dependencies[j].Ref) })
		r.Manifest.Objects = append(r.Manifest.Objects, object)
		definitions[len(r.Manifest.Objects)-1] = definition.SQL
	}
	// Resolve the closure before writing any executable file. A complete renderer
	// cannot conceal a missing user function/type or an omitted dependency.
	for changed := true; changed; {
		changed = false
		for i := range r.Manifest.Objects {
			o := &r.Manifest.Objects[i]
			if o.State != "included" {
				continue
			}
			for _, d := range o.Dependencies {
				target, ok := present[refKey(d.Ref)]
				if builtin(c.Context.Engine, d.Ref) {
					continue
				}
				if !ok || r.Manifest.Objects[target].State != "included" {
					o.State = "incomplete"
					o.ReasonCodes = append(o.ReasonCodes, "dependencyNotIncluded")
					changed = true
					break
				}
			}
		}
	}
	for i := range r.Manifest.Objects {
		o := &r.Manifest.Objects[i]
		for j := range o.Dependencies {
			d := &o.Dependencies[j]
			if builtin(c.Context.Engine, d.Ref) {
				d.State = "builtin"
			} else if index, ok := present[refKey(d.Ref)]; ok {
				d.State = r.Manifest.Objects[index].State
			} else {
				d.State = "external"
			}
		}
		sort.Strings(o.ReasonCodes)
		o.ReasonCodes = unique(o.ReasonCodes)
		sql := definitions[i]
		if o.State != "included" {
			sql = "-- This definition is omitted. Review manifest.json for its status and dependencies.\n"
			r.Manifest.Complete = false
		}
		if !utf8.ValidString(sql) || strings.ContainsRune(sql, 0) {
			return nil, ErrInvalid
		}
		if o.File, err = r.add(ctx, id(o.Ref), objectPath(o.Ref), []byte(sql)); err != nil {
			return nil, err
		}
	}
	manifest, err := jsonBytes(r.Manifest)
	if err != nil {
		return nil, err
	}
	if int64(len(manifest)) > MaxManifestBytes {
		return nil, ErrLimit
	}
	manifestFile, err := r.add(ctx, "manifest", "manifest.json", manifest)
	if err != nil {
		return nil, err
	}
	r.Summary = Summary{FormatVersion: Version, Engine: c.Context.Engine, Schemas: selected, Manifest: manifestFile}
	for _, o := range r.Manifest.Objects {
		switch o.State {
		case "included":
			r.Summary.Included++
		case "omitted":
			r.Summary.Omitted++
		case "incomplete":
			r.Summary.Incomplete++
		}
	}
	for _, f := range r.descriptions {
		r.Summary.TotalBytes += f.Bytes
	}
	return r, nil
}
func (r *Result) add(ctx context.Context, id, path string, b []byte) (File, error) {
	if e := ctx.Err(); e != nil {
		return File{}, e
	}
	if int64(len(b)) > MaxBytes-r.totalBytes {
		return File{}, ErrLimit
	}
	if _, ok := r.files[id]; ok {
		return File{}, ErrInvalid
	}
	descriptor, e := unix.Openat(int(r.directory.Fd()), path, unix.O_CREAT|unix.O_EXCL|unix.O_WRONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0600)
	if e != nil {
		return File{}, e
	}
	f := os.NewFile(uintptr(descriptor), path)
	defer f.Close()
	for offset := 0; offset < len(b); {
		if e = ctx.Err(); e != nil {
			return File{}, e
		}
		n, writeErr := f.Write(b[offset:min(len(b), offset+65536)])
		if writeErr != nil {
			return File{}, writeErr
		}
		if n == 0 {
			return File{}, io.ErrShortWrite
		}
		offset += n
	}
	info, e := f.Stat()
	if e != nil {
		return File{}, e
	}
	r.files[id] = info
	r.totalBytes += int64(len(b))
	desc := File{id, path, int64(len(b)), digest(b)}
	r.descriptions[id] = desc
	return desc, nil
}
func (r *Result) Chunk(ctx context.Context, id string, offset int64, maxBytes int) (sc.Chunk, error) {
	desc, ok := r.descriptions[id]
	if !ok || r.directory == nil || r.files[id] == nil || offset < 0 || offset > desc.Bytes || maxBytes < 1 || maxBytes > 1<<20 {
		return sc.Chunk{}, ErrInvalid
	}
	if e := ctx.Err(); e != nil {
		return sc.Chunk{}, e
	}
	b := make([]byte, min(int64(maxBytes), desc.Bytes-offset))
	descriptor, e := unix.Openat(int(r.directory.Fd()), desc.Path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if e != nil {
		return sc.Chunk{}, e
	}
	f := os.NewFile(uintptr(descriptor), desc.Path)
	defer f.Close()
	info, e := f.Stat()
	if e != nil || !info.Mode().IsRegular() || !os.SameFile(r.files[id], info) || info.Size() != desc.Bytes {
		return sc.Chunk{}, ErrInvalid
	}
	n, e := f.ReadAt(b, offset)
	if e != nil && e != io.EOF {
		return sc.Chunk{}, e
	}
	if n != len(b) {
		return sc.Chunk{}, io.ErrUnexpectedEOF
	}
	return sc.Chunk{ValueRef: id, SHA256: desc.SHA256, TotalBytes: desc.Bytes, Offset: offset, NextOffset: offset + int64(n), DataBase64: base64.StdEncoding.EncodeToString(b), HasMore: offset+int64(n) < desc.Bytes}, nil
}
func (r *Result) Close() error {
	if r.directory != nil {
		err := r.directory.Close()
		r.directory = nil
		r.files = nil
		return err
	}
	return nil
}

func unique(v []string) []string {
	out := v[:0]
	for _, s := range v {
		if len(out) == 0 || out[len(out)-1] != s {
			out = append(out, s)
		}
	}
	return out
}
func validRoot(ref sc.Ref, schemas []string) bool {
	if ref.Table != "" || ref.RowType || !sc.ValidName(ref.Name) {
		return false
	}
	if ref.Kind == "schema" {
		for _, s := range schemas {
			if ref.Schema == "" && ref.Name == s {
				return true
			}
		}
		return false
	}
	if ref.Kind != "table" && ref.Kind != "type" && ref.Kind != "sequence" {
		return false
	}
	for _, s := range schemas {
		if ref.Schema == s {
			return true
		}
	}
	return false
}
func builtin(engine string, ref sc.Ref) bool {
	switch engine {
	case "postgresql":
		return ref.Schema == "pg_catalog" || ref.Schema == "information_schema"
	case "mysql", "mariadb":
		return ref.Schema == "" && (ref.Kind == "type" || ref.Kind == "collation")
	case "sqlite":
		return ref.Schema == "sqlite" && ref.Kind == "type"
	}
	return false
}

func rootRef(ref sc.Ref) sc.Ref {
	if ref.Table != "" {
		return sc.Ref{Kind: "table", Schema: ref.Schema, Name: ref.Table}
	}
	if ref.RowType {
		return sc.Ref{Kind: "table", Schema: ref.Schema, Name: ref.Name}
	}
	return ref
}
func collectRefs(v reflect.Value, out map[string]sc.Ref) {
	if v.Kind() == reflect.Pointer {
		if !v.IsNil() {
			collectRefs(v.Elem(), out)
		}
		return
	}
	if v.Type() == reflect.TypeFor[sc.Ref]() {
		ref := rootRef(v.Interface().(sc.Ref))
		out[refKey(ref)] = ref
		return
	}
	switch v.Kind() {
	case reflect.Struct:
		for i := 0; i < v.NumField(); i++ {
			collectRefs(v.Field(i), out)
		}
	case reflect.Slice:
		for i := 0; i < v.Len(); i++ {
			collectRefs(v.Index(i), out)
		}
	}
}
func incomplete(v reflect.Value) bool {
	if v.Kind() == reflect.Pointer {
		if v.IsNil() {
			return false
		}
		return incomplete(v.Elem())
	}
	switch v.Kind() {
	case reflect.Struct:
		if f := v.FieldByName("State"); factOrCollection(v) && f.IsValid() && f.Kind() == reflect.String && f.String() != "known" {
			return true
		}
		if f := v.FieldByName("Complete"); f.IsValid() && f.Kind() == reflect.Bool && !f.Bool() {
			return true
		}
		for i := 0; i < v.NumField(); i++ {
			if incomplete(v.Field(i)) {
				return true
			}
		}
	case reflect.Slice:
		for i := 0; i < v.Len(); i++ {
			if incomplete(v.Index(i)) {
				return true
			}
		}
	}
	return false
}
