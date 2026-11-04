package dbtools

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"dbeer/helper/internal/protocol"
)

var serverVersionPattern = regexp.MustCompile(`^([0-9]+)(?:\.([0-9]+))?`)

func serverMajor(value string) (int, int, error) {
	match := serverVersionPattern.FindStringSubmatch(value)
	if len(match) != 3 {
		return 0, 0, errTool
	}
	major, _ := strconv.Atoi(match[1])
	minor, _ := strconv.Atoi(match[2])
	return major, minor, nil
}
func expectedTool(engine, operation, format string) string {
	if engine == "mysql" {
		if operation == "dump" {
			return "mysqldump"
		}
		return "mysql"
	}
	if operation == "dump" {
		return "pg_dump"
	}
	if format == "sql" {
		return "psql"
	}
	return "pg_restore"
}
func compatible(engine string, v toolVersion, server string) error {
	major, minor, err := serverMajor(server)
	if err != nil {
		return err
	}
	if engine == "postgresql" {
		if major < 16 || major > 18 || v.major != major {
			return fmt.Errorf("Choose PostgreSQL %d utilities to match this server's major version.", major)
		}
		return nil
	}
	if major != 8 || minor != 0 && minor != 4 || v.major != major || v.minor != minor {
		return fmt.Errorf("Choose MySQL %d.%d utilities to match this server version.", major, minor)
	}
	return nil
}
func supportsRestrict(v toolVersion) bool {
	return v.major >= 18 || v.major == 17 && v.minor >= 6 || v.major == 16 && v.minor >= 10
}

func utilityArguments(r protocol.DatabaseToolsRequest, p PreparedConnection, dir string) ([]string, []string, error) {
	env := baseEnvironment(dir)
	connection := p.Connection
	if connection.DatabaseEngine() == "postgresql" {
		password := strings.NewReplacer(`\`, `\\`, `:`, `\:`, "\n", "", "\r", "").Replace(connection.Password)
		if strings.ContainsAny(connection.Password, "\r\n") {
			return nil, nil, fmt.Errorf("PostgreSQL utility passwords containing line breaks are unsupported by password files.")
		}
		escape := strings.NewReplacer(`\`, `\\`, `:`, `\:`)
		passfile := filepath.Join(dir, "pgpass")
		host := p.Host
		if host == "" {
			host = connection.Host
		}
		port := p.Port
		if port == 0 {
			port = connection.Port
		}
		entry := escape.Replace(host) + ":" + strconv.Itoa(port) + ":" + escape.Replace(connection.Database) + ":" + escape.Replace(connection.User) + ":" + password + "\n"
		if os.WriteFile(passfile, []byte(entry), 0600) != nil {
			return nil, nil, errTool
		}
		// libpq otherwise prefers GSS encryption when ambient Kerberos tickets
		// are available, bypassing the explicitly reviewed TLS verification.
		env = append(env, "PGPASSFILE="+passfile, "PGHOST="+host, "PGPORT="+strconv.Itoa(port), "PGUSER="+connection.User, "PGDATABASE="+connection.Database, "PGSSLMODE="+connection.SSLMode, "PGGSSENCMODE=disable", "PGAPPNAME=DBeer database tools", "PGCONNECT_TIMEOUT=10")
		if p.HostAddr != "" {
			env = append(env, "PGHOSTADDR="+p.HostAddr)
		}
		if connection.SSLRootCert != "" {
			env = append(env, "PGSSLROOTCERT="+connection.SSLRootCert)
		}
		if r.Operation == "dump" {
			format := map[string]string{"custom": "custom", "sql": "plain", "tar": "tar"}[r.Format]
			args := []string{"--no-password", "--format=" + format}
			if r.Format == "sql" {
				args = append(args, "--clean", "--if-exists")
			}
			return args, env, nil
		}
		if r.Format == "sql" {
			return []string{"--no-psqlrc", "--no-password", "--set=ON_ERROR_STOP=1", "--single-transaction", "--file=-"}, env, nil
		}
		return []string{"--no-password", "--clean", "--if-exists", "--single-transaction", "--exit-on-error", "--dbname="}, env, nil
	}
	host := p.Host
	if host == "" {
		host = connection.Host
	}
	port := p.Port
	if port == 0 {
		port = connection.Port
	}
	mode := map[string]string{"disable": "DISABLED", "require": "REQUIRED", "verify-ca": "VERIFY_CA", "verify-full": "VERIFY_IDENTITY"}[connection.SSLMode]
	if mode == "" {
		return nil, nil, fmt.Errorf("Choose an explicit supported MySQL TLS mode.")
	}
	if connection.SSH != nil && mode == "VERIFY_IDENTITY" {
		return nil, nil, fmt.Errorf("MySQL utilities cannot preserve verify-identity TLS through the SSH endpoint. Use a direct verified connection.")
	}
	escape := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`, "\r", `\r`, "\t", `\t`, "\b", `\b`)
	defaults := filepath.Join(dir, "mysql.cnf")
	if os.WriteFile(defaults, []byte("[client]\npassword=\""+escape.Replace(connection.Password)+"\"\n"), 0600) != nil {
		return nil, nil, errTool
	}
	args := []string{"--defaults-file=" + defaults, "--protocol=TCP", "--host=" + host, "--port=" + strconv.Itoa(port), "--user=" + connection.User, "--ssl-mode=" + mode, "--default-character-set=utf8mb4"}
	if connection.SSLRootCert != "" {
		args = append(args, "--ssl-ca="+connection.SSLRootCert)
	}
	if r.Operation == "dump" {
		args = append(args, "--single-transaction", "--quick", "--skip-lock-tables", "--skip-add-locks", "--routines", "--events", "--triggers", "--hex-blob", "--set-gtid-purged=OFF", "--column-statistics=0", "--no-tablespaces", "--", connection.Database)
	} else {
		args = append(args, "--binary-mode", "--batch", "--skip-column-names", "--skip-reconnect", "--local-infile=0", "--database="+connection.Database)
	}
	return args, env, nil
}
