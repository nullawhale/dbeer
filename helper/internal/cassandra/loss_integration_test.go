package cassandra_test

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

// lossProxy understands just the uncompressed protocol-v5 envelope boundary.
// It forwards the real server's successful TRUNCATE completion to nobody, making
// the client observe transport loss after the server has confirmed execution.
// No statement bytes, credentials or results are logged or retained globally.
type lossProxy struct {
	listener    net.Listener
	target      string
	truncated   atomic.Int32
	dropped     atomic.Int32
	mu          sync.Mutex
	connections []net.Conn
}

func newLossProxy(t *testing.T, target string) *lossProxy {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal("cannot create isolated fault proxy")
	}
	p := &lossProxy{listener: listener, target: target}
	t.Cleanup(func() {
		listener.Close()
		p.mu.Lock()
		defer p.mu.Unlock()
		for _, c := range p.connections {
			c.Close()
		}
	})
	go func() {
		for {
			client, err := listener.Accept()
			if err != nil {
				return
			}
			server, err := net.DialTimeout("tcp", target, 3*time.Second)
			if err != nil {
				client.Close()
				continue
			}
			p.mu.Lock()
			p.connections = append(p.connections, client, server)
			p.mu.Unlock()
			go p.pipe(client, server)
		}
	}()
	return p
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
	proxy := newLossProxy(t, net.JoinHostPort(c.Host, strconv.Itoa(c.Port)))
	c.Host = "127.0.0.1"
	c.ContactPoints = nil
	c.Port = proxy.listener.Addr().(*net.TCPAddr).Port
	victim := liveOpen(t, c)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	result := victim.Execute(ctx, protocol.Command{Type: "execute", RequestID: "lost-ack", SQL: "TRUNCATE dbeer.live_loss"})
	if proxy.dropped.Load() != 1 || proxy.truncated.Load() != 1 {
		t.Fatal("fault proxy did not discard exactly one real write acknowledgement")
	}
	if result.Type != "error" || !result.OutcomeUnknown {
		t.Fatalf("lost write acknowledgement was not unknown: type=%s category=%s", result.Type, result.Category)
	}
	if rows := liveSQL(t, observer, "SELECT id FROM dbeer.live_loss"); len(rows.Rows) != 0 {
		t.Fatal("server did not complete the write whose acknowledgement was lost")
	}
}
