// Package datatransfer owns reviewed, immutable new-table transfer plans.
package datatransfer

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
)

const DefaultQuotaBytes int64 = 4 << 30
const MaxRowBytes = 16 << 20

var ErrInvalid = errors.New("Transfer definitions or values are incompatible.")
var ErrChanged = errors.New("The source structure changed. Describe and review the transfer again.")
var ErrExists = errors.New("The destination already exists. Choose a new table name.")
var ErrQuota = errors.New("The private transfer workspace exceeded its 4 GiB limit.")

type Description struct {
	Columns []protocol.TransferColumn
	Digest  string
	Notices []string
}
type Result struct {
	Rows           int64
	TableCreated   bool
	OutcomeUnknown bool
}
type RowReader func() ([]protocol.CellValue, error)

// Each method is called on an independently owned physical connection.
type Database interface {
	TransferDescribe(context.Context, string, string) (Description, error)
	TransferCapture(context.Context, string, string, string, func([]protocol.CellValue) error) (Description, error)
	TransferPreview(context.Context, string, string, []protocol.TransferColumn) (string, string, error)
	TransferApply(context.Context, string, string, string, []protocol.TransferColumn, RowReader, func(int64)) (Result, error)
}

func Digest(value any) string {
	data, _ := json.Marshal(value)
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}
func OmissionNotice() string {
	return "Creates reviewed columns and copies their values only. Source keys, indexes, foreign keys, defaults, identity/sequence behavior, generated expressions, triggers and grants are not cloned."
}

var decimalPattern = regexp.MustCompile(`^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$`)

func Decimal(value string) (string, int, int, error) {
	if len(value) > 8192 || !decimalPattern.MatchString(value) {
		return "", 0, 0, ErrInvalid
	}
	negative := strings.HasPrefix(value, "-")
	value = strings.TrimLeft(value, "+-")
	exponent := 0
	if offset := strings.IndexAny(value, "eE"); offset >= 0 {
		var err error
		exponent, err = strconv.Atoi(value[offset+1:])
		if err != nil || exponent < -1000 || exponent > 1000 {
			return "", 0, 0, ErrInvalid
		}
		value = value[:offset]
	}
	parts := strings.Split(value, ".")
	whole, fraction := parts[0], ""
	if len(parts) == 2 {
		fraction = parts[1]
	}
	digits := whole + fraction
	point := len(whole) + exponent
	if point < 0 {
		digits = strings.Repeat("0", -point) + digits
		point = 0
	}
	if point > len(digits) {
		digits += strings.Repeat("0", point-len(digits))
	}
	whole, fraction = digits[:point], digits[point:]
	whole = strings.TrimLeft(whole, "0")
	if whole == "" {
		whole = "0"
	}
	fraction = strings.TrimRight(fraction, "0")
	precision := len(strings.TrimLeft(whole, "0")) + len(fraction)
	if precision == 0 {
		precision = 1
	}
	if precision > 1000 || len(fraction) > 1000 {
		return "", 0, 0, ErrInvalid
	}
	canonical := whole
	if fraction != "" {
		canonical += "." + fraction
	}
	if negative && canonical != "0" {
		canonical = "-" + canonical
	}
	return canonical, precision, len(fraction), nil
}

