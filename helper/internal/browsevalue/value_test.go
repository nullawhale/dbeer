package browsevalue

import (
	"encoding/base64"
	"fmt"
	"math"
	"math/big"
	"strings"
	"testing"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
)

func operand(kind, value, engine, native, policy string) protocol.NativeCellFilterValue {
	return protocol.NativeCellFilterValue{Cell: protocol.CellValue{Kind: kind, Value: &value}, SourceEngine: engine, SourceType: native, SQLiteStorage: policy}
}

func TestNativeServerExactIEEEAndDecimal(t *testing.T) {
	for _, test := range []struct {
		value protocol.NativeCellFilterValue
		want  string
	}{
		{operand("sqliteReal", "3fb999999999999a", "sqlite", "dynamic", "preserve"), "0.1000000000000000055511151231257827021181583404541015625"},
		{operand("text", "0.1", "postgresql", "real", "real"), "0.100000001490116119384765625"},
		{operand("text", "0.1", "mysql", "float", "real"), "0.100000001490116119384765625"},
		{operand("text", "0.1", "postgresql", "double precision", "real"), "0.1000000000000000055511151231257827021181583404541015625"},
		{operand("text", "9007199254740993.000000000000000001", "mysql", "decimal(40,20)", "text"), "9007199254740993.000000000000000001"},
		{operand("sqliteInteger", "9223372036854775807", "sqlite", "INTEGER", "preserve"), "9223372036854775807"},
	} {
		got, err := Server(test.value, Target{Numeric: true})
		if err != nil || got.Kind != "text" || got.Value == nil || *got.Value != test.want {
			t.Fatal("native operand did not retain the complete exact numeric value")
		}
	}
	for _, f := range []float64{math.SmallestNonzeroFloat64, math.MaxFloat64, -math.MaxFloat64, 1.5, -0.125, math.Copysign(0, -1)} {
		value := operand("sqliteReal", fmt.Sprintf("%016x", math.Float64bits(f)), "sqlite", "dynamic", "preserve")
		cell, err := Server(value, Target{Numeric: true})
		if err != nil {
			t.Fatal("finite IEEE value rejected")
		}
		got, err := Decimal(*cell.Value)
		if err != nil || got.Cmp(newRat(f)) != 0 {
			t.Fatal("full IEEE conversion changed mathematical value")
		}
	}
}

func newRat(f float64) *big.Rat { return new(big.Rat).SetFloat64(f) }

func TestNativeSQLitePoliciesAreLossless(t *testing.T) {
	tests := []struct {
		v         protocol.NativeCellFilterValue
		typ, text string
		valid     bool
	}{
		{operand("text", "1e999999999", "postgresql", "numeric", "text"), "text", "MWU5OTk5OTk5OTk=", true},
		{operand("text", "0.1", "postgresql", "numeric", "real"), "", "", false},
		{operand("text", "0.5", "postgresql", "numeric", "real"), "real", "3fe0000000000000", true},
		{operand("text", "9007199254740993", "postgresql", "bigint", "real"), "", "", false},
		{operand("sqliteInteger", "9007199254740993", "sqlite", "INTEGER", "real"), "", "", false},
		{operand("sqliteInteger", "9007199254740992", "sqlite", "INTEGER", "real"), "real", "4340000000000000", true},
		{operand("text", "0.1", "postgresql", "real", "real"), "real", "3fb99999a0000000", true},
		{operand("text", "0.1", "mysql", "double", "real"), "real", "3fb999999999999a", true},
		{operand("sqliteReal", "8000000000000000", "sqlite", "dynamic", "preserve"), "real", "8000000000000000", true},
		{operand("sqliteReal", "0000000000000001", "sqlite", "dynamic", "preserve"), "real", "0000000000000001", true},
		{operand("sqliteReal", "7ff0000000000000", "sqlite", "dynamic", "preserve"), "real", "7ff0000000000000", true},
		{operand("sqliteReal", "fff0000000000000", "sqlite", "dynamic", "preserve"), "real", "fff0000000000000", true},
		{operand("sqliteReal", "7ff8000000000000", "sqlite", "dynamic", "preserve"), "", "", false},
		{operand("sqliteReal", "7ff0000000000000", "sqlite", "dynamic", "integer"), "", "", false},
		{operand("sqliteReal", "3ff0000000000000", "sqlite", "dynamic", "integer"), "integer", "1", true},
		{operand("sqliteReal", "3ff8000000000000", "sqlite", "dynamic", "integer"), "", "", false},
		{operand("sqliteReal", "43e0000000000000", "sqlite", "dynamic", "integer"), "", "", false},
		{operand("sqliteReal", "c3e0000000000000", "sqlite", "dynamic", "integer"), "integer", "-9223372036854775808", true},
		{operand("text", "9223372036854775807", "mysql", "bigint", "integer"), "integer", "9223372036854775807", true},
		{operand("text", "9223372036854775808", "mysql", "bigint unsigned", "integer"), "", "", false},
		{operand("text", "1.000", "postgresql", "numeric", "integer"), "integer", "1", true},
		{operand("text", "1.000", "postgresql", "text", "integer"), "", "", false},
		{operand("text", "01", "postgresql", "text", "integer"), "", "", false},
		{operand("text", "+1", "postgresql", "text", "integer"), "", "", false},
		{operand("text", "1", "postgresql", "custom_domain", "real"), "", "", false},
		{operand("text", "0.5", "sqlite", "REAL", "real"), "", "", false},
		{operand("text", "1", "postgresql", "text", "integer"), "integer", "1", true},
		{operand("text", "1e-4096", "postgresql", "numeric", "real"), "", "", false},
		{operand("text", "1e4096", "postgresql", "numeric", "real"), "", "", false},
		{operand("text", "1e999999999", "postgresql", "numeric", "real"), "", "", false},
		{operand("text", "0.5", "postgresql", "numeric", "preserve"), "", "", false},
	}
	for i, test := range tests {
		got, err := SQLite(test.v)
		if (err == nil) != test.valid || test.valid && (got.Type != test.typ || got.Value != test.text || !got.Valid()) {
			t.Fatalf("SQLite policy case %d changed precision or storage", i)
		}
	}
}

