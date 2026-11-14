package mariadb

import (
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/adapter"

	wire "github.com/go-mysql-org/go-mysql/mysql"
)

// Implicit system periods are native pseudo-columns, not I_S column ordinals.
// Keep them separate from visible snapshot columns and bind them in row tokens.
type MariaDBPeriodColumn struct {
	Name, NativeType, DataType, Generated string
	Implicit                              bool
}

func MariaDBSystemPeriods(query func(string, ...any) (*wire.Result, error), schema, table, nativeKind string, columns []MariaDBPeriodColumn) ([]MariaDBPeriodColumn, error) {
	if nativeKind != "SYSTEM VERSIONED" {
		return nil, nil
	}
	if !mariaDBNameValid(schema) || !mariaDBNameValid(table) || len(columns) > 4096 {
		return nil, editFailure("validation", "Native system-period metadata exceeds its supported bounds.")
	}
	owned := make([]MariaDBPeriodColumn, len(columns))
	for i, column := range columns {
		owned[i] = MariaDBPeriodColumn{Name: strings.Clone(column.Name), NativeType: strings.Clone(column.NativeType), DataType: strings.Clone(column.DataType), Generated: strings.Clone(column.Generated)}
	}
	columns = owned
	state, err := query("SELECT @@SESSION.system_versioning_asof")
	if err != nil {
		return nil, err
	}
	current, readErr := state.GetString(0, 0)
	validCurrent := state.RowNumber() == 1 && readErr == nil && current == "DEFAULT"
	state.Close()
	if !validCurrent {
		return nil, editFailure("validation", "Row writes on system-versioned tables require the already active system_versioning_asof='DEFAULT' context. Historical observation cannot authorize current-row changes.")
	}
	var start, end *MariaDBPeriodColumn
	for i := range columns {
		column := &columns[i]
		switch column.Generated {
		case "ROW START":
			if start != nil {
				return nil, editFailure("validation", "Native system-period metadata is ambiguous.")
			}
			start = column
		case "ROW END":
			if end != nil {
				return nil, editFailure("validation", "Native system-period metadata is ambiguous.")
			}
			end = column
		}
	}
	if start != nil || end != nil {
		if start == nil || end == nil || start.Name == end.Name || start.DataType != end.DataType || (start.DataType != "timestamp" && start.DataType != "bigint") {
			return nil, editFailure("validation", "Both exact native system periods are required before row writes.")
		}
		return []MariaDBPeriodColumn{*start, *end}, nil
	}
	for _, column := range columns {
		if strings.EqualFold(column.Name, "ROW_START") || strings.EqualFold(column.Name, "ROW_END") {
			return nil, editFailure("validation", "The implicit native period names conflict with captured column metadata.")
		}
	}
	result, err := query("SELECT ROW_START,ROW_END FROM " + QuoteIdentifier(schema) + "." + QuoteIdentifier(table) + " LIMIT 0")
	if err != nil {
		return nil, err
	}
	defer result.Close()
	if result.RowNumber() != 0 || len(result.Fields) != 2 {
		return nil, editFailure("validation", "The implicit native system-period metadata is unavailable.")
	}
	periods := make([]MariaDBPeriodColumn, 2)
	for i, name := range []string{"ROW_START", "ROW_END"} {
		field := result.Fields[i]
		if field == nil || !strings.EqualFold(string(field.Name), name) || field.Type != wire.MYSQL_TYPE_TIMESTAMP || field.Decimal != 6 {
			return nil, editFailure("validation", "The implicit native system-period type or name is unrecognized.")
		}
		role := "ROW START"
		if i == 1 {
			role = "ROW END"
		}
		periods[i] = MariaDBPeriodColumn{Name: name, NativeType: "timestamp(6)", DataType: "timestamp", Generated: role, Implicit: true}
	}
	return periods, nil
}

func editFailure(category, message string) error {
	return &adapter.ConnectionError{Category: category, Message: message}
}

func mariaDBNameValid(name string) bool {
	return name != "" && len(name) <= 256 && utf8.ValidString(name) && !strings.ContainsRune(name, 0)
}
