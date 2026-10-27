package cassandra

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

type refusingTransport struct{ targets []string }

func (transport *refusingTransport) DialContext(_ context.Context, _, address string) (net.Conn, error) {
	transport.targets = append(transport.targets, address)
	return nil, errors.New("unreachable")
}
func (*refusingTransport) Close() error          { return nil }
func (*refusingTransport) Done() <-chan struct{} { return nil }

func TestTunnelDialsEveryDiscoveredNodeWithoutDirectFallback(t *testing.T) {
	transport := &refusingTransport{}
	config := gocql.NewCluster("10.0.0.11")
	config.ConnectTimeout = time.Second
	settings := protocol.Connection{SSH: &protocol.SSHSettings{}}
	if err := configureTransport(adapter.WithTransport(context.Background(), transport), settings, config); err != nil {
		t.Fatal(err)
	}
	for _, ip := range []string{"10.0.0.11", "10.0.0.12"} {
		host, err := gocql.NewHostInfoFromAddrPort(net.ParseIP(ip), 9042)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := config.HostDialer.DialHost(context.Background(), host); err == nil {
			t.Fatal("unexpected direct fallback")
		}
	}
	if len(transport.targets) != 2 || transport.targets[0] != "10.0.0.11:9042" || transport.targets[1] != "10.0.0.12:9042" {
		t.Fatal("discovered nodes did not use tunnel")
	}
	config.Hosts = []string{"remote-only.invalid"}
	if err := configureTransport(adapter.WithTransport(context.Background(), transport), settings, config); err == nil {
		t.Fatal("unsupported contact-point DNS did not fail before local lookup")
	}
	if err := configureTransport(context.Background(), settings, config); err == nil {
		t.Fatal("SSH silently fell back to direct network")
	}
}
