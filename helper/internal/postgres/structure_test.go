package postgres

import (
	"dbeer/helper/internal/tableedit"
	"strings"
	"testing"
)

func TestStructureTypedDefaultsAndIdentifierInjection(t *testing.T) {
	value := "NULL"
	c := tableedit.Column{Name: "x' ; DROP TABLE samples; --", Type: tableedit.DataType{Kind: "varchar", Length: 100}, Nullable: true, Default: tableedit.Default{Kind: "text", Value: &value}}
	sql, e := structureColumn(c)
	if e != nil || !strings.Contains(sql, "DEFAULT 'NULL'") && !strings.Contains(sql, "DEFAULT E'NULL'") {
		t.Fatal("literal NULL became SQL NULL")
	}
	value = "12345678901234567890.1234567890"
	c.Type = tableedit.DataType{Kind: "numeric", Precision: 30, Scale: 10}
	c.Default = tableedit.Default{Kind: "numeric", Value: &value}
	sql, e = structureColumn(c)
	if e != nil || !strings.Contains(sql, "pg_catalog.numeric(30,10)") || !strings.Contains(sql, value) {
		t.Fatal("exact decimal lost")
	}
	value = "0; DROP TABLE samples"
	if _, e = structureColumn(c); e == nil {
		t.Fatal("numeric expression accepted")
	}
	c.Default = tableedit.Default{Kind: "none"}
	sql, e = structureColumn(c)
	if e != nil || strings.Contains(sql, "DEFAULT") {
		t.Fatal("absent default changed")
	}
	c.Default = tableedit.Default{Kind: "null"}
	sql, e = structureColumn(c)
	if e != nil || !strings.HasSuffix(sql, "DEFAULT NULL") {
		t.Fatal("explicit NULL lost")
	}
}
