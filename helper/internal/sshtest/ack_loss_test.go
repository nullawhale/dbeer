package sshtest

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/cassandra"
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/postgres"
	"dbeer/helper/internal/protocol"
)

// ackLossTransport forwards all traffic through a real leased SSH connection.
// It drops only the selected server completion, after independently counting
// execution requests. Plaintext framing is confined to disposable test traffic.
type ackLossTransport struct {
	adapter.Transport
	engine            string
	requests, dropped atomic.Int32
	prepared          sync.Map
	mu                sync.Mutex
	connections       []net.Conn
}

func (p *ackLossTransport) Close() error {
	p.mu.Lock()
	connections := p.connections
	p.connections = nil
	p.mu.Unlock()
	for _, c := range connections {
		c.Close()
	}
	return p.Transport.Close()
}
func (p *ackLossTransport) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	upstream, err := p.Transport.DialContext(ctx, network, address)
	if err != nil {
		return nil, err
	}
	client, bridge := net.Pipe()
	p.mu.Lock()
	p.connections = append(p.connections, client, bridge, upstream)
	p.mu.Unlock()
	go func() {
		defer bridge.Close()
		defer upstream.Close()
		switch p.engine {
		case "postgresql":
			p.postgres(bridge, upstream)
		case "mysql":
			p.mysql(bridge, upstream)
		case "cassandra":
			p.cassandra(bridge, upstream)
		}
	}()
	return addressedConnection{Conn: client, local: upstream.LocalAddr(), remote: upstream.RemoteAddr()}, nil
}

type addressedConnection struct {
	net.Conn
	local, remote net.Addr
}

