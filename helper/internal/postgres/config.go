// Package postgres owns the helper's single PostgreSQL session.
package postgres

import (
	"errors"
	"os"
	"strconv"
	"strings"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgconn/ctxwatch"
)

const ConnectTimeout = 5 * time.Second

// pgx reads PG* environment variables even when a connection string explicitly
// supplies credentials (PGSERVICE can still load a file). The dedicated helper
// calls this once at startup, before it starts its reader/owner goroutines.
func clearPostgresEnvironment() {
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if strings.HasPrefix(name, "PG") {
			_ = os.Unsetenv(name)
		}
	}
}

func connectionConfig(connection protocol.Connection) (*pgx.ConnConfig, error) {
	if connection.Host == "" || strings.Contains(connection.Host, ",") || connection.Database == "" || connection.User == "" || connection.Port < 1 || connection.Port > 65535 {
		return nil, errors.New("Invalid connection settings.")
	}
	switch connection.SSLMode {
	case "disable", "allow", "prefer", "require", "verify-ca", "verify-full":
	default:
		return nil, errors.New("Invalid connection settings.")
	}
	values := []string{connection.Host, connection.Database, connection.User, connection.Password, connection.SSLRootCert}
	for _, value := range values {
		if strings.ContainsRune(value, 0) {
			return nil, errors.New("Invalid connection settings.")
		}
	}
	quote := func(value string) string {
		return "'" + strings.ReplaceAll(strings.ReplaceAll(value, `\`, `\\`), `'`, `\'`) + "'"
	}
	// Empty passfile/client-certificate paths suppress libpq file defaults. The
	// explicit CA field still uses pgx's standard sslmode semantics.
	dsn := "host=" + quote(connection.Host) + " port=" + strconv.Itoa(connection.Port) +
		" dbname=" + quote(connection.Database) + " user=" + quote(connection.User) +
		" password=" + quote(connection.Password) + " sslmode=" + quote(connection.SSLMode) +
		" sslrootcert=" + quote(connection.SSLRootCert) +
		" sslcert='' sslkey='' passfile='/dev/null' connect_timeout=5 application_name='DBeer'"
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		// ParseConfigError retains its input DSN, including the password.
		return nil, errors.New("Connection settings or TLS certificate are invalid.")
	}
	config.Password = connection.Password
	config.ConnectTimeout = ConnectTimeout
	config.BuildContextWatcherHandler = func(conn *pgconn.PgConn) ctxwatch.Handler {
		return &pgconn.CancelRequestContextWatcherHandler{Conn: conn, CancelRequestDelay: 0, DeadlineDelay: 5 * time.Second}
	}
	return config, nil
}
