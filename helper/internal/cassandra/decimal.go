package cassandra

import (
	"math/big"
	"strconv"
	"strings"

	"gopkg.in/inf.v0"
)

// parseDecimal accepts CQL's exact scientific notation without computing a
// power of ten. The coefficient allocation is proportional to the input, and
// the resulting scale must fit Cassandra's signed 32-bit wire field.
func parseDecimal(text string) (*inf.Dec, error) {
	if len(text) == 0 || len(text) > 1024*1024 {
		return nil, errBrowse
	}
	mantissa, exponentText := text, ""
	if i := strings.IndexAny(text, "eE"); i >= 0 {
		mantissa, exponentText = text[:i], text[i+1:]
		if exponentText == "" || strings.IndexAny(exponentText, "eE") >= 0 {
			return nil, errBrowse
		}
	}
	var exponent int64
	if exponentText != "" {
		var err error
		exponent, err = strconv.ParseInt(exponentText, 10, 64)
		if err != nil {
			return nil, errBrowse
		}
	}
	sign := ""
	if len(mantissa) > 0 && (mantissa[0] == '-' || mantissa[0] == '+') {
		sign = mantissa[:1]
		mantissa = mantissa[1:]
	}
	if mantissa == "" {
		return nil, errBrowse
	}
	var digits strings.Builder
	digits.Grow(len(mantissa))
	point := false
	fraction := int64(0)
	for _, c := range []byte(mantissa) {
		if c == '.' {
			if point {
				return nil, errBrowse
			}
			point = true
			continue
		}
		if c < '0' || c > '9' {
			return nil, errBrowse
		}
		digits.WriteByte(c)
		if point {
			fraction++
		}
	}
	if digits.Len() == 0 || exponent < fraction-2147483647 || exponent > fraction+2147483648 {
		return nil, errBrowse
	}
	coefficient, ok := new(big.Int).SetString(sign+digits.String(), 10)
	if !ok {
		return nil, errBrowse
	}
	return inf.NewDecBig(coefficient, inf.Scale(fraction-exponent)), nil
}