func (c addressedConnection) LocalAddr() net.Addr  { return c.local }
func (c addressedConnection) RemoteAddr() net.Addr { return c.remote }
func packet(reader io.Reader, headerSize int, length func([]byte) int) ([]byte, error) {
	header := make([]byte, headerSize)
	if _, err := io.ReadFull(reader, header); err != nil {
		return nil, err
	}
	n := length(header)
	if n < 0 || n > 16*1024*1024 {
		return nil, io.ErrShortBuffer
	}
	result := make([]byte, len(header)+n)
	copy(result, header)
	_, err := io.ReadFull(reader, result[len(header):])
	return result, err
}
func pgPacket(r io.Reader) ([]byte, error) {
	return packet(r, 5, func(h []byte) int { return int(binary.BigEndian.Uint32(h[1:])) - 4 })
}
func (p *ackLossTransport) postgres(client, server net.Conn) {
	defer client.Close()
	defer server.Close()
	go func() {
		defer client.Close()
		defer server.Close()
		for {
			frame, err := pgPacket(server)
			if err != nil {
				return
			}
			if frame[0] == 'C' && bytes.Equal(frame[5:], []byte("COMMIT\x00")) {
				p.dropped.Add(1)
				return
			}
			if _, err = client.Write(frame); err != nil {
				return
			}
		}
	}()
	// PostgreSQL's startup packet is the sole untyped client message.
	startup, err := packet(client, 4, func(h []byte) int { return int(binary.BigEndian.Uint32(h)) - 4 })
	if err != nil {
		return
	}
	if _, err = server.Write(startup); err != nil {
		return
	}
	commitStatement := ""
	boundCommit := false
	for {
		frame, err := pgPacket(client)
		if err != nil {
			return
		}
		body := frame[5:]
		switch frame[0] {
		case 'P':
			parts := bytes.SplitN(body, []byte{0}, 3)
			if len(parts) >= 2 && strings.EqualFold(strings.TrimSpace(string(parts[1])), "COMMIT") {
				commitStatement = string(parts[0])
			}
		case 'B':
			parts := bytes.SplitN(body, []byte{0}, 3)
			boundCommit = len(parts) >= 2 && commitStatement != "" && string(parts[1]) == commitStatement
		case 'E':
			if boundCommit {
				p.requests.Add(1)
				boundCommit = false
			}
		case 'Q':
			if strings.EqualFold(strings.TrimSpace(strings.TrimRight(string(body), "\x00")), "COMMIT") {
				p.requests.Add(1)
			}
		}
		if _, err = server.Write(frame); err != nil {
			return
		}
	}
}
func myPacket(r io.Reader) ([]byte, error) {
	return packet(r, 4, func(h []byte) int { return int(h[0]) | int(h[1])<<8 | int(h[2])<<16 })
}
func (p *ackLossTransport) mysql(client, server net.Conn) {
	defer client.Close()
	defer server.Close()
	var commit atomic.Bool
	go func() {
		defer client.Close()
		defer server.Close()
		for {
			frame, err := myPacket(server)
			if err != nil {
				return
			}
			if commit.Load() && len(frame) > 4 && frame[3] == 1 && frame[4] == 0 {
				p.dropped.Add(1)
				return
			}
			if _, err = client.Write(frame); err != nil {
				return
			}
		}
	}()
	for {
		frame, err := myPacket(client)
		if err != nil {
			return
		}
		// CLIENT_QUERY_ATTRIBUTES prefixes a zero parameter count and one
		// parameter set even when the application supplies no attributes.
		if len(frame) > 5 && frame[3] == 0 && frame[4] == 3 && strings.EqualFold(strings.TrimSpace(string(bytes.TrimPrefix(frame[5:], []byte{0, 1}))), "COMMIT") {
			p.requests.Add(1)
			commit.Store(true)
		}
		if _, err = server.Write(frame); err != nil {
			return
		}
	}
}
func cqlPacket(r io.Reader, framed bool) ([]byte, []byte, error) {
	if !framed {
		f, e := packet(r, 9, func(h []byte) int { return int(binary.BigEndian.Uint32(h[5:9])) })
		return f, f, e
	}
	f, e := packet(r, 6, func(h []byte) int { return int(uint32(h[0])|uint32(h[1])<<8|uint32(h[2])<<16)&0x1ffff + 4 })
	if e != nil {
		return nil, nil, e
	}
	return f, f[6 : len(f)-4], nil
}
func cqlMessage(payload []byte, opcode byte, stream int32) bool {
	return len(payload) >= 9 && payload[4] == opcode && (stream < 0 || int32(binary.BigEndian.Uint16(payload[2:4])) == stream)
}
func (p *ackLossTransport) cassandra(client, server net.Conn) {
	defer client.Close()
	defer server.Close()
	ready := make(chan struct{})
	var readyOnce sync.Once
	var framed atomic.Bool
	var stream atomic.Int32
	stream.Store(-1)
	var preparing atomic.Int32
	preparing.Store(-1)
	go func() {
		defer client.Close()
		defer server.Close()
		defer readyOnce.Do(func() { close(ready) })
		for {
			frame, payload, err := cqlPacket(server, framed.Load())
			if err != nil {
				return
			}
			if framed.Load() && preparing.Load() >= 0 && cqlMessage(payload, 8, preparing.Load()) && len(payload) >= 15 && binary.BigEndian.Uint32(payload[9:13]) == 4 {
				size := int(binary.BigEndian.Uint16(payload[13:15]))
				if size > 0 && 15+size <= len(payload) {
					p.prepared.Store(string(payload[15:15+size]), true)
				}
				preparing.Store(-1)
			}
			if framed.Load() && stream.Load() >= 0 && cqlMessage(payload, 8, stream.Load()) {
				p.dropped.Add(1)
				return
			}
			if _, err = client.Write(frame); err != nil {
				return
			}
			if !framed.Load() && cqlMessage(payload, 2, -1) {
				framed.Store(true)
				readyOnce.Do(func() { close(ready) })
			}
		}
	}()
	for {
		frame, payload, err := cqlPacket(client, framed.Load())
		if err != nil {
			return
		}
		startup := !framed.Load() && cqlMessage(payload, 1, -1)
		target := len(payload) >= 9 && bytes.Contains(payload[9:], []byte("INSERT INTO dbeer_ssh_fault.lwt_loss"))
		if framed.Load() && cqlMessage(payload, 9, -1) && target {
			preparing.Store(int32(binary.BigEndian.Uint16(payload[2:4])))
		}
		execute := false
		if framed.Load() && cqlMessage(payload, 10, -1) && len(payload) >= 11 {
			size := int(binary.BigEndian.Uint16(payload[9:11]))
			if size > 0 && 11+size <= len(payload) {
				_, execute = p.prepared.Load(string(payload[11 : 11+size]))
			}
		}
		if framed.Load() && (cqlMessage(payload, 7, -1) && target || execute) {
			p.requests.Add(1)
			stream.Store(int32(binary.BigEndian.Uint16(payload[2:4])))
		}
		if _, err = server.Write(frame); err != nil {
			return
		}
		if startup {
			<-ready
		}
	}
}

