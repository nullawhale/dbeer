package cassandra_test

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/cassandra"
	"dbeer/helper/internal/protocol"
)

// lossProxy understands just the uncompressed protocol-v5 envelope boundary.
// It forwards the real server's successful TRUNCATE completion to nobody, making
// the client observe transport loss after the server has confirmed execution.
// No statement bytes, credentials or results are logged or retained globally.
type lossProxy struct {
	truncated   atomic.Int32
	dropped     atomic.Int32
	mu          sync.Mutex
	closed      bool
	connections []net.Conn
}

func newLossProxy(t *testing.T) *lossProxy {
	t.Helper()
	p := &lossProxy{}
	t.Cleanup(p.Close)
	return p
}

func (p *lossProxy) Close() {
	p.mu.Lock()
	p.closed = true
	connections := p.connections
	p.connections = nil
	p.mu.Unlock()
	for _, connection := range connections {
		connection.Close()
	}
}

// Intercept every driver dial, including discovered peers and reconnects. A
// proxy contact point alone is bypassed when metadata advertises real addresses.
func (p *lossProxy) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	p.mu.Lock()
	closed := p.closed
	p.mu.Unlock()
	if closed {
		return nil, net.ErrClosed
	}
	dialer := &net.Dialer{Timeout: 3 * time.Second}
	server, err := dialer.DialContext(ctx, network, address)
	if err != nil {
		return nil, err
	}
	client, bridge := net.Pipe()
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		client.Close()
		bridge.Close()
		server.Close()
		return nil, net.ErrClosed
	}
	p.connections = append(p.connections, client, bridge, server)
	p.mu.Unlock()
	go p.pipe(bridge, server)
	return lossProxyConn{Conn: client, local: server.LocalAddr(), remote: server.RemoteAddr()}, nil
}

// The driver uses the real TCP address to interpret system.local metadata.
// Preserve it instead of exposing net.Pipe's synthetic address to discovery.
type lossProxyConn struct {
	net.Conn
	local, remote net.Addr
}

func (c lossProxyConn) LocalAddr() net.Addr  { return c.local }
func (c lossProxyConn) RemoteAddr() net.Addr { return c.remote }

