package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestSSHSettingsValidation(t *testing.T) {
	good := SSHSettings{ProfileID: "profile", Host: "bastion.example", Port: 22, User: "alice", AuthMethod: "agent"}
	if !good.Valid() {
		t.Fatal("valid rejected")
	}
	for _, host := range []string{"-option", "host\nother", "user@host", "host/path", "[::1]", "host name", "host,other", "*.host", "!host", "|host", "#host", "quote\"host", "host;command"} {
		s := good
		s.Host = host
		if s.Valid() {
			t.Errorf("unsafe host %q", host)
		}
	}
	for _, method := range []string{"unknown", "key", ""} {
		s := good
		s.AuthMethod = method
		if s.Valid() {
			t.Errorf("unknown method %q", method)
		}
	}
	s := good
	s.AuthMethod = "privateKey"
	s.IdentityFile = "relative/key"
	if s.Valid() {
		t.Fatal("relative key accepted")
	}
	s.IdentityFile = "/synthetic/key"
	if !s.Valid() {
		t.Fatal("absolute key rejected")
	}
	s.Password = "secret"
	if s.Valid() {
		t.Fatal("mixed method secret accepted")
	}
}
func TestSSHProtocolCommands(t *testing.T) {
	connection := Connection{Host: "db", Port: 5432, Database: "db", User: "user", SSLMode: "verify-full", SSH: &SSHSettings{ProfileID: "profile", Host: "bastion", Port: 22, User: "user", AuthMethod: "agent"}}
	for _, kind := range []string{"ssh.probe", "ssh.trust", "connect"} {
		command := Command{Type: kind, RequestID: "request", Connection: &connection}
		if kind == "ssh.trust" {
			command.SSHTrust = &SSHTrust{Token: "challenge", Replace: true}
		}
		data, _ := json.Marshal(command)
		if _, e := ParseCommand(data); e != nil {
			t.Fatalf("%s: %v", kind, e)
		}
		unsafe := strings.Replace(string(data), `"authMethod":"agent"`, `"authMethod":"agent","unexpected":true`, 1)
		if _, e := ParseCommand([]byte(unsafe)); e == nil {
			t.Fatal("unknown SSH field accepted")
		}
	}
}

func TestOpenSSHConfigurationSettingsAreExplicitAndContainNoCredentials(t *testing.T) {
	good := SSHSettings{ProfileID: "profile", Host: "analytics-route", AuthMethod: "openSSH", ConfigFile: "/synthetic/ssh config"}
	if !good.Valid() {
		t.Fatal("configuration mode rejected")
	}
	for _, mutate := range []func(*SSHSettings){
		func(s *SSHSettings) { s.Port = 22 }, func(s *SSHSettings) { s.User = "user" },
		func(s *SSHSettings) { s.IdentityFile = "/synthetic/key" }, func(s *SSHSettings) { s.Password = "secret" },
		func(s *SSHSettings) { s.Passphrase = "secret" }, func(s *SSHSettings) { s.ConfigFile = "relative/config" },
		func(s *SSHSettings) { s.ConfigFile = "/synthetic/config\nHost *" }, func(s *SSHSettings) { s.ConfigFile = "/${UNTRUSTED}/config" },
	} {
		bad := good
		mutate(&bad)
		if bad.Valid() {
			t.Fatal("ambiguous configuration accepted")
		}
	}
	good.ConfigFile = ""
	if !good.Valid() {
		t.Fatal("default configuration rejected")
	}
	good.AuthMethod = "agent"
	good.Port = 22
	good.User = "user"
	good.ConfigFile = "/synthetic/config"
	if good.Valid() {
		t.Fatal("configuration file accepted in explicit mode")
	}
}
