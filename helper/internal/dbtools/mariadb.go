package dbtools

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"dbeer/helper/internal/protocol"
)

var mariaDBToolVersion = regexp.MustCompile(`(?i)(?:Distrib|from) ([0-9]+)\.([0-9]+)\.([0-9]+)-MariaDB\b`)

func mariaDBCompatible(v toolVersion, server string) error {
	major, minor, err := serverMajor(server)
	if err != nil || !(major == 10 && minor == 11 || major == 11 && minor == 4) {
		return fmt.Errorf("MariaDB utilities support the reviewed 10.11 and 11.4 server lines.")
	}
	if v.major == 11 && v.minor == 4 && v.patch >= 3 {
		return nil
	}
	if major == 10 && v.major == 10 && v.minor == 11 && v.patch >= 9 {
		return nil
	}
	return fmt.Errorf("Choose MariaDB 11.4.3 or later 11.4 utilities for this server. Native 10.11.9+ tools are also supported with a 10.11 server and disabled TLS.")
}

func mariaDBArguments(r protocol.DatabaseToolsRequest, p PreparedConnection, dir string) ([]string, error) {
	c := p.Connection
	if r.Format != "sql" {
		return nil, fmt.Errorf("MariaDB logical dump and restore use SQL format.")
	}
	host, port := p.Host, p.Port
	if host == "" {
		host = c.Host
	}
	if port == 0 {
		port = c.Port
	}
	escape := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`, "\r", `\r`, "\t", `\t`, "\b", `\b`)
	defaults := filepath.Join(dir, "mariadb.cnf")
	if os.WriteFile(defaults, []byte("[client]\npassword=\""+escape.Replace(c.Password)+"\"\n"), 0600) != nil {
		return nil, errTool
	}
	args := []string{"--defaults-file=" + defaults, "--protocol=TCP", "--host=" + host, fmt.Sprintf("--port=%d", port), "--user=" + c.User, "--default-character-set=utf8mb4"}
	switch c.SSLMode {
	case "disable":
		args = append(args, "--skip-ssl")
	case "require":
		args = append(args, "--ssl", "--skip-ssl-verify-server-cert", "--tls-version=TLSv1.2,TLSv1.3")
	case "verify-ca":
		if c.SSLRootCert == "" {
			return nil, fmt.Errorf("Choose an explicit trusted CA file for MariaDB utility verify-ca mode.")
		}
		args = append(args, "--ssl", "--skip-ssl-verify-server-cert", "--ssl-ca="+c.SSLRootCert, "--tls-version=TLSv1.2,TLSv1.3")
	case "verify-full":
		if c.SSH != nil {
			return nil, fmt.Errorf("MariaDB utilities cannot preserve the original verified hostname through the SSH forwarding endpoint. Use a direct verified utility connection.")
		}
		args = append(args, "--ssl", "--ssl-verify-server-cert", "--tls-version=TLSv1.2,TLSv1.3")
		if c.SSLRootCert != "" {
			args = append(args, "--ssl-ca="+c.SSLRootCert)
		}
	default:
		return nil, fmt.Errorf("Choose an explicit supported MariaDB TLS mode.")
	}
	if c.SSLMode != "disable" && !mariaDBFingerprint(p.PeerFingerprint) {
		return nil, fmt.Errorf("A certificate observed during the reviewed TLS preflight is required.")
	}
	if p.PeerFingerprint != "" {
		if !mariaDBFingerprint(p.PeerFingerprint) || c.SSLMode != "require" && c.SSLMode != "verify-ca" && c.SSLMode != "verify-full" {
			return nil, fmt.Errorf("The reviewed utility certificate pin is invalid.")
		}
		args = append(args, "--ssl-fp="+p.PeerFingerprint)
	}
	if r.Operation == "dump" {
		args = append(args, "--single-transaction", "--dump-history", "--quick", "--skip-lock-tables", "--skip-add-locks", "--routines", "--events", "--triggers", "--hex-blob", "--", c.Database)
	} else {
		args = append(args, "--binary-mode", "--batch", "--skip-column-names", "--skip-reconnect", "--local-infile=0", "--database="+c.Database)
	}
	return args, nil
}

func mariaDBFingerprint(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
