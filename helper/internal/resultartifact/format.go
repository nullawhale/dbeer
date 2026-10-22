package resultartifact

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"math"
	"strings"
	"unicode/utf8"
)

func decodeManifest(data []byte, id string) (Metadata, error) {
	object, err := decodeObject(data)
	if err != nil {
		return Metadata{}, err
	}
	var m Metadata
	if !decodeRequired(object, "version", &m.Version) || m.Version != 1 ||
		!decodeRequired(object, "id", &m.ID) || strings.ToLower(m.ID) != id ||
		!decodeRequired(object, "title", &m.Title) || strings.TrimSpace(m.Title) == "" || len(m.Title) > 4096 ||
		!decodeRequired(object, "capturedAt", &m.CapturedAt) || math.IsInf(m.CapturedAt, 0) || math.IsNaN(m.CapturedAt) ||
		!decodeRequired(object, "engine", &m.Engine) || !validEngine(m.Engine) ||
		!decodeRequired(object, "sql", &m.SQL) || len(m.SQL) > MaximumManifestBytes/2 ||
		!decodeRequired(object, "environment", &m.Environment) || !oneOf(m.Environment, "unspecified", "development", "staging", "production") ||
		!decodeRequired(object, "outcome", &m.Outcome) || !oneOf(m.Outcome, "succeeded", "failed", "cancelled", "timedOut", "unknown") ||
		!decodeRequired(object, "rowCount", &m.RowCount) || m.RowCount < 0 ||
		!decodeRequired(object, "truncated", &m.Truncated) || !decodeRequired(object, "partial", &m.Partial) ||
		!decodeRequired(object, "commandTag", &m.CommandTag) || len(m.CommandTag) > 4096 ||
		!decodeRequired(object, "rowsBytes", &m.RowsBytes) || m.RowsBytes < 0 ||
		!decodeRequired(object, "rowsSHA256", &m.RowsSHA256) || !validDigest(m.RowsSHA256) ||
		!decodeOptional(object, "sourceRowCount", &m.SourceRowCount) ||
		!decodeOptional(object, "profileID", &m.ProfileID) || !decodeOptional(object, "profileName", &m.ProfileName) ||
		m.SourceRowCount != nil && *m.SourceRowCount < m.RowCount ||
		m.ProfileID != nil && !ValidID(strings.ToLower(*m.ProfileID)) ||
		m.ProfileName != nil && len(*m.ProfileName) > 4096 {
		return Metadata{}, ErrCorrupt
	}
	m.ID = id
	if m.Columns, err = decodeColumns(object["columns"]); err != nil {
		return Metadata{}, err
	}
	return m, nil
}

func decodeColumns(data []byte) ([]Column, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('[') {
		return nil, ErrCorrupt
	}
	columns := make([]Column, 0)
	for decoder.More() {
		if len(columns) >= 65_536 {
			return nil, ErrCorrupt
		}
		var raw json.RawMessage
		if decoder.Decode(&raw) != nil {
			return nil, ErrCorrupt
		}
		column, err := decodeColumn(raw, len(columns))
		if err != nil {
			return nil, err
		}
		columns = append(columns, column)
	}
	if token, err := decoder.Token(); err != nil || token != json.Delim(']') {
		return nil, ErrCorrupt
	}
	return columns, nil
}

func decodeColumn(data []byte, index int) (Column, error) {
	object, err := decodeObject(data)
	if err != nil {
		return Column{}, err
	}
	c := Column{Engine: "postgresql"}
	if !decodeRequired(object, "index", &c.Index) || c.Index != index ||
		!decodeRequired(object, "name", &c.Name) || len(c.Name) > 65_536 {
		return Column{}, ErrCorrupt
	}
	// These defaults match Swift's legacy-compatible ResultColumn decoder.
	var engine, nativeType, encoding *string
	var typeOID *uint32
	if !decodeOptional(object, "engine", &engine) || !decodeOptional(object, "nativeType", &nativeType) ||
		!decodeOptional(object, "typeOid", &typeOID) || !decodeOptional(object, "encoding", &encoding) {
		return Column{}, ErrCorrupt
	}
	if engine != nil {
		c.Engine = *engine
	}
	if nativeType != nil {
		c.NativeType = *nativeType
	}
	if typeOID != nil {
		c.TypeOID = *typeOID
	}
	if encoding != nil {
		if *encoding != "base64" {
			return Column{}, ErrCorrupt
		}
		c.Encoding = *encoding
	}
	if !validEngine(c.Engine) || len(c.NativeType) > 65_536 {
		return Column{}, ErrCorrupt
	}
	return c, nil
}

