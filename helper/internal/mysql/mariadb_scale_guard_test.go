package mysql

import (
	"dbeer/helper/internal/tableedit"
	"testing"
)

func TestMariaDBScaleDoesNotChangeMySQLColumnAdmission(t *testing.T) {
	column := tableedit.Column{Name: "amount", Type: tableedit.DataType{Kind: "numeric", Precision: 65, Scale: 38}, Nullable: true, Default: tableedit.Default{Kind: "none"}}
	if _, err := structureColumn(column); err == nil {
		t.Fatal("MariaDB numeric scale admitted by MySQL adapter")
	}
	column.Type.Scale = 30
	if _, err := structureColumn(column); err != nil {
		t.Fatal("existing MySQL numeric column rejected")
	}
}
