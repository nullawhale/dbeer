// Package browsevalue converts typed browse operands without losing storage,
// binary encoding, integer precision, or the exact value of an IEEE float.
package browsevalue

import (
	"encoding/base64"
	"errors"
	"fmt"
	"math"
	"math/big"
	"strconv"
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
)

var ErrConversion = errors.New("The native filter value cannot be represented exactly by the selected target type or SQLite storage policy.")

// Target describes authoritative adapter metadata, never source metadata.
// FloatBits is 32 or 64 only for a native floating-point target.
type Target struct {
	Binary, Numeric bool
	FloatBits       int
	RejectNUL       bool
}

type source struct {
	text        string
	bytes       []byte
	binary      bool
	number      *big.Rat
	floating    float64
	nativeFloat bool
	sqlite      *protocol.SQLiteValue
}

// Decimal bounds coefficient digits and exponent work before allocating big
// integers. No user-controlled exponent reaches math/big's string parser.
func Decimal(value string) (*big.Rat, error) {
	if value == "" || len(value) > 8220 {
		return nil, ErrConversion
	}
	negative := false
	if value[0] == '-' || value[0] == '+' {
		negative = value[0] == '-'
		value = value[1:]
	}
	exponent := 0
	if i := strings.IndexAny(value, "eE"); i >= 0 {
		raw := value[i+1:]
		value = value[:i]
		if len(raw) == 0 || len(raw) > 6 {
			return nil, ErrConversion
		}
		n, err := strconv.Atoi(raw)
		if err != nil || n < -4096 || n > 4096 {
			return nil, ErrConversion
		}
		exponent = n
	}
	integer, fraction, found := strings.Cut(value, ".")
	if !found {
		fraction = ""
	}
	digits := integer + fraction
	if len(digits) == 0 || len(digits) > 4096 {
		return nil, ErrConversion
	}
	for _, d := range digits {
		if d < '0' || d > '9' {
			return nil, ErrConversion
		}
	}
	coefficient, ok := new(big.Int).SetString(digits, 10)
	if !ok {
		return nil, ErrConversion
	}
	if negative {
		coefficient.Neg(coefficient)
	}
	scale := len(fraction) - exponent
	power := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(abs(scale))), nil)
	if scale < 0 {
		return new(big.Rat).SetInt(coefficient.Mul(coefficient, power)), nil
	}
	return new(big.Rat).SetFrac(coefficient, power), nil
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// decimalText emits the entire exact terminating decimal, including the tail
// hidden by shortest-roundtrip float formatting (for example binary64 0.1).
func decimalText(r *big.Rat) string {
	denominator := new(big.Int).Set(r.Denom())
	two, five, remainder := big.NewInt(2), big.NewInt(5), new(big.Int)
	twos, fives := 0, 0
	for {
		quotient := new(big.Int)
		quotient.QuoRem(denominator, two, remainder)
		if remainder.Sign() != 0 {
			break
		}
		denominator = quotient
		twos++
	}
	for {
		quotient := new(big.Int)
		quotient.QuoRem(denominator, five, remainder)
		if remainder.Sign() != 0 {
			break
		}
		denominator = quotient
		fives++
	}
	text := r.FloatString(max(twos, fives))
	if strings.Contains(text, ".") {
		text = strings.TrimRight(strings.TrimRight(text, "0"), ".")
	}
	return text
}

func numericSource(engine, native string) (numeric bool, floatBits int) {
	if engine == "sqlite" {
		return false, 0
	}
	kind := strings.ToLower(strings.TrimSpace(native))
	kind = strings.TrimPrefix(kind, "pg_catalog.")
	if i := strings.IndexByte(kind, '('); i >= 0 {
		kind = strings.TrimSpace(kind[:i])
	}
	if engine == "mysql" || engine == "mariadb" {
		for {
			previous := kind
			kind = strings.TrimSuffix(strings.TrimSuffix(kind, " unsigned"), " zerofill")
			if previous == kind {
				break
			}
		}
	}
	switch kind {
	case "smallint", "integer", "bigint", "int2", "int4", "int8", "numeric", "decimal":
		return true, 0
	case "tinyint", "mediumint", "int":
		return (engine == "mysql" || engine == "mariadb"), 0
	case "float4", "real":
		if engine == "postgresql" {
			return true, 32
		}
	case "float8", "double precision":
		if engine == "postgresql" {
			return true, 64
		}
	case "float":
		if engine == "mysql" || engine == "mariadb" {
			return true, 32
		}
	case "double":
		if engine == "mysql" || engine == "mariadb" {
			return true, 64
		}
	}
	return false, 0
}

