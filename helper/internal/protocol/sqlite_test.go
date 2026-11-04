package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestSQLiteSharedContract(t *testing.T) {
	data, e := os.ReadFile("../../../protocol/fixtures/sqlite-v1.json")
	if e != nil {
		t.Fatal(e)
	}
	var f struct {
		Version     int
		Connection  Connection
		TypedValues []SQLiteValue
	}
	if json.Unmarshal(data, &f) != nil || f.Version != Version || !f.Connection.Valid() {
		t.Fatal("invalid shared SQLite fixture")
	}
	for _, v := range f.TypedValues {
		if !v.Valid() {
			t.Fatal("invalid typed fixture cell")
		}
	}
	c, _ := json.Marshal(f.Connection)
	for _, kind := range []string{"connect", "sqlite.create"} {
		if _, e := ParseCommand([]byte(`{"type":"` + kind + `","requestId":"sqlite","connection":` + string(c) + `}`)); e != nil {
			t.Fatal(e)
		}
	}
	for _, bad := range []string{strings.Replace(string(c), `"port":0`, `"port":5432`, 1), strings.Replace(string(c), `/synthetic/example.sqlite`, `relative.sqlite`, 1), strings.Replace(string(c), `"password":""`, `"password":"secret"`, 1)} {
		if _, e := ParseCommand([]byte(`{"type":"connect","requestId":"bad","connection":` + bad + `}`)); e == nil {
			t.Fatal("unsafe SQLite connection accepted")
		}
	}
	for _, v := range []SQLiteValue{{"integer", "01"}, {"integer", "9223372036854775808"}, {"real", "abc"}, {"blob", "%%%"}, {"null", "text"}, {"unknown", ""}} {
		if v.Valid() {
			t.Fatal("invalid cell accepted")
		}
	}
	r := Response{Type: "query.result", RequestID: "sqlite", SQLiteValues: [][]SQLiteValue{f.TypedValues}}
	encoded, e := json.Marshal(r)
	if e != nil || !strings.Contains(string(encoded), `"sqliteValues"`) {
		t.Fatal("typed cells lost on transport")
	}
}
