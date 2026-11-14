package queryparams

import (
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMariaDBParameterDialectAndScaleRemainEngineBound(t *testing.T) {
	value := "0." + strings.Repeat("1", 38)
	parameters := []protocol.QueryParameter{{Name: "amount", Type: "decimal", Value: &value}}
	bound, err := Bind("mariadb", "SELECT :amount,`literal:amount` # :ignored\n", parameters)
	if err != nil || bound.SQL != "SELECT CAST(? AS DECIMAL(39,38)),`literal:amount` # :ignored\n" || len(bound.Parameters) != 1 || bound.Parameters[0].Value == nil || *bound.Parameters[0].Value != value {
		t.Fatal("MariaDB dialect or exact decimal parameter was not retained")
	}
	if _, err := Bind("mysql", "SELECT :amount", parameters); err == nil {
		t.Fatal("MariaDB scale admission widened the MySQL contract")
	}
	for _, sql := range []string{"SELECT :amount /*! UNION SELECT :amount */", "SELECT :amount /*M! UNION SELECT :amount */"} {
		if _, err := Bind("mariadb", sql, parameters); err == nil {
			t.Fatal("ambiguous native executable comment accepted parameter binding")
		}
	}
}
