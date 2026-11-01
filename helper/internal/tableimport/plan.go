// Package tableimport plans bounded, insert-only imports without retaining files.
package tableimport

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
)

type Column struct {
	protocol.TableImportColumn
	Writable  bool
	Supported bool
	OID       uint32
}

var ErrInvalid = errors.New("The import mapping or values are incompatible with the target columns.")
var ErrConflict = errors.New("The table structure changed. Describe the table and preview the import again.")

func Fingerprint(facts any) string {
	data, _ := json.Marshal(facts)
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

func MetadataFingerprint(facts any) (string, error) {
	data, err := json.Marshal(facts)
	if err != nil || len(data) > 4*1024*1024 {
		return "", ErrInvalid
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}

// Validate never writes data. Returned columns retain request mapping order.
func Validate(columns []Column, fingerprint string, request protocol.TableImportRequest) ([]Column, error) {
	if !request.Valid("import.apply") {
		return nil, ErrInvalid
	}
	if request.Fingerprint != fingerprint {
		return nil, ErrConflict
	}
	byName, selected := map[string]Column{}, map[string]bool{}
	for _, c := range columns {
		byName[c.Name] = c
	}
	mapped := make([]Column, len(request.Columns))
	for i, name := range request.Columns {
		column, exists := byName[name]
		if !exists || column.Generated || !column.Writable || !column.Supported {
			return nil, ErrInvalid
		}
		mapped[i], selected[name] = column, true
	}
	for _, column := range columns {
		if !selected[column.Name] && !column.Nullable && !column.HasDefault && !column.Generated {
			return nil, ErrInvalid
		}
	}
	for _, row := range request.Rows {
		for i, value := range row {
			if value.Kind == "null" && !mapped[i].Nullable || value.Kind == "text" && mapped[i].Binary || value.Kind == "binary" && !mapped[i].Binary {
				return nil, ErrInvalid
			}
		}
	}
	return mapped, nil
}

func ReplyColumns(columns []Column) []protocol.TableImportColumn {
	result := make([]protocol.TableImportColumn, len(columns))
	for i, c := range columns {
		result[i] = c.TableImportColumn
	}
	return result
}

func DescriptionValid(columns []Column) bool {
	if len(columns) == 0 || len(columns) > 4096 {
		return false
	}
	seen := map[string]bool{}
	for _, c := range columns {
		if c.Name == "" || len(c.Name) > 1024 || strings.ContainsRune(c.Name, 0) || !utf8.ValidString(c.Name) || seen[c.Name] || len(c.NativeType) == 0 || len(c.NativeType) > 65536 || strings.ContainsRune(c.NativeType, 0) || !utf8.ValidString(c.NativeType) {
			return false
		}
		seen[c.Name] = true
	}
	encoded, err := json.Marshal(ReplyColumns(columns))
	return err == nil && len(encoded) <= 8*1024*1024
}
