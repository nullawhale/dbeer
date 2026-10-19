package postgres

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func TestPostgresErrorPositionCountsUnicodeScalars(t *testing.T) {
	h := newSQLIntegrationSession(t, 30*time.Second)
	prefix := "SELECT 'κόσμος 🌍', "
	response := h.execute(prefix + "dbeer_missing_column")
	if response.Type != "error" || response.SQLState != "42703" || response.ErrorPosition != utf8.RuneCountInString(prefix)+1 || !response.Connected {
		t.Fatal("PostgreSQL error position did not preserve the one-based Unicode scalar offset")
	}
	frame, err := json.Marshal(response)
	if err != nil || !strings.Contains(string(frame), `"errorPosition":`) {
		t.Fatal("PostgreSQL error position was not carried over the protocol")
	}
}
