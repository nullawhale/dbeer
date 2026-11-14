package nativevalue

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/jsoncheck"
	"dbeer/helper/internal/sqlitevalue"
)

const NativeResultValuesCapability = "nativeResultValuesV1"
const NativeResultValuesFormat = "nativeV1"
const MaxNativeValueDepth = 32
const MaxNativeValueNodes = 100000
const MaxNativeValueBytes = 4 * 1024 * 1024

// NativeValue is captured evidence, never an edit instruction. Entries preserve
// key order and duplicate keys; opaque values retain bytes without inventing semantics.
type NativeValue struct {
	Kind         string
	Value        *string
	Engine       string
	NativeType   string
	TypeIdentity string
	Items        []NativeValue
	Entries      []NativeEntry
}

type NativeEntry struct {
	Key   NativeValue `json:"key"`
	Value NativeValue `json:"value"`
}

var nativeInteger = regexp.MustCompile(`^-?[0-9]+$`)
var nativeDecimal = regexp.MustCompile(`^-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$`)

func NativeScalar(kind, value string) NativeValue { return NativeValue{Kind: kind, Value: &value} }
func NativeBinary(value []byte) NativeValue {
	if len(value) > (MaxNativeValueBytes-128)/4*3 {
		return NativeValue{Kind: "invalid"}
	}
	return NativeScalar("binary", base64.StdEncoding.EncodeToString(value))
}
func NativeFloat32(value float32) NativeValue {
	return NativeScalar("float32", strconv.FormatUint(uint64(math.Float32bits(value)), 16)).paddedFloat(8)
}
func NativeFloat64(value float64) NativeValue {
	return NativeScalar("float64", strconv.FormatUint(math.Float64bits(value), 16)).paddedFloat(16)
}
func (value NativeValue) paddedFloat(width int) NativeValue {
	text := strings.Repeat("0", width-len(*value.Value)) + *value.Value
	value.Value = &text
	return value
}

type nativeValueBudget struct{ nodes, bytes int }

// NativeMatrixBudget validates rows incrementally under the same whole-matrix
// limits used by persisted and received results, without retaining a duplicate tree.
type NativeMatrixBudget struct {
	budget nativeValueBudget
	rows   int
}

func (budget *NativeMatrixBudget) Append(row []NativeValue, columns int) bool {
	if columns < 0 || columns > 4096 || len(row) != columns || budget.rows >= 100000 {
		return false
	}
	next := *budget
	if next.rows == 0 {
		next.budget.bytes = 2
	} else {
		next.budget.bytes++
	}
	next.budget.bytes += 2 + max(0, columns-1)
	for _, value := range row {
		if !value.valid(0, &next.budget) {
			return false
		}
	}
	if next.budget.bytes > MaxNativeValueBytes {
		return false
	}
	next.rows++
	*budget = next
	return true
}

func (value NativeValue) Valid() bool {
	return value.valid(0, &nativeValueBudget{})
}