func Normalize(value protocol.CellValue, column protocol.TransferColumn, engine string) (protocol.CellValue, error) {
	if !column.Valid() || value.Kind == "default" || !value.Valid(false) {
		return value, ErrInvalid
	}
	if value.Kind == "null" {
		if !column.Nullable {
			return value, ErrInvalid
		}
		return value, nil
	}
	if value.Value == nil {
		return value, ErrInvalid
	}
	text := *value.Value
	if column.Type == "binary" {
		if value.Kind != "binary" {
			return value, ErrInvalid
		}
		decoded, err := base64.StdEncoding.DecodeString(text)
		if err != nil || base64.StdEncoding.EncodeToString(decoded) != text {
			return value, ErrInvalid
		}
		return value, nil
	}
	if value.Kind != "text" || !utf8.ValidString(text) || strings.ContainsRune(text, 0) {
		return value, ErrInvalid
	}
	switch column.Type {
	case "text":
	case "integer":
		n, err := strconv.ParseInt(text, 10, 64)
		if err != nil {
			return value, ErrInvalid
		}
		text = strconv.FormatInt(n, 10)
	case "decimal":
		canonical, p, s, err := Decimal(text)
		whole := p - s
		if canonical == "0" {
			whole = 0
		}
		if err != nil || s > column.Scale || whole > column.Precision-column.Scale || !transferDecimalFits(engine, column.Precision, column.Scale) {
			return value, ErrInvalid
		}
		text = canonical
	case "real":
		n, err := strconv.ParseFloat(text, 64)
		if err != nil || math.IsNaN(n) || math.IsInf(n, 0) {
			return value, ErrInvalid
		}
		canonical, _, _, err := Decimal(text)
		if err != nil {
			return value, ErrInvalid
		}
		text = strconv.FormatFloat(n, 'g', -1, 64)
		rendered, _, _, err := Decimal(text)
		if err != nil || rendered != canonical {
			return value, ErrInvalid
		}
	case "boolean":
		switch strings.ToLower(text) {
		case "true", "t", "1":
			text = "true"
		case "false", "f", "0":
			text = "false"
		default:
			return value, ErrInvalid
		}
	case "date":
		parsed, err := time.Parse("2006-01-02", text)
		if err != nil || parsed.Year() < 1 || (engine == "mysql" || engine == "mariadb") && parsed.Year() < 1000 {
			return value, ErrInvalid
		}
	case "timestamp":
		parsed, err := time.Parse("2006-01-02 15:04:05.999999999", strings.Replace(text, "T", " ", 1))
		if err != nil || parsed.Year() < 1 || parsed.Nanosecond()%1000 != 0 || (engine == "mysql" || engine == "mariadb") && parsed.Year() < 1000 {
			return value, ErrInvalid
		}
		text = parsed.Format("2006-01-02 15:04:05.999999999")
	case "timestampTZ":
		parsed, err := time.Parse(time.RFC3339Nano, text)
		utc := parsed.UTC()
		if err != nil || utc.Year() < 1 || utc.Year() > 9999 || parsed.Nanosecond()%1000 != 0 || (engine == "mysql" || engine == "mariadb") && utc.Year() < 1000 {
			return value, ErrInvalid
		}
		text = utc.Format(time.RFC3339Nano)
	case "json":
		if !json.Valid([]byte(text)) {
			return value, ErrInvalid
		}
	default:
		return value, ErrInvalid
	}
	return protocol.CellValue{Kind: "text", Value: &text}, nil
}

