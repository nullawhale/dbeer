package mariadb

import (
	"strings"
	"testing"

	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func TestMariaDBStorageNativeLiveInstantsChoicesAndFloatBits(t *testing.T) {
	s := dataIntegrationSession(t)
	query := func(sql string) *wire.Result {
		t.Helper()
		r, err := s.work.client.Execute(sql)
		if err != nil {
			t.Fatal("native storage fixture statement failed")
		}
		return r
	}
	exec := func(sql string) { r := query(sql); r.Close() }
	before := query("SELECT @@SESSION.sql_mode,@@SESSION.time_zone")
	mode, _ := before.GetString(0, 0)
	zone, _ := before.GetString(0, 1)
	before.Close()
	t.Cleanup(func() {
		r, err := s.work.client.Execute("SET SESSION sql_mode=?,time_zone=?", mode, zone)
		if err != nil {
			t.Error("native storage fixture could not restore its explicit settings")
			return
		}
		r.Close()
	})
	exec("SET SESSION sql_mode='',time_zone='+00:00'")
	exec("CREATE TEMPORARY TABLE g1_storage_native(id INT PRIMARY KEY,e ENUM('','a','b'),s SET('','a','b'),f FLOAT,d DOUBLE,t TIMESTAMP(6) NULL)")
	exec("INSERT INTO g1_storage_native VALUES(1,0,0,1.00000011920928955078125,1.0000000000000002,'2024-10-27 00:30:00.123456'),(2,1,1,1.0000002384185791015625,1.0000000000000004,'2024-10-27 01:30:00.123456'),(3,NULL,NULL,NULL,NULL,NULL),(4,0,0,0,0,'0000-00-00 00:00:00.000000')")
	exec("SET SESSION time_zone='Europe/Berlin'")
	kinds := map[string]string{"e": "enum", "s": "set", "f": "float", "d": "double", "t": "timestamp"}
	names := MariaDBStorageColumns(kinds)
	projection := strings.Join(MariaDBStorageProjections(names, kinds), ",")
	r := query("SELECT e,s,t," + MariaDBStableProjection("t", "timestamp") + "," + projection + " FROM g1_storage_native ORDER BY id")
	defer r.Close()
	if len(r.Values) != 4 || len(r.Values[0]) != 4+len(names) {
		t.Fatal("native storage fixture lost its complete projection")
	}
	firstTime, _ := r.GetString(0, 2)
	secondTime, _ := r.GetString(1, 2)
	if firstTime != secondTime || firstTime != "2024-10-27 02:30:00.123456" {
		t.Fatal("fixture did not reach the native daylight-saving fold")
	}
	for index, expected := range []string{"2024-10-27 00:30:00.123456", "2024-10-27 01:30:00.123456"} {
		canonical, _ := r.GetString(index, 3)
		if canonical != expected {
			t.Fatal("native timestamp instant or fraction changed during canonical rendering")
		}
	}
	for _, ordinal := range []int{0, 1} {
		left, _ := r.GetString(0, ordinal)
		right, _ := r.GetString(1, ordinal)
		if left != "" || right != "" {
			t.Fatal("native choice fixture no longer has ambiguous display labels")
		}
	}
	tokens := map[string]bool{}
	for _, row := range r.Values {
		token, err := MariaDBStorageToken(row[4:])
		if err != nil || token == "" || tokens[token] {
			t.Fatal("distinct native storage states shared an opaque token")
		}
		tokens[token] = true
	}
	for column, name := range names {
		first, second := r.Values[0][4+column], r.Values[1][4+column]
		switch name {
		case "e", "s":
			if first.AsUint64() != 0 || second.AsUint64() != 1 {
				t.Fatal("native choice ordinal or mask was not captured")
			}
		case "f", "d":
			if first.Type != wire.FieldValueTypeFloat || second.Type != wire.FieldValueTypeFloat || first.AsFloat64() == second.AsFloat64() {
				t.Fatal("promoted native floating values lost distinct bits")
			}
		case "t":
			if string(first.AsString()) != "epoch:1729989000.123456" || string(second.AsString()) != "epoch:1729992600.123456" || r.Values[2][4+column].Type != wire.FieldValueTypeNull || !strings.HasPrefix(string(r.Values[3][4+column].AsString()), "zero:") {
				t.Fatal("native epoch fold, NULL, zero or fractional storage identity was lost")
			}
		}
	}
	after := query("SELECT @@SESSION.sql_mode,@@SESSION.time_zone")
	defer after.Close()
	afterMode, _ := after.GetString(0, 0)
	afterZone, _ := after.GetString(0, 1)
	if afterMode != "" || afterZone != "Europe/Berlin" {
		t.Fatal("storage projections changed native session state")
	}
}