func (value NativeValue) valid(depth int, budget *nativeValueBudget) bool {
	budget.nodes++
	budget.bytes += 9 + nativeJSONStringBytes(value.Kind)
	for name, text := range map[string]string{"engine": value.Engine, "nativeType": value.NativeType, "typeIdentity": value.TypeIdentity} {
		if text != "" {
			budget.bytes += len(name) + 4 + nativeJSONStringBytes(text)
		}
	}
	if depth > MaxNativeValueDepth || budget.nodes > MaxNativeValueNodes || budget.bytes > MaxNativeValueBytes {
		return false
	}
	for _, text := range []string{value.Engine, value.NativeType, value.TypeIdentity} {
		if len(text) > 65536 || !utf8.ValidString(text) || strings.ContainsRune(text, 0) {
			return false
		}
	}
	if value.Engine != "" && value.Engine != "postgresql" && value.Engine != "mysql" && value.Engine != "mariadb" && value.Engine != "sqlite" && value.Engine != "mongodb" && value.Engine != "cassandra" {
		return false
	}
	if value.Value != nil {
		budget.bytes += 9 + nativeJSONStringBytes(*value.Value)
		if !utf8.ValidString(*value.Value) || budget.bytes > MaxNativeValueBytes {
			return false
		}
	}
	scalar := value.Value != nil && value.Items == nil && value.Entries == nil
	switch value.Kind {
	case "null":
		return value.Value == nil && value.Items == nil && value.Entries == nil
	case "text":
		return scalar
	case "native":
		return scalar && value.Engine != "" && value.NativeType != ""
	case "integer":
		return scalar && len(*value.Value) <= 65536 && nativeInteger.MatchString(*value.Value)
	case "decimal":
		return scalar && len(*value.Value) <= 65536 && nativeDecimal.MatchString(*value.Value)
	case "boolean":
		return scalar && (*value.Value == "true" || *value.Value == "false")
	case "float32", "float64":
		width := 8
		if value.Kind == "float64" {
			width = 16
		}
		if !scalar || len(*value.Value) != width {
			return false
		}
		decoded, err := hex.DecodeString(*value.Value)
		return err == nil && hex.EncodeToString(decoded) == *value.Value
	case "binary", "opaque":
		if !scalar || value.Kind == "opaque" && (value.Engine == "" || value.NativeType == "") {
			return false
		}
		decoded, err := base64.StdEncoding.Strict().DecodeString(*value.Value)
		return err == nil && base64.StdEncoding.EncodeToString(decoded) == *value.Value
	case "list", "tuple", "set":
		if value.Value != nil || value.Items == nil || value.Entries != nil {
			return false
		}
		budget.bytes += 11 + max(0, len(value.Items)-1)
		for _, item := range value.Items {
			if !item.valid(depth+1, budget) {
				return false
			}
		}
		return budget.bytes <= MaxNativeValueBytes
	case "map", "object":
		if value.Value != nil || value.Items != nil || value.Entries == nil {
			return false
		}
		budget.bytes += 13 + max(0, len(value.Entries)-1) + 17*len(value.Entries)
		for _, entry := range value.Entries {
			if value.Kind == "object" && entry.Key.Kind != "text" {
				return false
			}
			if !entry.Key.valid(depth+1, budget) || !entry.Value.valid(depth+1, budget) {
				return false
			}
		}
		return budget.bytes <= MaxNativeValueBytes
	default:
		return false
	}
}

func nativeJSONStringBytes(text string) int {
	count := 2
	for _, scalar := range text {
		switch scalar {
		case '"', '\\', '\b', '\f', '\n', '\r', '\t':
			count += 2
		case '<', '>', '&', '\u2028', '\u2029':
			count += 6
		default:
			if scalar < 32 {
				count += 6
			} else {
				count += utf8.RuneLen(scalar)
			}
		}
	}
	return count
}

func NativeMatrixValid(values [][]NativeValue, rows, columns int) bool {
	if values == nil {
		return true
	}
	if rows < 0 || columns < 0 || columns > 4096 || rows > 100000 || len(values) != rows || rows != 0 && columns > MaxNativeValueNodes/rows {
		return false
	}
	budget := &NativeMatrixBudget{}
	for _, row := range values {
		if !budget.Append(row, columns) {
			return false
		}
	}
	encoded, err := json.Marshal(values)
	return err == nil && len(encoded) <= MaxNativeValueBytes
}

func (value NativeValue) MarshalJSON() ([]byte, error) {
	if !value.Valid() {
		return nil, errors.New("invalid native value")
	}
	fields := map[string]any{"kind": value.Kind}
	if value.Value != nil {
		fields["value"] = *value.Value
	}
	if value.Engine != "" {
		fields["engine"] = value.Engine
	}
	if value.NativeType != "" {
		fields["nativeType"] = value.NativeType
	}
	if value.TypeIdentity != "" {
		fields["typeIdentity"] = value.TypeIdentity
	}
	if value.Items != nil {
		fields["items"] = value.Items
	}
	if value.Entries != nil {
		fields["entries"] = value.Entries
	}
	return json.Marshal(fields)
}

func (value *NativeValue) UnmarshalJSON(data []byte) error {
	if len(data) > MaxNativeValueBytes || !jsoncheck.UnicodeValid(data) || !jsoncheck.UniqueObjectKeys(data) {
		return errors.New("invalid native value")
	}
	parsed, err := parseNativeValue(data, 0, &nativeValueBudget{})
	if err != nil || !parsed.Valid() {
		return errors.New("invalid native value")
	}
	*value = parsed
	return nil
}

