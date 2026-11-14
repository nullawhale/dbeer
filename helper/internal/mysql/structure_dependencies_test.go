package mysql

import (
	"dbeer/helper/internal/tableedit"
	"testing"
)

func TestStructureDependencyIdentifiersKeepScopeAndQuoting(t *testing.T) {
	target := tableedit.Target{Schema: "owned", Table: "parent"}
	for _, x := range []struct {
		body, schema, mode string
		want               bool
	}{
		{"INSERT INTO `parent` VALUES(NEW.id)", "owned", "", true},
		{"INSERT INTO owned.parent VALUES(NEW.id)", "other", "", true},
		{"INSERT INTO `owned`.`parent` VALUES(NEW.id)", "other", "", true},
		{"INSERT INTO parent VALUES(NEW.id)", "other", "", false},
		{"INSERT INTO parent_shadow VALUES(NEW.id)", "owned", "", false},
		{"SET @x='parent'", "owned", "", false},
		{"INSERT INTO `unproven\\name` VALUES(1)", "other", "", true},
		{"SET @x='back\\'; INSERT INTO parent VALUES(NEW.id)", "owned", "NO_BACKSLASH_ESCAPES", true},
	} {
		if mysqlMayReferenceTable(x.body, x.schema, target, x.mode) != x.want {
			t.Fatal("trigger/routine dependency scope or literal boundaries changed")
		}
	}
}
