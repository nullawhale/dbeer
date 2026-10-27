package cassandra

import (
	"context"
	"crypto/tls"
	"net"
	"strings"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

type tunnelHostDialer struct {
	transport adapter.Transport
	tlsConfig *tls.Config
	timeout   time.Duration
}

func (dialer tunnelHostDialer) DialHost(ctx context.Context, host *gocql.HostInfo) (*gocql.DialedHost, error) {
	ctx, cancel := context.WithTimeout(ctx, dialer.timeout)
	defer cancel()
	conn, err := dialer.transport.DialContext(ctx, "tcp", host.ConnectAddressAndPort())
	if err != nil {
		return nil, err
	}
	// HostDialer also owns TLS: use each node's identity, never the SOCKS
	// endpoint or the first contact point's name for every discovered node.
	return gocql.WrapTLS(ctx, conn, host.HostnameAndPort(), dialer.tlsConfig)
}

func configureTransport(ctx context.Context, connection protocol.Connection, config *gocql.ClusterConfig) error {
	transport := adapter.TransportFromContext(ctx)
	if transport == nil {
		if connection.SSH != nil {
			return &adapter.ConnectionError{Category: "ssh", Message: "The SSH transport is unavailable."}
		}
		return nil
	}
	// gocql resolves contact points before invoking HostDialer. Reject names
	// explicitly instead of sending DNS outside the SSH transport. Discovered
	// node addresses are numeric and use this same dialer on every reconnect.
	for _, host := range config.Hosts {
		if net.ParseIP(strings.Trim(host, "[]")) == nil {
			return &adapter.ConnectionError{Category: "validation", Message: "Cassandra over SSH requires numeric IP contact points reachable from the SSH server."}
		}
	}
	var tlsConfig *tls.Config
	if config.SslOpts != nil {
		tlsConfig = config.SslOpts.Config.Clone()
	}
	config.HostDialer = tunnelHostDialer{transport: transport, tlsConfig: tlsConfig, timeout: config.ConnectTimeout}
	return nil
}