func TestNativeTextAndBinaryNeverInterchange(t *testing.T) {
	for _, text := range []string{"", "NULL", "AP8=", "é", "e\u0301", "x\x00y", string([]byte{255, 0, 128})} {
		encoded := base64.StdEncoding.EncodeToString([]byte(text))
		if utf8.ValidString(text) {
			cell, err := Server(operand("text", text, "mysql", "varchar(20)", "text"), Target{})
			if err != nil || cell.Value == nil || *cell.Value != text {
				t.Fatal("server text bytes changed")
			}
		}
		for _, policy := range []string{"preserve", "text"} {
			got, err := SQLite(operand("sqliteText", encoded, "sqlite", "ANY", policy))
			if err != nil || got.Type != "text" || got.Value != encoded {
				t.Fatal("SQLite text bytes changed")
			}
		}
		if _, err := SQLite(operand("sqliteBlob", encoded, "sqlite", "ANY", "text")); err == nil {
			t.Fatal("blob silently decoded as text")
		}
		if _, err := SQLite(operand("sqliteText", encoded, "sqlite", "ANY", "blob")); err == nil {
			t.Fatal("text silently treated as binary")
		}
		blob, err := SQLite(operand("binary", encoded, "mysql", "varbinary", "blob"))
		if err != nil || blob.Type != "blob" || blob.Value != encoded {
			t.Fatal("binary bytes changed")
		}
	}
	for _, value := range []protocol.NativeCellFilterValue{
		operand("text", "AP8=", "postgresql", "text", "text"),
		operand("sqliteText", "AP8=", "sqlite", "ANY", "preserve"),
	} {
		if _, err := Server(value, Target{Binary: true}); err == nil {
			t.Fatal("text accepted by binary target")
		}
	}
	if _, err := Server(operand("binary", "AP8=", "mysql", "blob", "blob"), Target{}); err == nil {
		t.Fatal("binary accepted by text target")
	}
	for _, encoded := range []string{"/w==", "YQBi"} {
		if _, err := Server(operand("sqliteText", encoded, "sqlite", "ANY", "preserve"), Target{RejectNUL: true}); err == nil {
			t.Fatal("PostgreSQL unrepresentable text accepted")
		}
	}
	if _, err := Server(operand("text", "1", "mysql", "varchar(20)", "text"), Target{Numeric: true}); err == nil {
		t.Fatal("arbitrary text guessed as numeric")
	}
	if _, err := Server(operand("text", "0.1", "mysql", "decimal(10,5)", "real"), Target{Numeric: true, FloatBits: 64}); err == nil {
		t.Fatal("decimal rounded to native float")
	}
}

func TestNativeDecimalWorkBounds(t *testing.T) {
	for _, value := range []string{"1e999999999", "1e-999999999", "1e4097", "1e-4097", strings.Repeat("9", 4097), "1/2", "0x1", "1.2.3", "", "+", ".", "1e", "1e1e1", "NaN", "Inf", "1e+", "1e-", "1e++2"} {
		if _, err := Decimal(value); err == nil {
			t.Fatal("unbounded or malformed decimal accepted")
		}
	}
	for _, value := range []string{"1e4096", "1e-4096", strings.Repeat("9", 4096), "-.5", "0.000", "1.0e+3"} {
		if _, err := Decimal(value); err != nil {
			t.Fatal("bounded exact decimal rejected")
		}
	}
}

func TestNativeFloatSourceCannotUnderflowOrChangePrecision(t *testing.T) {
	for _, test := range []struct {
		value, sourceType string
		bits              int
	}{
		{"1e-1000", "double precision", 64},
		{"1e1000", "double precision", 64},
		{"NaN", "double precision", 64},
		{"Infinity", "double precision", 64},
		{"0x1p0", "double precision", 64},
		{"9007199254740993", "numeric", 64},
		{"0.1", "numeric", 64},
		{"0.1000000000000000055511151231257827021181583404541015625", "numeric", 32},
	} {
		value := operand("text", test.value, "postgresql", test.sourceType, "real")
		if _, err := Server(value, Target{Numeric: true, FloatBits: test.bits}); err == nil {
			t.Fatal("native float conversion rounded or reinterpreted its input")
		}
	}
	value := operand("text", "0.1", "postgresql", "real", "real")
	if cell, err := Server(value, Target{Numeric: true, FloatBits: 32}); err != nil || *cell.Value != "0.100000001490116119384765625" {
		t.Fatal("known native float32 was not promoted exactly")
	}
	for _, policy := range []string{"integer", "real", "text", "blob"} {
		value := operand("sqliteReal", "7ff0000000000000", "sqlite", "ANY", policy)
		if _, err := SQLite(value); err == nil {
			t.Fatal("nonfinite SQLite value used an incompatible storage policy")
		}
	}
	for _, target := range []Target{{}, {Numeric: true}, {Numeric: true, FloatBits: 64}} {
		value := operand("sqliteReal", "7ff0000000000000", "sqlite", "ANY", "preserve")
		if _, err := Server(value, target); err == nil {
			t.Fatal("nonfinite native value was silently changed for a server target")
		}
	}
}