func TestCassandraLossProxyPreservesEveryDialTargetAndClosesConnections(t *testing.T) {
	proxy := newLossProxy(t)
	var clients []net.Conn
	for range 2 {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal("cannot create synthetic upstream")
		}
		t.Cleanup(func() { listener.Close() })
		go func() {
			server, err := listener.Accept()
			if err == nil {
				defer server.Close()
				_, _ = io.Copy(server, server)
			}
		}()
		client, err := proxy.DialContext(context.Background(), "tcp", listener.Addr().String())
		if err != nil {
			t.Fatal("fault proxy did not dial the requested upstream")
		}
		clients = append(clients, client)
		if _, ok := client.RemoteAddr().(*net.TCPAddr); !ok || client.RemoteAddr().String() != listener.Addr().String() {
			t.Fatal("fault proxy hid the real upstream TCP address from discovery")
		}
		if err := client.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
			t.Fatal("fault proxy does not support driver deadlines")
		}
		// OPTIONS is unframed, before the protocol-v5 STARTUP/READY transition.
		message := []byte{0x05, 0, 0, 1, 0x05, 0, 0, 0, 0}
		if _, err := client.Write(message); err != nil {
			t.Fatal("fault proxy did not forward the request")
		}
		response := make([]byte, len(message))
		if _, err := io.ReadFull(client, response); err != nil || !bytes.Equal(response, message) {
			t.Fatal("fault proxy did not forward the upstream response")
		}
	}
	proxy.Close()
	for _, client := range clients {
		if _, err := client.Read(make([]byte, 1)); !errors.Is(err, io.ErrClosedPipe) {
			t.Fatal("fault proxy retained an open client connection after cleanup")
		}
	}
	if _, err := proxy.DialContext(context.Background(), "tcp", "127.0.0.1:0"); !errors.Is(err, net.ErrClosed) {
		t.Fatal("fault proxy accepted a new dial after cleanup")
	}
}
func protocolFrame(reader io.Reader, framed bool) ([]byte, []byte, error) {
	size := 9
	if framed {
		size = 6
	}
	header := make([]byte, size)
	if _, err := io.ReadFull(reader, header); err != nil {
		return nil, nil, err
	}
	length := 0
	if !framed {
		length = int(binary.BigEndian.Uint32(header[5:9]))
	}
	if framed {
		length = int(uint32(header[0])|uint32(header[1])<<8|uint32(header[2])<<16) & 0x1ffff
	}
	if length < 0 || length > 16*1024*1024 {
		return nil, nil, io.ErrShortBuffer
	}
	extra := 0
	if framed {
		extra = 4
	}
	body := make([]byte, length+extra)
	if _, err := io.ReadFull(reader, body); err != nil {
		return nil, nil, err
	}
	frame := append(header, body...)
	if framed {
		return frame, body[:length], nil
	}
	return frame, frame, nil
}
func nativeMessage(payload []byte, opcode byte, stream int32) bool {
	return len(payload) >= 9 && payload[4] == opcode && (stream < 0 || int32(binary.BigEndian.Uint16(payload[2:4])) == stream)
}
func (p *lossProxy) pipe(client, server net.Conn) {
	defer client.Close()
	defer server.Close()
	ready := make(chan struct{})
	var closeReady sync.Once
	var framed atomic.Bool
	var stream atomic.Int32
	stream.Store(-1)
	stopped := make(chan struct{})
	go func() {
		defer client.Close()
		defer server.Close()
		defer close(stopped)
		defer closeReady.Do(func() { close(ready) })
		for {
			frame, payload, err := protocolFrame(server, framed.Load())
			if err != nil {
				return
			}
			if framed.Load() && stream.Load() >= 0 && nativeMessage(payload, 0x08, stream.Load()) {
				p.dropped.Add(1)
				client.Close()
				server.Close()
				return
			}
			if _, err := client.Write(frame); err != nil {
				return
			}
			if !framed.Load() && nativeMessage(payload, 0x02, -1) {
				framed.Store(true)
				closeReady.Do(func() { close(ready) })
			}
		}
	}()
	for {
		frame, payload, err := protocolFrame(client, framed.Load())
		if err != nil {
			return
		}
		startup := !framed.Load() && nativeMessage(payload, 0x01, -1)
		if framed.Load() && nativeMessage(payload, 0x07, -1) && strings.Contains(string(payload[9:]), "TRUNCATE dbeer.live_loss") {
			p.truncated.Add(1)
			stream.Store(int32(binary.BigEndian.Uint16(payload[2:4])))
		}
		if _, err := server.Write(frame); err != nil {
			return
		}
		if startup {
			select {
			case <-ready:
			case <-stopped:
				return
			}
		}
	}
}
func TestCassandraLiveLostWriteAcknowledgementIsUnknownAndNotRepeated(t *testing.T) {
	c := liveConnection(t)
	if c.SSLMode != "disable" {
		t.Skip("plaintext fault-proxy fixture is not selected")
	}
	observer := liveOpen(t, c)
	liveSQL(t, observer, "CREATE TABLE IF NOT EXISTS dbeer.live_loss (id int PRIMARY KEY)")
	liveSQL(t, observer, "INSERT INTO dbeer.live_loss (id) VALUES (1)")
	proxy := newLossProxy(t)
	victim := cassandra.NewSessionWithDialerForTest(t, c, proxy)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	result := victim.Execute(ctx, protocol.Command{Type: "execute", RequestID: "lost-ack", SQL: "TRUNCATE dbeer.live_loss"})
	if proxy.dropped.Load() != 1 || proxy.truncated.Load() != 1 {
		t.Fatalf("fault proxy did not discard exactly one real write acknowledgement: requests=%d completions=%d result=%s unknown=%t", proxy.truncated.Load(), proxy.dropped.Load(), result.Type, result.OutcomeUnknown)
	}
	if result.Type != "error" || !result.OutcomeUnknown {
		t.Fatalf("lost write acknowledgement was not unknown: type=%s category=%s", result.Type, result.Category)
	}
	if rows := liveSQL(t, observer, "SELECT id FROM dbeer.live_loss"); len(rows.Rows) != 0 {
		t.Fatal("server did not complete the write whose acknowledgement was lost")
	}
}
