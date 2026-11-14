package schemabundle

import (
	"bytes"
	"encoding/json"
	"io"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// Source identifies bytes selected by the user, not an authenticated producer.
// Inspection fills Engine and both digests. Comparison requires all three and
// independently validates the files again before retaining a historical source.
type Source struct {
	Path            string `json:"path"`
	AllowSQLChanges bool   `json:"allowSQLChanges"`
	Engine          string `json:"engine,omitempty"`
	ManifestSHA256  string `json:"manifestSha256,omitempty"`
	ContentSHA256   string `json:"contentSha256,omitempty"`
}

func DigestValid(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range []byte(s) {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func (s Source) Valid(inspect bool) bool {
	if !utf8.ValidString(s.Path) || len(s.Path) > 4096 || !filepath.IsAbs(s.Path) || strings.ContainsRune(s.Path, 0) || strings.HasPrefix(s.Path, "file:") {
		return false
	}
	if inspect {
		return s.Engine == "" && s.ManifestSHA256 == "" && s.ContentSHA256 == ""
	}
	return Supported(s.Engine) && DigestValid(s.ManifestSHA256) && DigestValid(s.ContentSHA256)
}

type ImportedSource struct {
	Source        Source   `json:"source"`
	Label         string   `json:"label"`
	Schemas       []string `json:"schemas"`
	ModifiedSQL   int      `json:"modifiedSQL"`
	ManualObjects int      `json:"manualObjects"`
	Complete      bool     `json:"complete"`
}

// UnmarshalJSON rejects duplicate, case-aliased and null fields before typed decoding.
func (s *Source) UnmarshalJSON(raw []byte) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	t, e := d.Token()
	if e != nil || t != json.Delim('{') {
		return ErrInvalid
	}
	fields := map[string]json.RawMessage{}
	allowed := map[string]bool{"path": true, "allowSQLChanges": true, "engine": true, "manifestSha256": true, "contentSha256": true}
	for d.More() {
		t, e = d.Token()
		name, ok := t.(string)
		if e != nil || !ok || !allowed[name] || fields[name] != nil {
			return ErrInvalid
		}
		var value json.RawMessage
		if d.Decode(&value) != nil || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return ErrInvalid
		}
		fields[name] = value
	}
	if t, e = d.Token(); e != nil || t != json.Delim('}') {
		return ErrInvalid
	}
	if _, e = d.Token(); e != io.EOF {
		return ErrInvalid
	}
	if fields["path"] == nil || fields["allowSQLChanges"] == nil {
		return ErrInvalid
	}
	type plain Source
	var value plain
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&value) != nil {
		return ErrInvalid
	}
	*s = Source(value)
	if len(fields) != 2 && len(fields) != 5 {
		return ErrInvalid
	}
	if !s.Valid(len(fields) == 2) {
		return ErrInvalid
	}
	return nil
}