func TestSSHExactCommitOrLWTAcknowledgementLossIsUnknownWithoutRetry(t *testing.T) {
	root, ssh := fixture(t)
	database := databaseSettings(t, root)
	observerManager := newManager(t)
	trust(t, observerManager, &ssh)
	observer := open(t, observerManager, &ssh, database)
	var prepare, mutation, verify, cleanup string
	switch database.Engine {
	case "postgresql", "mysql":
		prepare = "CREATE TABLE dbeer_ssh_commit_loss (id int PRIMARY KEY)"
		mutation = "INSERT INTO dbeer_ssh_commit_loss VALUES (1)"
		verify = "SELECT count(*) FROM dbeer_ssh_commit_loss"
		cleanup = "DROP TABLE IF EXISTS dbeer_ssh_commit_loss"
	case "cassandra":
		prepare = "CREATE TABLE IF NOT EXISTS dbeer_ssh_fault.lwt_loss (id int PRIMARY KEY, value int)"
		mutation = "INSERT INTO dbeer_ssh_fault.lwt_loss (id,value) VALUES (1,7) IF NOT EXISTS"
		verify = "SELECT value FROM dbeer_ssh_fault.lwt_loss WHERE id=1"
		cleanup = "DROP KEYSPACE IF EXISTS dbeer_ssh_fault"
	}
	query(t, observer, cleanup)
	if database.Engine == "cassandra" {
		query(t, observer, "CREATE KEYSPACE dbeer_ssh_fault WITH replication = {'class':'SimpleStrategy','replication_factor':3}")
	}
	query(t, observer, prepare)
	defer query(t, observer, cleanup)
	manager := newManager(t)
	trust(t, manager, &ssh)
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Second)
	defer cancel()
	lease, err := manager.Acquire(ctx, &ssh)
	if err != nil {
		t.Fatal(err)
	}
	proxy := &ackLossTransport{Transport: lease, engine: database.Engine}
	defer proxy.Close()
	database.SSH = &ssh
	var victim adapter.Session
	transportCtx := adapter.WithTransport(ctx, proxy)
	switch database.Engine {
	case "postgresql":
		victim, err = postgres.Open(transportCtx, database)
	case "mysql":
		victim, err = mysql.Open(transportCtx, database)
	case "cassandra":
		victim, err = cassandra.Open(transportCtx, database)
	}
	if err != nil {
		t.Fatal("cannot open the SSH acknowledgement-loss fixture")
	}
	defer victim.Close()
	statement := mutation
	if database.Engine != "cassandra" {
		query(t, victim, "BEGIN")
		query(t, victim, mutation)
		statement = "COMMIT"
	}
	result := victim.Execute(ctx, protocol.Command{Type: "execute", RequestID: "lost-ack", QueryID: "lost-ack", SQL: statement})
	if proxy.requests.Load() != 1 || proxy.dropped.Load() != 1 {
		t.Fatalf("fault fixture did not discard exactly one actual completion: requests=%d completions=%d", proxy.requests.Load(), proxy.dropped.Load())
	}
	if result.Type != "error" || !result.OutcomeUnknown {
		t.Fatalf("lost acknowledgement did not retain uncertainty: type=%s category=%s", result.Type, result.Category)
	}
	stored := query(t, observer, verify)
	expected := "1"
	if database.Engine == "cassandra" {
		expected = "7"
	}
	if len(stored.Rows) != 1 || len(stored.Rows[0]) != 1 || stored.Rows[0][0] == nil || *stored.Rows[0][0] != expected {
		t.Fatal("independent SSH observer did not confirm the acknowledged server mutation")
	}
}
