package dbtools

import (
	"crypto/x509"
	"io"
	"os"
	"path/filepath"

	"dbeer/helper/internal/protocol"
)

// Utility homes are intentionally isolated from libpq's implicit root.crt and
// client configuration. Bind the reviewed CA bytes to the plan as well as its
// SQL input, so a later edit of the profile's certificate cannot change trust.
func freezeRootCertificate(connection *protocol.Connection, dir string) error {
	if connection.SSLRootCert == "" {
		if connection.DatabaseEngine() == "postgresql" && (connection.SSLMode == "verify-ca" || connection.SSLMode == "verify-full") {
			return safe("PostgreSQL utilities require an explicit CA certificate file for verify-ca and verify-full. Select a CA file in the connection profile and preview again.")
		}
		return nil
	}
	source, before, err := openReadonlyRegular(connection.SSLRootCert)
	if err != nil {
		return safe("The selected TLS CA certificate file is unavailable.")
	}
	defer source.Close()
	const limit = 4 * 1024 * 1024
	if before.Size() <= 0 || before.Size() > limit {
		return safe("Choose a regular PEM CA certificate file of at most 4 MiB.")
	}
	data, err := io.ReadAll(io.LimitReader(source, limit+1))
	after, statErr := source.Stat()
	named, nameErr := os.Stat(connection.SSLRootCert)
	if err != nil || len(data) > limit || statErr != nil || nameErr != nil || !os.SameFile(before, after) || !os.SameFile(after, named) || before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
		return safe("The TLS CA certificate file changed or could not be read. Preview again.")
	}
	if !x509.NewCertPool().AppendCertsFromPEM(data) {
		return safe("The TLS CA certificate file contains no usable PEM certificates.")
	}
	path := filepath.Join(dir, "root-ca.pem")
	if os.WriteFile(path, data, 0400) != nil {
		return safe("The reviewed TLS CA certificate could not be retained privately.")
	}
	connection.SSLRootCert = path
	return nil
}