func decode(v protocol.NativeCellFilterValue) (source, error) {
	if !v.Valid() {
		return source{}, ErrConversion
	}
	s := source{}
	payload := *v.Cell.Value
	switch v.Cell.Kind {
	case "binary", "sqliteBlob":
		s.bytes, _ = base64.StdEncoding.DecodeString(payload)
		s.binary = true
	case "sqliteText":
		s.bytes, _ = base64.StdEncoding.DecodeString(payload)
		s.text = string(s.bytes)
	case "sqliteInteger":
		s.text = payload
		s.number, _ = Decimal(payload)
	case "sqliteReal":
		bits, _ := strconv.ParseUint(payload, 16, 64)
		s.floating = math.Float64frombits(bits)
		s.nativeFloat = true
		s.number = new(big.Rat).SetFloat64(s.floating)
		if s.number != nil {
			s.text = decimalText(s.number)
		}
	case "text":
		s.text = payload
		numeric, bits := numericSource(v.SourceEngine, v.SourceType)
		if numeric {
			if bits != 0 {
				input, decimalErr := Decimal(payload)
				if decimalErr != nil {
					return source{}, decimalErr
				}
				f, err := strconv.ParseFloat(payload, bits)
				if err != nil || math.IsInf(f, 0) || math.IsNaN(f) || f == 0 && input.Sign() != 0 {
					return source{}, ErrConversion
				}
				s.floating, s.nativeFloat = f, true
				s.number = new(big.Rat).SetFloat64(f)
			} else {
				var err error
				s.number, err = Decimal(payload)
				if err != nil {
					return source{}, err
				}
			}
		}
	}
	if strings.HasPrefix(v.Cell.Kind, "sqlite") {
		scalar := protocol.SQLiteValue{Type: strings.ToLower(strings.TrimPrefix(v.Cell.Kind, "sqlite")), Value: payload}
		s.sqlite = &scalar
	}
	return s, nil
}

func exactFloat(number *big.Rat, bits int) (float64, bool) {
	if number == nil {
		return 0, false
	}
	f, exact := number.Float64()
	if !exact || math.IsInf(f, 0) || math.IsNaN(f) {
		return 0, false
	}
	if bits == 32 && float64(float32(f)) != f {
		return 0, false
	}
	return f, true
}

// Server returns a CellValue suitable for an adapter's existing bound-operand
// and source-SQL formatters. Binary and text remain separate categories.
func Server(v protocol.NativeCellFilterValue, target Target) (protocol.CellValue, error) {
	s, err := decode(v)
	if err != nil {
		return protocol.CellValue{}, err
	}
	if target.Binary != s.binary {
		return protocol.CellValue{}, ErrConversion
	}
	kind, text := "text", s.text
	if s.binary {
		kind, text = "binary", base64.StdEncoding.EncodeToString(s.bytes)
	} else if target.Numeric {
		if s.number == nil {
			return protocol.CellValue{}, ErrConversion
		}
		if target.FloatBits != 0 {
			if _, ok := exactFloat(s.number, target.FloatBits); !ok {
				return protocol.CellValue{}, ErrConversion
			}
		}
		text = decimalText(s.number)
	} else if s.nativeFloat && s.number == nil {
		return protocol.CellValue{}, ErrConversion
	}
	if !s.binary && (!utf8.ValidString(text) || target.RejectNUL && strings.ContainsRune(text, 0)) {
		return protocol.CellValue{}, ErrConversion
	}
	return protocol.CellValue{Kind: kind, Value: &text}, nil
}

// SQLite follows the explicit binding policy; it does not infer affinity from
// target declarations or from a value's display text.
func SQLite(v protocol.NativeCellFilterValue) (protocol.SQLiteValue, error) {
	if !v.Valid() {
		return protocol.SQLiteValue{}, ErrConversion
	}
	if v.SQLiteStorage == "text" && v.Cell.Kind == "text" {
		return protocol.SQLiteValue{Type: "text", Value: base64.StdEncoding.EncodeToString([]byte(*v.Cell.Value))}, nil
	}
	s, err := decode(v)
	if err != nil {
		return protocol.SQLiteValue{}, err
	}
	switch v.SQLiteStorage {
	case "preserve":
		if s.sqlite == nil {
			return protocol.SQLiteValue{}, ErrConversion
		}
		return *s.sqlite, nil
	case "text":
		if s.binary {
			return protocol.SQLiteValue{}, ErrConversion
		}
		if s.sqlite != nil && s.sqlite.Type != "text" {
			return protocol.SQLiteValue{}, ErrConversion
		}
		return protocol.SQLiteValue{Type: "text", Value: base64.StdEncoding.EncodeToString([]byte(s.text))}, nil
	case "blob":
		if !s.binary {
			return protocol.SQLiteValue{}, ErrConversion
		}
		return protocol.SQLiteValue{Type: "blob", Value: base64.StdEncoding.EncodeToString(s.bytes)}, nil
	case "integer":
		number := s.number
		if number == nil && !s.binary && !s.nativeFloat {
			// Only a canonical integer may opt into numeric conversion without native
			// numeric metadata. This rejects formatting such as 01, +1, or 1.0.
			integer, err := strconv.ParseInt(s.text, 10, 64)
			if err != nil || strconv.FormatInt(integer, 10) != s.text {
				return protocol.SQLiteValue{}, ErrConversion
			}
			number = new(big.Rat).SetInt64(integer)
		}
		if number == nil || !number.IsInt() || !number.Num().IsInt64() {
			return protocol.SQLiteValue{}, ErrConversion
		}
		return protocol.SQLiteValue{Type: "integer", Value: number.Num().String()}, nil
	case "real":
		f, ok := exactFloat(s.number, 64)
		if !ok {
			return protocol.SQLiteValue{}, ErrConversion
		}
		if s.nativeFloat {
			f = s.floating
		}
		return protocol.SQLiteValue{Type: "real", Value: fmt.Sprintf("%016x", math.Float64bits(f))}, nil
	}
	return protocol.SQLiteValue{}, ErrConversion
}
