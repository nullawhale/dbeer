package dbtools

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMariaDBToolNamesVersionAndClientFlavor(t *testing.T) {
	if expectedTool("mariadb", "dump", "sql") != "mariadb-dump" || expectedTool("mariadb", "restore", "sql") != "mariadb" {
		t.Fatal("native utility names changed")
	}
	for _, tt := range []struct {
		output string
		want   bool
	}{
		{"mariadb  Ver 15.1 Distrib 10.11.19-MariaDB, for debian-linux-gnu (aarch64)", true},
		{"mariadb-dump from 11.4.13-MariaDB, client 10.19 for debian-linux-gnu (aarch64)", true},
		{"mysql  Ver 8.4.8 for Linux on aarch64 (MySQL Community Server)", false},
		{"mariadb-dump Ver 10.19 for Linux", false},
	} {
		tool := filepath.Join(t.TempDir(), "mariadb")
		if os.WriteFile(tool, []byte("#!/bin/sh\nprintf '%s\\n' '"+tt.output+"'\n"), 0700) != nil {
			t.Fatal("tool fixture unavailable")
		}
		identity, err := captureTool(tool, "mariadb")
		if err != nil {
			t.Fatal("native tool identity unavailable")
		}
		version, err := probeTool(context.Background(), identity, "mariadb", t.TempDir())
		if (err == nil) != tt.want {
			t.Fatal("a utility's native distribution version or flavor was misclassified")
		}
		if tt.want && version.major != 10 && version.major != 11 {
			t.Fatal("client protocol version was confused with distribution version")
		}
	}
	for _, tt := range []struct {
		tool   toolVersion
		server string
		want   bool
	}{
		{toolVersion{major: 10, minor: 11, patch: 9}, "10.11.19-MariaDB", true}, {toolVersion{major: 11, minor: 4, patch: 3}, "11.4.13-MariaDB", true},
		{toolVersion{major: 10, minor: 11, patch: 8}, "10.11.19-MariaDB", false}, {toolVersion{major: 11, minor: 4, patch: 2}, "11.4.13-MariaDB", false},
		{toolVersion{major: 11, minor: 4, patch: 13}, "10.11.19-MariaDB", true}, {toolVersion{major: 8, minor: 4, patch: 8}, "11.4.13-MariaDB", false},
	} {
		if (compatible("mariadb", tt.tool, tt.server) == nil) != tt.want {
			t.Fatal("native utility line/floor compatibility changed")
		}
	}
}

func TestMariaDBUtilityArgumentsPreserveNativeTLSAndNoReplay(t *testing.T) {
	for _, mode := range []string{"disable", "require", "verify-ca", "verify-full"} {
		t.Run(mode, func(t *testing.T) {
			dir := t.TempDir()
			c := protocol.Connection{Engine: "mariadb", Host: "localhost", Port: 3306, User: "reader", Database: "fixture", Password: "synthetic\"secret\\value\n", SSLMode: mode, SSLRootCert: filepath.Join(dir, "ca.crt")}
			for _, operation := range []string{"dump", "restore"} {
				args, _, err := utilityArguments(protocol.DatabaseToolsRequest{Operation: operation, Format: "sql"}, PreparedConnection{Connection: c, PeerFingerprint: func() string {
					if mode != "disable" {
						return strings.Repeat("a", 64)
					}
					return ""
				}()}, dir)
				if err != nil {
					t.Fatal("supported native argument mapping failed")
				}
				for _, arg := range args {
					if strings.Contains(arg, c.Password) || strings.HasPrefix(arg, "--ssl-mode=") || strings.HasPrefix(arg, "--set-gtid-purged=") || strings.HasPrefix(arg, "--column-statistics=") {
						t.Fatal("password or MySQL-only utility option escaped into native arguments")
					}
				}
				if mode == "disable" {
					if !slices.Contains(args, "--skip-ssl") || slices.Contains(args, "--ssl-ca="+c.SSLRootCert) {
						t.Fatal("disabled TLS was reenabled by a CA argument")
					}
				} else if !slices.Contains(args, "--ssl") || !slices.Contains(args, "--tls-version=TLSv1.2,TLSv1.3") {
					t.Fatal("TLS enforcement or minimum disappeared")
				}
				if mode == "verify-full" && !slices.Contains(args, "--ssl-verify-server-cert") {
					t.Fatal("native hostname verification disappeared")
				}
				if mode == "verify-ca" && (!slices.Contains(args, "--ssl-ca="+c.SSLRootCert) || !slices.Contains(args, "--skip-ssl-verify-server-cert")) {
					t.Fatal("chain-only native verification changed")
				}
				if operation == "dump" && !slices.Contains(args, "--dump-history") {
					t.Fatal("native timestamp history was omitted from the logical backup")
				}
				if operation == "restore" && (!slices.Contains(args, "--binary-mode") || !slices.Contains(args, "--skip-reconnect") || !slices.Contains(args, "--local-infile=0")) {
					t.Fatal("restore gained client-command, local file or replay authority")
				}
			}
			data, err := os.ReadFile(filepath.Join(dir, "mariadb.cnf"))
			info, e := os.Stat(filepath.Join(dir, "mariadb.cnf"))
			if err != nil || e != nil || info.Mode().Perm() != 0600 || !strings.Contains(string(data), `password="synthetic\"secret\\value\n"`) {
				t.Fatal("private native credential representation changed")
			}
		})
	}
	for _, c := range []protocol.Connection{{Engine: "mariadb", SSLMode: "verify-ca"}, {Engine: "mariadb", SSLMode: "verify-full", SSH: &protocol.SSHSettings{}}, {Engine: "mariadb", SSLMode: "prefer"}} {
		if _, err := mariaDBArguments(protocol.DatabaseToolsRequest{Operation: "restore", Format: "sql"}, PreparedConnection{Connection: c}, t.TempDir()); err == nil {
			t.Fatal("an unrepresentable TLS policy silently weakened")
		}
	}
}

func TestMariaDBUtilityCertificatePinIsPrivateAndStrict(t *testing.T) {
	for _, value := range []string{"", strings.Repeat("0", 63), strings.Repeat("0", 65), strings.Repeat("g", 64), strings.Repeat("A", 64)} {
		if mariaDBFingerprint(value) {
			t.Fatal("invalid certificate pin admitted")
		}
	}
	c := protocol.Connection{Engine: "mariadb", SSLMode: "verify-full"}
	args, err := mariaDBArguments(protocol.DatabaseToolsRequest{Operation: "restore", Format: "sql"}, PreparedConnection{Connection: c, PeerFingerprint: strings.Repeat("a", 64)}, t.TempDir())
	if err != nil || !slices.Contains(args, "--ssl-fp="+strings.Repeat("a", 64)) {
		t.Fatal("verified certificate pin was omitted")
	}
	c.SSLMode = "disable"
	if _, err = mariaDBArguments(protocol.DatabaseToolsRequest{Operation: "restore", Format: "sql"}, PreparedConnection{Connection: c, PeerFingerprint: strings.Repeat("a", 64)}, t.TempDir()); err == nil {
		t.Fatal("unverified connection accepted certificate authority")
	}
}
