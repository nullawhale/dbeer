package postgres

import (
	"context"
	"net"
	"strconv"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

// pgx uses RemoteAddr for CancelRequest. A SOCKS socket's real peer is the
// local proxy, so expose the original target to keep cancellation in the same
// leased tunnel rather than accidentally asking the proxy to cancel a query.
type remoteAddress struct{ address string }

func (address remoteAddress) Network() string { return "tcp" }
func (address remoteAddress) String() string  { return address.address }

type forwardedConnection struct {
	net.Conn
	target net.Addr
}

func (connection forwardedConnection) RemoteAddr() net.Addr { return connection.target }

func configureTransport(ctx context.Context, connection protocol.Connection, config *pgx.ConnConfig) error {
	transport := adapter.TransportFromContext(ctx)
	if transport == nil {
		if connection.SSH != nil {
			return &adapter.ConnectionError{Category: "ssh", Message: "The SSH transport is unavailable."}
		}
		return nil
	}
	// Return the hostname unchanged. Resolution belongs to the bastion and TLS
	// continues validating the original database identity from ParseConfig.
	config.LookupFunc = func(_ context.Context, host string) ([]string, error) { return []string{host}, nil }
	target := net.JoinHostPort(connection.Host, strconv.Itoa(connection.Port))
	config.DialFunc = func(ctx context.Context, network, address string) (net.Conn, error) {
		conn, err := transport.DialContext(ctx, network, address)
		if err != nil {
			return nil, err
		}
		return forwardedConnection{Conn: conn, target: remoteAddress{target}}, nil
	}
	return nil
}
