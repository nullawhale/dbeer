package mariadb

import (
	"strings"
	"testing"

	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func TestMariaDBSystemPeriodProbeIsClosedAndMetadataOnly(t *testing.T) {
	for _, mutation := range []string{"valid", "historical", "wrongName", "wrongType", "wrongPrecision", "missingEnd"} {
		t.Run(mutation, func(t *testing.T) {
			calls := 0
			query := func(sql string, args ...any) (*wire.Result, error) {
				calls++
				if len(args) != 0 {
					t.Fatal("native period probe introduced authored bound expressions")
				}
				if calls == 1 {
					if sql != "SELECT @@SESSION.system_versioning_asof" {
						t.Fatal("native period probe changed session state")
					}
					value := "DEFAULT"
					if mutation == "historical" {
						value = "2020-01-01"
					}
					r := wire.NewResultset(1)
					r.Fields[0] = &wire.Field{Name: []byte("state"), Type: wire.MYSQL_TYPE_VAR_STRING}
					r.Values = [][]wire.FieldValue{{wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte(value))}}
					return wire.NewResult(r), nil
				}
				if sql != "SELECT ROW_START,ROW_END FROM `schema`.`odd``name` LIMIT 0" || strings.Contains(sql, "SET ") {
					t.Fatal("native period probe read rows, evaluated an authored expression or changed session state")
				}
				result := wire.NewResultset(2)
				result.Fields = []*wire.Field{{Name: []byte("ROW_START"), Type: wire.MYSQL_TYPE_TIMESTAMP, Decimal: 6}, {Name: []byte("ROW_END"), Type: wire.MYSQL_TYPE_TIMESTAMP, Decimal: 6}}
				switch mutation {
				case "wrongName":
					result.Fields[1].Name = []byte("unreviewed")
				case "wrongType":
					result.Fields[1].Type = wire.MYSQL_TYPE_DATETIME
				case "wrongPrecision":
					result.Fields[1].Decimal = 0
				case "missingEnd":
					result.Fields = result.Fields[:1]
				}
				return wire.NewResult(result), nil
			}
			periods, err := MariaDBSystemPeriods(query, "schema", "odd`name", "SYSTEM VERSIONED", []MariaDBPeriodColumn{{Name: "id", NativeType: "int(11)", DataType: "int"}})
			if mutation == "valid" {
				if err != nil || len(periods) != 2 || !periods[0].Implicit || !periods[1].Implicit || periods[0].Name != "ROW_START" || periods[1].Generated != "ROW END" {
					t.Fatal("complete native implicit period metadata was not retained")
				}
			} else if err == nil {
				t.Fatal("unrecognized or historical native period metadata was accepted")
			}
		})
	}
	columns := []MariaDBPeriodColumn{{Name: "start", NativeType: "bigint(20) unsigned", DataType: "bigint", Generated: "ROW START"}}
	query := func(string, ...any) (*wire.Result, error) {
		r := wire.NewResultset(1)
		r.Fields[0] = &wire.Field{Name: []byte("state"), Type: wire.MYSQL_TYPE_VAR_STRING}
		r.Values = [][]wire.FieldValue{{wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte("DEFAULT"))}}
		return wire.NewResult(r), nil
	}
	if _, err := MariaDBSystemPeriods(query, "schema", "table", "SYSTEM VERSIONED", columns); err == nil {
		t.Fatal("a partial explicit period silently fell back to implicit pseudo-columns")
	}
	columns = append(columns, columns[0], MariaDBPeriodColumn{Name: "end", NativeType: "bigint(20) unsigned", DataType: "bigint", Generated: "ROW END"})
	if _, err := MariaDBSystemPeriods(query, "schema", "table", "SYSTEM VERSIONED", columns); err == nil {
		t.Fatal("duplicate explicit native roles were accepted")
	}
}
