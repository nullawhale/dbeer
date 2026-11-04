package mysql

import "testing"

func TestMySQLTransferPreservesUnsignedDecimalBounds(t *testing.T) {
	for _, native := range []string{"decimal(20,10)", "decimal(20,10) unsigned", "decimal(20,10) unsigned zerofill"} {
		precision, scale, ok := transferDecimalBounds(native)
		if !ok || precision != 20 || scale != 10 {
			t.Fatal("supported decimal modifiers hid its exact precision and scale")
		}
	}
	for _, native := range []string{"decimal(66,10)", "decimal(20,31)", "decimal(2,3)", "decimal(20,10) unknown"} {
		if _, _, ok := transferDecimalBounds(native); ok {
			t.Fatal("invalid or unknown decimal bounds were accepted")
		}
	}
}
