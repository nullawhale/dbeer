package postgres

import (
	"dbeer/helper/internal/tableedit"
	"testing"
)

func TestMariaDBScaleDoesNotChangePostgresColumnAdmission(t *testing.T) {
	column := tableedit.Column{Name: "amount", Type: tableedit.DataType{Kind: "numeric", Precision: 65, Scale: 38}, Nullable: true, Default: tableedit.Default{Kind: "none"}}
	if _, err := structureColumn(column); err == nil {
		t.Fatal("MariaDB numeric bound broadened existing PostgreSQL authoring")
	}
	column.Type.Scale = 30
	if _, err := structureColumn(column); err != nil {
		t.Fatal("existing PostgreSQL numeric column rejected")
	}
}
