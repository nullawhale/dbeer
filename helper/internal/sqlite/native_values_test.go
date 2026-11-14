package sqlite

import (
	"context"
	"encoding/json"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestNativeResultValuesRetainActualSQLiteStorage(t *testing.T) {
	session, _ := openCore(t, false)
	command := protocol.Command{Type: "execute", RequestID: "r", SessionID: "s", QueryID: "q", SQL: "SELECT NULL,9223372036854775807,-0.0,'','NULL',CAST(X'ff' AS TEXT),X'00ff'", ResultValues: protocol.NativeResultValuesFormat}
	result := session.Execute(context.Background(), command)
	if result.Type != "query.result" || len(result.NativeValues) != 1 || !protocol.NativeMatrixValid(result.NativeValues, 1, 7) {
		t.Fatal("actual typed SQLite result unavailable")
	}
	values := result.NativeValues[0]
	for index, kind := range []string{"null", "integer", "float64", "text", "text", "opaque", "binary"} {
		if values[index].Kind != kind {
			t.Fatalf("SQLite native storage %d changed", index)
		}
	}
	if *values[1].Value != "9223372036854775807" || *values[2].Value != "8000000000000000" || *values[3].Value != "" || *values[4].Value != "NULL" || *values[5].Value != "/w==" || *values[6].Value != "AP8=" {
		t.Fatal("SQLite native payload changed")
	}
	if _, err := json.Marshal(result); err != nil {
		t.Fatal("native SQLite result cannot serialize")
	}
	command.ResultValues = ""
	legacy := session.Execute(context.Background(), command)
	if legacy.NativeValues != nil {
		t.Fatal("legacy SQLite request acquired new fields")
	}
}
