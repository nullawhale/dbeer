// Package mysql isolates the direct go-mysql client behind one physical session.
package mysql

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/credential"
	"dbeer/helper/internal/protocol"
	"github.com/go-mysql-org/go-mysql/client"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

const ConnectTimeout = 5 * time.Second
const ExecuteTimeout = 30 * time.Second
const RecoveryTimeout = 5 * time.Second

type connection struct {
	client    *client.Conn
	transport net.Conn
}

func invalidSettings(message string) error {
	return &adapter.ConnectionError{Category: "validation", Message: message}
}

func tlsConfiguration(settings protocol.Connection) (*tls.Config, error) {
	if settings.Host == "" || strings.ContainsAny(settings.Host, "/,\x00") ||
		settings.Database == "" || settings.User == "" || settings.Port < 1 || settings.Port > 65535 {
		return nil, invalidSettings("Invalid MySQL connection settings.")
	}
	for _, value := range []string{settings.Database, settings.User, settings.Password, settings.SSLRootCert} {
		if strings.ContainsRune(value, 0) {
			return nil, invalidSettings("Invalid MySQL connection settings.")
		}
	}
	switch settings.SSLMode {
	case "disable":
		return nil, nil
	case "allow", "prefer":
		return nil, invalidSettings("MySQL supports disable, require, verify-ca and verify-full TLS modes. Select one explicitly.")
	case "require", "verify-ca", "verify-full":
	default:
		return nil, invalidSettings("Invalid MySQL TLS mode.")
	}
	config := &tls.Config{MinVersion: tls.VersionTLS12, ServerName: settings.Host}
	if settings.SSLMode == "require" {
		// Encryption only is an explicit user choice; no plaintext fallback.
		config.InsecureSkipVerify = true
		return config, nil
	}
	if settings.SSLRootCert != "" {
		pem, err := os.ReadFile(settings.SSLRootCert)
		if err != nil {
			return nil, invalidSettings("The MySQL trusted CA file cannot be read.")
		}
		config.RootCAs = x509.NewCertPool()
		if !config.RootCAs.AppendCertsFromPEM(pem) {
			return nil, invalidSettings("The MySQL trusted CA file is invalid.")
		}
	}
	if settings.SSLMode == "verify-ca" {
		// Go's default verification includes hostname validation. verify-ca
		// deliberately verifies the full chain without the hostname check.
		config.InsecureSkipVerify = true
		config.VerifyConnection = func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) == 0 {
				return errors.New("server certificate missing")
			}
			intermediates := x509.NewCertPool()
			for _, certificate := range state.PeerCertificates[1:] {
				intermediates.AddCert(certificate)
			}
			_, err := state.PeerCertificates[0].Verify(x509.VerifyOptions{
				Roots: config.RootCAs, Intermediates: intermediates,
				KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
			})
			return err
		}
	}
	return config, nil
}

func dial(ctx context.Context, settings protocol.Connection) (*connection, error) {
	return dialWithTransport(ctx, settings, adapter.TransportFromContext(ctx))
}

func dialWithTransport(ctx context.Context, settings protocol.Connection, tunnel adapter.Transport) (*connection, error) {
	if settings.SSH != nil && tunnel == nil {
		return nil, invalidSettings("The SSH transport is unavailable.")
	}
	tlsConfig, err := tlsConfiguration(settings)
	if err != nil {
		return nil, err
	}
	password, err := credential.Password(ctx, settings)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, ConnectTimeout)
	defer cancel()
	var transport net.Conn
	dialer := func(ctx context.Context, network, address string) (net.Conn, error) {
		var conn net.Conn
		var err error
		if tunnel != nil {
			conn, err = tunnel.DialContext(ctx, "tcp", address)
		} else {
			conn, err = (&net.Dialer{}).DialContext(ctx, "tcp", address)
		}
		if err != nil {
			return nil, err
		}
		transport = conn
		if deadline, ok := ctx.Deadline(); ok {
			_ = conn.SetDeadline(deadline)
		}
		return conn, nil
	}
	conn, err := client.ConnectWithDialer(ctx, "tcp", net.JoinHostPort(settings.Host, strconv.Itoa(settings.Port)),
		settings.User, password, settings.Database, dialer, func(conn *client.Conn) error {
			conn.SetTLSConfig(tlsConfig)
			// Never grant local-file access or multiple user statements.
			conn.UnsetCapability(wire.CLIENT_LOCAL_FILES)
			conn.UnsetCapability(wire.CLIENT_MULTI_STATEMENTS)
			// Procedures can return many results from one COM_QUERY. Legacy EOF
			// framing lets the adapter stream subsequent results without using
			// the driver's buffering ExecuteMultiple implementation.
			conn.UnsetCapability(wire.CLIENT_DEPRECATE_EOF)
			if err := conn.SetCapability(wire.CLIENT_MULTI_RESULTS); err != nil {
				return err
			}
			if err := conn.SetCapability(wire.CLIENT_PS_MULTI_RESULTS); err != nil {
				return err
			}
			return conn.SetCollation("utf8mb4_general_ci")
		})
	if err != nil {
		if transport != nil {
			_ = transport.Close()
		}
		return nil, err
	}
	return &connection{client: conn, transport: transport}, nil
}
