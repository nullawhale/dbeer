package sshtest

import (
	"context"
	"net"
	"os"
	"os/exec"
	"sync"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/cassandra"
	"dbeer/helper/internal/protocol"
)

type observedSSHTransport struct {
	adapter.Transport
	mu          sync.Mutex
	connections map[string][]net.Conn
	dials       map[string]int
}

func (p *observedSSHTransport) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	conn, err := p.Transport.DialContext(ctx, network, address)
	p.mu.Lock()
	defer p.mu.Unlock()
	p.dials[address]++
	if err == nil {
		p.connections[address] = append(p.connections[address], conn)
	}
	return conn, err
}
func (p *observedSSHTransport) Close() error {
	p.mu.Lock()
	for _, conns := range p.connections {
		for _, conn := range conns {
			conn.Close()
		}
	}
	p.connections = map[string][]net.Conn{}
	p.mu.Unlock()
	return p.Transport.Close()
}
func TestSSHCassandraUnavailableNodeRecoversThroughTheSameTunnel(t *testing.T) {
	root, ssh := fixture(t)
	database := databaseSettings(t, root)
	if database.Engine != "cassandra" {
		t.Skip("requires the three-node Cassandra SSH fixture")
	}
	node, address := os.Getenv("DBEER_TEST_SSH_CASSANDRA_FAILURE_NODE"), os.Getenv("DBEER_TEST_SSH_CASSANDRA_FAILURE_ADDRESS")
	if node == "" || address == "" {
		t.Fatal("required owned node-failure fixture is missing")
	}
	manager := newManager(t)
	trust(t, manager, &ssh)
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Second)
	defer cancel()
	lease, err := manager.Acquire(ctx, &ssh)
	if err != nil {
		t.Fatal(err)
	}
	transport := &observedSSHTransport{Transport: lease, connections: map[string][]net.Conn{}, dials: map[string]int{}}
	defer transport.Close()
	database.SSH = &ssh
	physical, err := cassandra.Open(adapter.WithTransport(ctx, transport), database)
	if err != nil {
		t.Fatal(err)
	}
	defer physical.Close()
	status := func() string {
		response := physical.Execute(ctx, protocol.Command{Type: "catalog", Catalog: &protocol.CatalogRequest{Kind: "clusterNodes"}})
		if response.Type != "query.result" {
			t.Fatal("cluster snapshot unavailable")
		}
		for _, row := range response.Rows {
			if len(row) >= 2 && row[0] != nil && row[1] != nil && *row[0] == address {
				return *row[1]
			}
		}
		return "MISSING"
	}
	if status() != "UP" {
		t.Fatal("owned failure node was not initially discovered as available")
	}
	transport.mu.Lock()
	initial := transport.dials[address]
	transport.mu.Unlock()
	if initial == 0 {
		t.Fatal("discovered node bypassed the SSH transport")
	}
	if exec.Command("docker", "pause", node).Run() != nil {
		t.Fatal("cannot pause the owned Cassandra node")
	}
	paused := true
	defer func() {
		if paused && exec.Command("docker", "unpause", node).Run() != nil {
			t.Error("cannot restore the owned Cassandra node")
		}
	}()
	// Model the network disconnect caused by losing this exact node. Closing
	// only its actual SSH forwarded sockets avoids waiting for TCP keepalive;
	// all other discovered-node connections remain live in the same lease.
	transport.mu.Lock()
	connections := append([]net.Conn(nil), transport.connections[address]...)
	transport.mu.Unlock()
	for _, conn := range connections {
		conn.Close()
	}
	deadline := time.Now().Add(35 * time.Second)
	for status() != "DOWN" {
		if time.Now().After(deadline) {
			t.Fatal("driver did not retain the unavailable discovered node as DOWN")
		}
		time.Sleep(100 * time.Millisecond)
	}
	query(t, physical, "SELECT release_version FROM system.local")
	if exec.Command("docker", "unpause", node).Run() != nil {
		t.Fatal("cannot resume the owned Cassandra node")
	}
	paused = false
	deadline = time.Now().Add(45 * time.Second)
	for status() != "UP" {
		if time.Now().After(deadline) {
			t.Fatal("recovered node was not rediscovered through the live SSH lease")
		}
		time.Sleep(100 * time.Millisecond)
	}
	transport.mu.Lock()
	reconnected := transport.dials[address] > initial
	transport.mu.Unlock()
	if !reconnected {
		t.Fatal("recovered node did not open a new connection through SSH")
	}
	query(t, physical, "SELECT release_version FROM system.local")
}
