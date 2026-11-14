package mariadb

import (
	"strings"
	"testing"

	"dbeer/helper/internal/tableedit"
)

func TestMariaDBStructureColumnNativeBoundsAndNoExpressionEvaluation(t *testing.T) {
	c := tableedit.Column{Name: "amount", Type: tableedit.DataType{Kind: "numeric", Precision: 65, Scale: 38}, Nullable: true, Default: tableedit.Default{Kind: "none"}}
	sql, err := mariaDBStructureColumn(c)
	if err != nil || sql != "`amount` DECIMAL(65,38)" {
		t.Fatal("native 65,38 column was not rendered")
	}
	c.Type.Scale = 39
	if _, err = mariaDBStructureColumn(c); err == nil {
		t.Fatal("native scale overflow accepted")
	}
	c.Type = tableedit.DataType{Kind: "integer"}
	expression := "(unknown_user_function(7))"
	c.Default = tableedit.Default{Kind: "expression", Value: &expression}
	sql, err = mariaDBStructureColumn(c)
	if err != nil || !strings.Contains(sql, expression) {
		t.Fatal("bounded expression was evaluated or rewritten during pure Preview rendering")
	}
	for _, bad := range []string{"1; DROP TABLE items", "1 /*M! + hidden() */", "1 # comment", "?", "'unterminated"} {
		c.Default.Value = &bad
		if _, err = mariaDBStructureColumn(c); err == nil {
			t.Fatal("expression escaped its single bounded slot")
		}
	}
}
