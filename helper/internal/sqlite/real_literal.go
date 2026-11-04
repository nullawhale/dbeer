package sqlite

import (
	"errors"
	"math"
	"strconv"
	"strings"
)

var errSQLiteRealLiteral = errors.New("SQLite cannot preserve this REAL value exactly.")

// exactRealSQL avoids decimal-to-binary parsing by scaling an exact integer
// significand by powers of two. Every intermediate is exactly representable.
// SQLite normalizes negative zero when writing a record; refuse that payload.
func exactRealSQL(raw string) (string, error) {
	bits, err := strconv.ParseUint(raw, 16, 64)
	if err != nil || len(raw) != 16 {
		return "", errSQLiteRealLiteral
	}
	f := math.Float64frombits(bits)
	if math.IsNaN(f) || bits == uint64(1)<<63 {
		return "", errSQLiteRealLiteral
	}
	if math.IsInf(f, 0) {
		if math.IsInf(f, -1) {
			return "-9e999", nil
		}
		return "9e999", nil
	}
	mantissa := bits & ((uint64(1) << 52) - 1)
	exponent := int((bits >> 52) & 0x7ff)
	scale := -1074
	if exponent != 0 {
		mantissa |= uint64(1) << 52
		scale = exponent - 1023 - 52
	}
	if mantissa == 0 {
		scale = 0
	}
	var out strings.Builder
	out.WriteByte('(')
	if bits>>63 != 0 {
		out.WriteByte('-')
	}
	out.WriteString("CAST(")
	out.WriteString(strconv.FormatUint(mantissa, 10))
	out.WriteString(" AS REAL)")
	for scale != 0 {
		step := min(52, max(scale, -scale))
		if scale < 0 {
			out.WriteString(" / ")
			scale += step
		} else {
			out.WriteString(" * ")
			scale -= step
		}
		out.WriteString(strconv.FormatUint(uint64(1)<<step, 10))
	}
	out.WriteByte(')')
	return out.String(), nil
}
