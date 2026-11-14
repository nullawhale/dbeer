package mariadb

import (
	"dbeer/helper/internal/tableedit"
	"testing"
)

func TestMariaDBStructureFactsCommentReferenceBounds(t *testing.T) {
	target := tableedit.Target{Schema: "target_schema", Table: "target_table"}
	for _, body := range []string{"BEGIN -- target_schema.target_table John's unmatched quote\n SELECT 1; END", "BEGIN # target_schema.target_table John's unmatched quote\n SELECT 1; END", "SELECT 'target_schema.target_table # -- q''s'"} {
		if mariaMayReferenceTable(body, "external_schema", target, "") {
			t.Fatal("comment or quoted text became a native table reference")
		}
	}
	for _, body := range []string{"BEGIN -- John's unmatched quote\n SELECT * FROM `target_schema`.`target_table`; END", "BEGIN # John's unmatched quote\n SELECT * FROM `target_schema`.`target_table`; END", "SELECT 'unterminated"} {
		if !mariaMayReferenceTable(body, "external_schema", target, "") {
			t.Fatal("real or unavailable native reference gained empty dependency proof")
		}
	}
	if _, ok := mariaIndexMetadataTokens("SELECT 1--2,3", "", 0); !ok {
		t.Fatal("non-comment double-minus operator was rejected")
	}
}
