// Package mongodb implements the document adapter using the official Go driver.
package mongodb

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"net"
	"os"
	"strconv"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

func clientOptions(connection protocol.Connection) (*options.ClientOptions, error) {
	if connection.DatabaseEngine() != "mongodb" || !connection.Valid() {
		return nil, &adapter.ConnectionError{Category: "connection", Message: "The MongoDB connection settings are invalid."}
	}
	hosts := connection.ContactPoints
	if len(hosts) == 0 {
		hosts = []string{connection.Host}
	}
	addresses := make([]string, len(hosts))
	for i, host := range hosts {
		addresses[i] = net.JoinHostPort(host, strconv.Itoa(connection.Port))
	}
	opts := options.Client().SetHosts(addresses).SetAppName("DBeer").SetConnectTimeout(10 * time.Second).
		SetServerSelectionTimeout(10 * time.Second).SetTimeout(30 * time.Second).
		SetMaxPoolSize(2).SetMinPoolSize(0).SetMaxConnecting(1).
		SetRetryReads(false).SetRetryWrites(false)
	if connection.MongoDB != nil {
		opts.SetDirect(connection.MongoDB.DirectConnection)
		if connection.MongoDB.ReplicaSet != "" {
			opts.SetReplicaSet(connection.MongoDB.ReplicaSet)
		}
	}
	if connection.SSLMode != "disable" {
		config := &tls.Config{MinVersion: tls.VersionTLS12}
		if connection.SSLRootCert != "" {
			data, err := os.ReadFile(connection.SSLRootCert)
			if err != nil {
				return nil, &adapter.ConnectionError{Category: "tls", Message: "The MongoDB CA certificate could not be read."}
			}
			roots, err := x509.SystemCertPool()
			if err != nil {
				roots = x509.NewCertPool()
			}
			if !roots.AppendCertsFromPEM(data) {
				return nil, &adapter.ConnectionError{Category: "tls", Message: "The MongoDB CA certificate is invalid."}
			}
			config.RootCAs = roots
		}
		opts.SetTLSConfig(config)
	}
	return opts, nil
}

// A leased SSH transport receives logical MongoDB addresses, preserving TLS
// hostname validation. Direct mode prevents unexpected topology discovery.
func bindTransport(ctx context.Context, connection protocol.Connection, opts *options.ClientOptions) {
	if transport := adapter.TransportFromContext(ctx); transport != nil {
		opts.SetDialer(transport)
	}
}