func decodeRow(data []byte, columns []Column) ([]*string, error) {
	trimmed := bytes.TrimSpace(data)
	if len(data) == 0 || len(data) > MaximumRowBytes || len(trimmed) == 0 || trimmed[0] != '[' || !validJSONText(data) {
		return nil, ErrCorrupt
	}
	// Reject an oversized positional array before decoding its elements. The
	// declared width is at most 65,536 even if a damaged 16 MiB line contains
	// millions of JSON nulls; never allocate an array sized by that input.
	if rowWidth(trimmed) != len(columns) {
		return nil, ErrCorrupt
	}
	var row []*string
	if json.Unmarshal(data, &row) != nil {
		return nil, ErrCorrupt
	}
	for index, value := range row {
		if value == nil || columns[index].Encoding != "base64" {
			continue
		}
		// Decode through a small scratch buffer, rather than allocating another
		// large value. Foundation rejects whitespace in base64 payload strings.
		if strings.ContainsAny(*value, "\r\n") {
			return nil, ErrCorrupt
		}
		decoder := base64.NewDecoder(base64.StdEncoding, strings.NewReader(*value))
		if _, err := io.Copy(io.Discard, decoder); err != nil {
			return nil, ErrCorrupt
		}
	}
	return row, nil
}

func rowWidth(data []byte) int {
	width := 0
	quoted := false
	for index := 1; index < len(data)-1; index++ {
		switch data[index] {
		case '\\':
			if quoted {
				index++
			}
		case '"':
			quoted = !quoted
			if quoted && width == 0 {
				width = 1
			}
		case ',':
			if !quoted {
				width++
			}
		case 'n':
			if !quoted && width == 0 {
				width = 1
			}
		case ' ', '\t', '\r', '\n':
		default:
			if !quoted && data[index] != 'u' && data[index] != 'l' {
				// Rows contain only optional strings, never nested containers,
				// numbers, booleans, or arbitrary JSON values.
				return -1
			}
		}
	}
	return width
}

func validEngine(engine string) bool { return oneOf(engine, "postgresql", "mysql", "cassandra") }

func oneOf(value string, choices ...string) bool {
	for _, choice := range choices {
		if value == choice {
			return true
		}
	}
	return false
}

func validDigest(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range []byte(value) {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func decodeRequired(object map[string]json.RawMessage, key string, destination any) bool {
	value, ok := object[key]
	return ok && !bytes.Equal(bytes.TrimSpace(value), []byte("null")) && json.Unmarshal(value, destination) == nil
}

func decodeOptional(object map[string]json.RawMessage, key string, destination any) bool {
	value, ok := object[key]
	return !ok || json.Unmarshal(value, destination) == nil
}

func decodeObject(data []byte) (map[string]json.RawMessage, error) {
	if !validJSONText(data) {
		return nil, ErrCorrupt
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, ErrCorrupt
	}
	object := make(map[string]json.RawMessage)
	for decoder.More() {
		token, err := decoder.Token()
		key, ok := token.(string)
		if err != nil || !ok {
			return nil, ErrCorrupt
		}
		if _, duplicate := object[key]; duplicate {
			return nil, ErrCorrupt
		}
		var value json.RawMessage
		if decoder.Decode(&value) != nil {
			return nil, ErrCorrupt
		}
		object[key] = value
	}
	if token, err := decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, ErrCorrupt
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, ErrCorrupt
	}
	return object, nil
}

// encoding/json replaces invalid UTF-8 and unpaired UTF-16 surrogates with the
// replacement character. A snapshot comparison must never silently change bytes.
func validJSONText(data []byte) bool {
	if !utf8.Valid(data) || !json.Valid(data) {
		return false
	}
	for index := 0; index < len(data); index++ {
		if data[index] != '\\' {
			continue
		}
		index++
		if data[index] != 'u' {
			continue
		}
		code := hexCode(data[index+1 : index+5])
		index += 4
		if code >= 0xdc00 && code <= 0xdfff {
			return false
		}
		if code >= 0xd800 && code <= 0xdbff {
			if index+6 >= len(data) || data[index+1] != '\\' || data[index+2] != 'u' {
				return false
			}
			low := hexCode(data[index+3 : index+7])
			if low < 0xdc00 || low > 0xdfff {
				return false
			}
			index += 6
		}
	}
	return true
}

func hexCode(data []byte) uint16 {
	var code uint16
	for _, c := range data {
		code <<= 4
		switch {
		case c >= '0' && c <= '9':
			code += uint16(c - '0')
		case c >= 'a' && c <= 'f':
			code += uint16(c-'a') + 10
		default:
			code += uint16(c-'A') + 10
		}
	}
	return code
}
