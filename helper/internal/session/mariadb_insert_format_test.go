package session

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func TestMariaDBOfflineFormattingUsesNormalManagerWithoutOwner(t *testing.T) {
	var opened atomic.Int32
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		opened.Add(1)
		return blockingSession(), nil
	})
	defer manager.Close()
	raw := []byte(`{"type":"formatInserts","requestId":"native-offline","insert":{"engine":"mariadb","schema":"fixture","table":"items","columns":[{"name":"payload"}],"rows":[[{"kind":"null"}],[{"kind":"text","value":""}],[{"kind":"text","value":"NULL"}],[{"kind":"default"}]]}}`)
	command, err := protocol.ParseCommand(raw)
	if err != nil {
		t.Fatal("native offline framed request refused")
	}
	submit(t, manager, command)
	response := receive(t, manager)
	if response.Type != "insertSQL" || response.SessionID != "" || response.QueryID != "" || opened.Load() != 0 || !strings.Contains(response.SQL, "CONVERT(X'' USING utf8mb4)") || !strings.Contains(response.SQL, "4e554c4c") || !strings.Contains(response.SQL, "(DEFAULT)") {
		t.Fatal("native offline format opened an owner, executed SQL or changed values")
	}
}
