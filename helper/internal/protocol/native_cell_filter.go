package protocol

import (
	"dbeer/helper/internal/jsoncheck"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"
	"strconv"
	"strings"
	"unicode/utf8"
)

const NativeCellFilterCapability = "nativeCellFilterV1"
const NativeCellFilterValueLimit = 1024 * 1024
const NativeCellFilterBudget = 4 * 1024 * 1024

// NativeCellFilterValue retains a cell's source representation and the reviewed
// SQLite binding policy. SourceType is metadata, never executable SQL.
type NativeCellFilterValue struct {
	Cell          CellValue `json:"cell"`
	SourceEngine  string    `json:"sourceEngine"`
	SourceType    string    `json:"sourceType"`
	SQLiteStorage string    `json:"sqliteStorage"`
}

func (v NativeCellFilterValue) Valid() bool {
	if v.SourceEngine != "postgresql" && v.SourceEngine != "mysql" && v.SourceEngine != "mariadb" && v.SourceEngine != "sqlite" {
		return false
	}
	if v.SourceType == "" || len(v.SourceType) > 16384 || !utf8.ValidString(v.SourceType) || strings.ContainsRune(v.SourceType, 0) {
		return false
	}
	switch v.SQLiteStorage {
	case "preserve", "text", "integer", "real", "blob":
	default:
		return false
	}
	if v.Cell.Value == nil || len(*v.Cell.Value) > NativeCellFilterValueLimit || !v.Cell.Valid(false) {
		return false
	}
	switch v.Cell.Kind {
	case "text":
		return true
	case "binary":
		bytes, err := base64.StdEncoding.DecodeString(*v.Cell.Value)
		return err == nil && base64.StdEncoding.EncodeToString(bytes) == *v.Cell.Value
	case "sqliteInteger", "sqliteText", "sqliteBlob":
		return v.SourceEngine == "sqlite"
	case "sqliteReal":
		bits, err := strconv.ParseUint(*v.Cell.Value, 16, 64)
		f := math.Float64frombits(bits)
		return v.SourceEngine == "sqlite" && err == nil && !math.IsNaN(f)
	default:
		return false
	}
}

func (v NativeCellFilterValue) encodedSize() int {
	data, err := json.Marshal(v)
	if err != nil {
		return NativeCellFilterBudget + 1
	}
	return len(data)
}

func (v *NativeCellFilterValue) UnmarshalJSON(data []byte) error {
	invalid := errors.New("invalid native cell filter operand")
	if !utf8.Valid(data) || !uniqueObjectKeys(data) || !nativeJSONUnicodeValid(data) {
		return invalid
	}
	fields, ok := changesObject(data, "cell|sourceEngine|sourceType|sqliteStorage", "cell", "sourceEngine", "sourceType", "sqliteStorage")
	if !ok {
		return invalid
	}
	var parsed NativeCellFilterValue
	if !stringField(fields, "sourceEngine", &parsed.SourceEngine) || !stringField(fields, "sourceType", &parsed.SourceType) || !stringField(fields, "sqliteStorage", &parsed.SQLiteStorage) {
		return invalid
	}
	cell, ok := changesObject(fields["cell"], "kind|value", "kind", "value")
	if !ok || !stringField(cell, "kind", &parsed.Cell.Kind) {
		return invalid
	}
	var payload string
	if !stringField(cell, "value", &payload) {
		return invalid
	}
	parsed.Cell.Value = &payload
	if !parsed.Valid() {
		return invalid
	}
	*v = parsed
	return nil
}

// JSONUnicodeValid checks original UTF-8 and surrogate escapes before decoding.
// JSON syntax and field validation remain the caller's responsibility.
func JSONUnicodeValid(data []byte) bool {
	return utf8.Valid(data) && nativeJSONUnicodeValid(data)
}

// encoding/json replaces lone UTF16 surrogate escapes with U+FFFD. Reject
// them instead of changing a source cell's bytes or its type metadata.
func nativeJSONUnicodeValid(data []byte) bool { return jsoncheck.UnicodeValid(data) }