func Infer(headers []string, rows [][]protocol.CellValue, engine string) ([]protocol.TransferColumn, []string) {
	columns := make([]protocol.TransferColumn, len(headers))
	notices := []string{}
	for index, header := range headers {
		name := strings.TrimSpace(header)
		if name == "" {
			name = "column_" + strconv.Itoa(index+1)
		}
		limit := 63
		if engine == "mysql" || engine == "mariadb" {
			limit = 64
		}
		for len(name) > limit && engine != "mysql" && engine != "mariadb" || (engine == "mysql" || engine == "mariadb") && utf8.RuneCountInString(name) > limit {
			_, size := utf8.DecodeLastRuneInString(name)
			name = name[:len(name)-size]
		}
		base := name
		suffix := 2
		for {
			duplicate := false
			for _, prior := range columns[:index] {
				if prior.Name == name || (engine == "mysql" || engine == "mariadb") && strings.EqualFold(prior.Name, name) {
					duplicate = true
					break
				}
			}
			if !duplicate {
				break
			}
			tail := "_" + strconv.Itoa(suffix)
			name = base
			for (engine != "mariadb" && len(name)+len(tail) > limit) || (engine == "mariadb" && utf8.RuneCountInString(name)+len(tail) > limit) {
				_, size := utf8.DecodeLastRuneInString(name)
				name = name[:len(name)-size]
			}
			name += tail
			suffix++
		}
		column := protocol.TransferColumn{SourceIndex: index, Name: name, Type: "text", Nullable: len(rows) == 0}
		nonnull := []protocol.CellValue{}
		for _, row := range rows {
			if index >= len(row) {
				continue
			}
			if row[index].Kind == "null" {
				column.Nullable = true
			} else {
				nonnull = append(nonnull, row[index])
			}
		}
		for _, kind := range []string{"integer", "decimal", "boolean", "date", "timestampTZ", "timestamp", "json", "binary", "text"} {
			candidate := column
			candidate.Type = kind
			if kind == "decimal" {
				whole, scale := 0, 0
				for _, value := range nonnull {
					if value.Value == nil || value.Kind != "text" {
						continue
					}
					_, p, s, err := Decimal(*value.Value)
					if err == nil {
						whole = max(whole, p-s)
						scale = max(scale, s)
					}
				}
				candidate.Precision = max(1, whole+scale)
				candidate.Scale = scale
				if !transferDecimalFits(engine, candidate.Precision, scale) {
					continue
				}
			}
			valid := len(nonnull) > 0
			for _, value := range nonnull {
				if kind == "json" && value.Value != nil {
					spelling := strings.TrimSpace(*value.Value)
					if !strings.HasPrefix(spelling, "{") && !strings.HasPrefix(spelling, "[") {
						valid = false
						break
					}
				}
				if value.Value != nil && (kind == "integer" || kind == "decimal") {
					spelling := strings.TrimLeft(*value.Value, "+-")
					if strings.HasPrefix(*value.Value, "-") {
						if canonical, _, _, err := Decimal(*value.Value); err == nil && canonical == "0" {
							valid = false
							break
						}
					}
					if len(spelling) > 1 && spelling[0] == '0' && spelling[1] >= '0' && spelling[1] <= '9' {
						valid = false
						break
					}
				}
				if _, err := Normalize(value, candidate, engine); err != nil {
					valid = false
					break
				}
			}
			if valid || kind == "text" {
				column = candidate
				break
			}
		}
		columns[index] = column
	}
	return columns, notices
}

func ValidateColumns(columns []protocol.TransferColumn, engine string) error {
	if len(columns) == 0 || len(columns) > protocol.MaxTransferColumns {
		return ErrInvalid
	}
	seen := map[string]bool{}
	for _, column := range columns {
		key := column.Name
		if engine == "mariadb" {
			key = strings.ToLower(key)
		}
		if !column.Valid() || seen[key] || (engine == "mysql" || engine == "mariadb") && utf8.RuneCountInString(column.Name) > 64 || engine == "postgresql" && len([]byte(column.Name)) > 63 || column.Type == "decimal" && !transferDecimalFits(engine, column.Precision, column.Scale) {
			return ErrInvalid
		}
		seen[key] = true
	}
	return nil
}

func ValidateTarget(engine, schema, table string) error {
	for _, name := range []string{schema, table} {
		if name == "" || !utf8.ValidString(name) || strings.ContainsRune(name, 0) || engine == "postgresql" && len(name) > 63 || (engine == "mysql" || engine == "mariadb") && utf8.RuneCountInString(name) > 64 {
			return ErrInvalid
		}
	}
	return nil
}

func MapRow(row []protocol.CellValue, columns []protocol.TransferColumn, engine string) ([]protocol.CellValue, int, error) {
	mapped := make([]protocol.CellValue, len(columns))
	for index, column := range columns {
		if column.SourceIndex >= len(row) {
			return nil, index, ErrChanged
		}
		value, err := Normalize(row[column.SourceIndex], column, engine)
		if err != nil {
			return nil, index, err
		}
		mapped[index] = value
	}
	return mapped, -1, nil
}

func transferDecimalFits(engine string, precision, scale int) bool {
	switch engine {
	case "mysql":
		return precision <= 65 && scale <= 30
	case "mariadb":
		return precision <= 65 && scale <= 38
	}
	return true
}
