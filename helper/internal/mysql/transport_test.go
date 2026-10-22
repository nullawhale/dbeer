package mysql

import (
	"context"
	"errors"
	"net"
	"testing"

	"dbeer/helper/internal/protocol"
)

type refusingTransport struct{ targets []string }

func (transport *refusingTransport) DialContext(_ context.Context, _, address string) (net.Conn, error) {
	transport.targets = append(transport.targets, address)
	return nil, errors.New("unreachable")
}
func (*refusingTransport) Close() error          { return nil }
func (*refusingTransport) Done() <-chan struct{} { return nil }

func TestTunnelControlsUseCapturedGenerationWithFreshContext(t *testing.T) {
	settings := protocol.Connection{Host: "mysql.remote-only.invalid", Port: 3306, Database: "test", User: "test", SSLMode: "verify-full", SSH: &protocol.SSHSettings{}}
	transport := &refusingTransport{}
	for range 2 {
		if _, err := dialWithTransport(context.Background(), settings, transport); err == nil {
			t.Fatal("unexpected direct fallback")
		}
	}
	if len(transport.targets) != 2 || transport.targets[0] != settings.Host+":3306" || transport.targets[1] != transport.targets[0] {
		t.Fatal("auxiliary connection escaped leased generation")
	}
	if _, err := dialWithTransport(context.Background(), settings, nil); err == nil {
		t.Fatal("SSH silently fell back to direct network")
	}
}
