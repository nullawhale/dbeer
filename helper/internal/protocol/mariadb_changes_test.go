package protocol

import (
	"encoding/json"
	"testing"
)

func TestMariaDBChangesRetainDistinctEngineAndStrictValues(t *testing.T) {
	raw := []byte(`{"type":"changes.preview","requestId":"fixture","sessionId":"owner","queryId":"query","changes":{"schema":"fixture","table":"items","columns":[{"name":"id","engine":"mariadb","nativeType":"int(11)"},{"name":"payload","engine":"mariadb","nativeType":"longtext"}],"changes":[{"kind":"update","original":[{"kind":"text","value":"1"},{"kind":"null"}],"values":[{"column":"payload","value":{"kind":"text","value":"{\"a\":1, \"a\":2}"}}],"storageToken":"mariadb.storage.v1:fixture"}]}}`)
	command, err := ParseCommand(raw)
	if err != nil || command.Changes == nil || !command.Changes.Valid() || command.Changes.Columns[1].Engine != "mariadb" || *command.Changes.Changes[0].Values[0].Value.Value != "{\"a\":1, \"a\":2}" {
		t.Fatal("native engine or textual JSON changes were altered")
	}
	for _, engine := range []string{"mysqlAlias", "unknown", ""} {
		var changed map[string]any
		if json.Unmarshal(raw, &changed) != nil {
			t.Fatal("request clone failed")
		}
		changed["changes"].(map[string]any)["columns"].([]any)[0].(map[string]any)["engine"] = engine
		bad, _ := json.Marshal(changed)
		if _, err := ParseCommand(bad); err == nil {
			t.Fatal("unknown engine admitted by row edit protocol")
		}
	}
}
