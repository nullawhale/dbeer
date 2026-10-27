package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPasswordCommandValidation(t *testing.T) {
	base := Connection{Engine: "postgresql", Host: "localhost", Port: 5432, Database: "app", User: "reader", SSLMode: "require",
		PasswordCommand: &PasswordCommand{Executable: "/synthetic/token-cli", Arguments: []string{"token", "literal $HOME"}}}
	data, err := json.Marshal(Command{Type: "connect", RequestID: "password-command", Connection: &base})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseCommand(data); err != nil {
		t.Fatal("valid password command rejected")
	}
	for _, change := range []func(*Connection){
		func(c *Connection) { c.PasswordCommand.Executable = "token-cli" },
		func(c *Connection) { c.PasswordCommand.Arguments = []string{"\x00"} },
		func(c *Connection) { c.PasswordCommand.Arguments = make([]string, 129) },
		func(c *Connection) { c.PasswordCommand.Arguments = []string{strings.Repeat("x", 65536)} },
		func(c *Connection) { c.Password = "ambiguous" },
		func(c *Connection) { c.User = "" },
	} {
		c := base
		p := *base.PasswordCommand
		c.PasswordCommand = &p
		change(&c)
		if c.Valid() {
			t.Fatal("invalid credential settings accepted")
		}
	}
	for _, raw := range []string{`null`, `{}`, `{"executable":"/bin/echo","arguments":null}`, `{"executable":"/bin/echo","arguments":[],"shell":true}`} {
		var fields map[string]json.RawMessage
		if json.Unmarshal(data, &fields) != nil {
			t.Fatal("fixture")
		}
		var connection map[string]json.RawMessage
		json.Unmarshal(fields["connection"], &connection)
		connection["passwordCommand"] = json.RawMessage(raw)
		fields["connection"], _ = json.Marshal(connection)
		invalid, _ := json.Marshal(fields)
		if _, err := ParseCommand(invalid); err == nil {
			t.Fatal("malformed provider accepted")
		}
	}
}
