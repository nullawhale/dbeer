package queryparams

import (
	"dbeer/helper/internal/protocol"
	"strings"
	"testing"
)

func TestExplainGenericBindingsDoNotRewriteQuotedNamesOrValues(t *testing.T) {
	value := "'quoted :n' ; DELETE FROM evidence; --"
	one := "1"
	parameters := []protocol.QueryParameter{{Name: "n", Type: "integer", Value: &one}, {Name: "text", Type: "text", Value: &value}}
	sql := "SELECT ':n', :n, :text, :n /* :text */ -- :n\n"
	bound, err := BindGeneric(sql, parameters)
	if err != nil || len(bound.Parameters) != 2 || strings.Count(bound.SQL, "($1::pg_catalog.int8)") != 2 || strings.Count(bound.SQL, "($2::pg_catalog.text)") != 1 || !strings.Contains(bound.SQL, "':n'") || !strings.Contains(bound.SQL, "/* :text */") || strings.Contains(bound.SQL, value) {
		t.Fatal("generic placeholder rewrite crossed lexical/value boundaries")
	}
	if bound.AssessmentSQL != "SELECT ':n', 00, 00000, 00 /* :text */ -- :n\n" {
		t.Fatal("generic assessment no longer maps original source bytes")
	}
	if _, err := BindGeneric("SELECT :missing", parameters); err == nil {
		t.Fatal("missing generic binding accepted")
	}
}
