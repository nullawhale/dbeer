package resultartifact

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPersistedColumnTypeIdentityIsOptionalBoundedAndLossless(t *testing.T) {
	column := Column{Index: 0, Name: "mood", Engine: "postgresql", NativeType: `"fixture"."mood"`, TypeIdentity: "pgtype-v1:" + strings.Repeat("a", 64)}
	raw, _ := json.Marshal(column)
	decoded, err := decodeColumn(raw, 0)
	if err != nil || decoded != column {
		t.Fatal("column structural identity was lost")
	}
	column.TypeIdentity = strings.Repeat("x", 65537)
	raw, _ = json.Marshal(column)
	if _, err := decodeColumn(raw, 0); err == nil {
		t.Fatal("oversized identity accepted")
	}
	column.TypeIdentity = ""
	raw, _ = json.Marshal(column)
	if decoded, err = decodeColumn(raw, 0); err != nil || decoded != column {
		t.Fatal("legacy column rejected")
	}
}
