package mysql

import (
	"strconv"
	"strings"
)

// Exact numeric columns must not compare a string parameter through MySQL's
// floating-point coercion. Normalize a bounded decimal string without float64,
// and cast only the parameter to a generated DECIMAL shape that preserves every
// significant digit. The column's own precision/scale must not round the input.
func browseNumericParameter(kind, value string) (string, string, error) {
	switch kind {
	case "tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric":
	default:
		return "?", value, nil
	}
	invalid := func() (string, string, error) {
		return "", "", invalidSettings("Exact numeric filters require a decimal value within 65 digits and 30 fractional places.")
	}
	if value == "" {
		return invalid()
	}
	negative := value[0] == '-'
	mantissa := value
	if mantissa[0] == '-' || mantissa[0] == '+' {
		mantissa = mantissa[1:]
	}
	exponent := 0
	if index := strings.IndexAny(mantissa, "eE"); index >= 0 {
		raw := mantissa[index+1:]
		mantissa = mantissa[:index]
		if raw == "" {
			return invalid()
		}
		digits := raw
		if digits[0] == '-' || digits[0] == '+' {
			digits = digits[1:]
		}
		if digits == "" {
			return invalid()
		}
		for _, digit := range digits {
			if digit < '0' || digit > '9' {
				return invalid()
			}
		}
		parsed, err := strconv.ParseInt(raw, 10, 32)
		if err != nil || parsed < -1_000_000 || parsed > 1_000_000 {
			return invalid()
		}
		exponent = int(parsed)
	}
	integer, fraction, _ := strings.Cut(mantissa, ".")
	if integer == "" && fraction == "" {
		return invalid()
	}
	digits := integer + fraction
	for _, digit := range digits {
		if digit < '0' || digit > '9' {
			return invalid()
		}
	}
	significant := strings.TrimLeft(digits, "0")
	if significant == "" {
		return "CAST(? AS DECIMAL(65,0))", "0", nil
	}
	decimalPoint := len(integer) + exponent - (len(digits) - len(significant))
	significant = strings.TrimRight(significant, "0")
	scale := max(len(significant)-decimalPoint, 0)
	integerDigits := max(decimalPoint, 0)
	if scale > 30 || integerDigits+scale > 65 {
		return invalid()
	}
	canonical := ""
	switch {
	case decimalPoint <= 0:
		canonical = "0." + strings.Repeat("0", -decimalPoint) + significant
	case decimalPoint >= len(significant):
		canonical = significant + strings.Repeat("0", decimalPoint-len(significant))
	default:
		canonical = significant[:decimalPoint] + "." + significant[decimalPoint:]
	}
	if negative {
		canonical = "-" + canonical
	}
	return "CAST(? AS DECIMAL(65," + strconv.Itoa(scale) + "))", canonical, nil
}
