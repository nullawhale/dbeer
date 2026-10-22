package postgres

import (
	"context"
	"net"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type testTransport struct {
	addresses []string
	peers     []net.Conn
}

func (transport *testTransport) DialContext(_ context.Context, network, address string) (net.Conn, error) {
	transport.addresses = append(transport.addresses, address)
	a, b := net.Pipe()
	transport.peers = append(transport.peers, b)
	return a, nil
}
func (*testTransport) Close() error          { return nil }
func (*testTransport) Done() <-chan struct{} { return nil }

func TestTunnelPreservesRemoteDNSAndCancellationTarget(t *testing.T) {
	cleanEnvironment(t)
	settings := protocol.Connection{Host: "database.only-at-bastion.invalid", Port: 5432, User: "test", Database: "test", SSLMode: "verify-full", SSH: &protocol.SSHSettings{}}
	config, err := connectionConfig(settings)
	if err != nil {
		t.Fatal(err)
	}
	transport := &testTransport{}
	defer func() {
		for _, peer := range transport.peers {
			peer.Close()
		}
	}()
	if err := configureTransport(adapter.WithTransport(context.Background(), transport), settings, config); err != nil {
		t.Fatal(err)
	}
	hosts, err := config.LookupFunc(context.Background(), settings.Host)
	if err != nil || len(hosts) != 1 || hosts[0] != settings.Host {
		t.Fatal("DNS escaped tunnel")
	}
	work, err := config.DialFunc(context.Background(), "tcp", hosts[0]+":5432")
	if err != nil {
		t.Fatal(err)
	}
	defer work.Close()
	// This is the address pgconn.CancelRequest obtains from the work socket.
	cancel, err := config.DialFunc(context.Background(), work.RemoteAddr().Network(), work.RemoteAddr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer cancel.Close()
	if len(transport.addresses) != 2 || transport.addresses[0] != settings.Host+":5432" || transport.addresses[1] != transport.addresses[0] {
		t.Fatal("cancellation did not use original database through same transport")
	}
	if config.TLSConfig.ServerName != settings.Host || config.TLSConfig.InsecureSkipVerify {
		t.Fatal("TLS identity changed")
	}
	if err := configureTransport(context.Background(), settings, config); err == nil {
		t.Fatal("SSH silently fell back to direct network")
	}
}
