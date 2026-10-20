package mysql

import (
	"strings"
	"testing"
)

func TestBrowseExactNumericParametersNeverRoundClampOrUseFloatingPoint(t *testing.T) {
	for _, item := range []struct{ input, canonical, scale string }{
		{"9007199254740993.000000000000000001", "9007199254740993.000000000000000001", "18"},
		{"-9223372036854775808", "-9223372036854775808", "0"},
		{"18446744073709551615", "18446744073709551615", "0"},
		{"18446744073709551616", "18446744073709551616", "0"},
		{strings.Repeat("9", 65), strings.Repeat("9", 65), "0"},
		{"0." + strings.Repeat("0", 29) + "1", "0." + strings.Repeat("0", 29) + "1", "30"},
		{"1.234", "1.234", "3"}, {"+.0012000", "0.0012", "4"},
		{"1.234e2", "123.4", "1"}, {"1e-30", "0." + strings.Repeat("0", 29) + "1", "30"},
		{"-0e999", "0", "0"}, {"001000.00", "1000", "0"},
	} {
		for _, kind := range []string{"decimal", "bigint", "int"} {
			parameter, value, err := browseNumericParameter(kind, item.input)
			if err != nil || value != item.canonical || parameter != "CAST(? AS DECIMAL(65,"+item.scale+"))" {
				t.Fatal("exact numeric parameter lost its decimal representation")
			}
		}
	}
	for _, value := range []string{"", "NaN", "Infinity", "-Inf", "1e999999999", "1e-999999999", "1e", "1e+-2", "1e2e3", ".", "1/3", "1.2.3", "0x10", "1; DROP TABLE x", strings.Repeat("9", 66), "0." + strings.Repeat("0", 30) + "1", strings.Repeat("9", 36) + "." + strings.Repeat("1", 30)} {
		if _, _, err := browseNumericParameter("decimal", value); err == nil {
			t.Fatal("unsupported exact numeric filter was silently coerced")
		}
	}
	parameter, value, err := browseNumericParameter("text", "x' OR 1=1 --")
	if err != nil || parameter != "?" || value != "x' OR 1=1 --" {
		t.Fatal("text stopped being a parameter value")
	}
}