func parseNativeValue(data []byte, depth int, budget *nativeValueBudget) (NativeValue, error) {
	var value NativeValue
	budget.nodes++
	if depth > MaxNativeValueDepth || budget.nodes > MaxNativeValueNodes {
		return value, errors.New("native value limit")
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil || fields == nil {
		return value, errors.New("invalid native value")
	}
	for key, raw := range fields {
		if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return value, errors.New("null native field")
		}
		switch key {
		case "kind", "value", "engine", "nativeType", "typeIdentity", "items", "entries":
		default:
			return value, errors.New("unknown native field")
		}
	}
	if json.Unmarshal(fields["kind"], &value.Kind) != nil {
		return value, errors.New("missing native kind")
	}
	for name, target := range map[string]*string{"engine": &value.Engine, "nativeType": &value.NativeType, "typeIdentity": &value.TypeIdentity} {
		if raw, exists := fields[name]; exists {
			if json.Unmarshal(raw, target) != nil || *target == "" {
				return value, errors.New("invalid native metadata")
			}
		}
	}
	if raw, exists := fields["value"]; exists {
		var text string
		if json.Unmarshal(raw, &text) != nil {
			return value, errors.New("invalid native scalar")
		}
		value.Value = &text
	}
	if raw, exists := fields["items"]; exists {
		var items []json.RawMessage
		if json.Unmarshal(raw, &items) != nil || items == nil || len(items) > MaxNativeValueNodes {
			return value, errors.New("invalid native items")
		}
		value.Items = make([]NativeValue, len(items))
		for i, item := range items {
			parsed, err := parseNativeValue(item, depth+1, budget)
			if err != nil {
				return value, err
			}
			value.Items[i] = parsed
		}
	}
	if raw, exists := fields["entries"]; exists {
		var entries []json.RawMessage
		if json.Unmarshal(raw, &entries) != nil || entries == nil || len(entries) > MaxNativeValueNodes/2 {
			return value, errors.New("invalid native entries")
		}
		value.Entries = make([]NativeEntry, len(entries))
		for i, entry := range entries {
			var pair map[string]json.RawMessage
			if json.Unmarshal(entry, &pair) != nil || len(pair) != 2 || pair["key"] == nil || pair["value"] == nil {
				return value, errors.New("invalid native entry")
			}
			key, err := parseNativeValue(pair["key"], depth+1, budget)
			if err != nil {
				return value, err
			}
			item, err := parseNativeValue(pair["value"], depth+1, budget)
			if err != nil {
				return value, err
			}
			value.Entries[i] = NativeEntry{Key: key, Value: item}
		}
	}
	return value, nil
}

// Comparable proves exact value semantics for the shared comparison contract.
// Opaque/native payloads and unordered collection kinds need adapter-specific proof.
func (value NativeValue) Comparable() bool {
	if !value.Valid() {
		return false
	}
	switch value.Kind {
	case "opaque", "native", "set", "map":
		return false
	}
	if strings.HasPrefix(value.TypeIdentity, "unresolved:") {
		return false
	}
	for _, item := range value.Items {
		if !item.Comparable() {
			return false
		}
	}
	for _, entry := range value.Entries {
		if !entry.Key.Comparable() || !entry.Value.Comparable() {
			return false
		}
	}
	return true
}

func MatchesSQLite(native NativeValue, cell sqlitevalue.Value) bool {
	if native.Engine != "sqlite" || native.NativeType != cell.Type {
		return false
	}
	switch cell.Type {
	case "null":
		return native.Kind == "null"
	case "integer":
		return native.Kind == "integer" && native.Value != nil && *native.Value == cell.Value
	case "real":
		return native.Kind == "float64" && native.Value != nil && *native.Value == cell.Value
	case "blob":
		return native.Kind == "binary" && native.Value != nil && *native.Value == cell.Value
	case "text":
		raw, err := base64.StdEncoding.Strict().DecodeString(cell.Value)
		if err != nil {
			return false
		}
		if utf8.Valid(raw) {
			return native.Kind == "text" && native.Value != nil && *native.Value == string(raw)
		}
		return native.Kind == "opaque" && native.Value != nil && *native.Value == cell.Value
	}
	return false
}
