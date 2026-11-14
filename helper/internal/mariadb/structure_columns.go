package mariadb

import (
	"errors"

	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/tableedit"
)

func mariaDBStructureColumn(column tableedit.Column) (string, error) {
	if column.Type.Kind == "numeric" && (column.Type.Precision > 65 || column.Type.Scale > 38) {
		return "", errors.New("MariaDB DECIMAL authoring supports at most 65 digits and scale 38.")
	}
	if column.Identity != nil && column.Identity.Kind != "none" && (column.Identity.Kind != "autoIncrement" || column.Nullable || column.Type.Kind != "integer" && column.Type.Kind != "bigint") {
		return "", errors.New("MariaDB AUTO_INCREMENT requires a reviewed non-null integer or bigint column and a supporting key.")
	}
	return mysql.ColumnDefinitionSQL(column)
}
