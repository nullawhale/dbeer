package sshtunnel

import (
	"context"
	"io"
	"net"
	"strconv"
	"time"
)

// DialContext returns the actual TCP socket so adapter read/write deadlines and
// PostgreSQL cancellation retain their usual semantics. Destination names are
// sent to the bastion and are never resolved through the client's DNS.
func (l *Lease) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	if network != "tcp" && network != "tcp4" && network != "tcp6" {
		return nil, failure("destination", "SSH forwarding requires a TCP destination.")
	}
	select {
	case <-l.Done():
		return nil, failure("connection_lost", "The SSH tunnel disconnected.")
	default:
	}
	host, portText, e := net.SplitHostPort(address)
	port, portErr := strconv.Atoi(portText)
	if e != nil || portErr != nil || port < 1 || port > 65535 || host == "" || len(host) > 255 {
		return nil, failure("destination", "Invalid SSH forwarding destination.")
	}
	conn, e := (&net.Dialer{}).DialContext(ctx, "tcp", l.entry.address)
	if e != nil {
		return nil, failure("connection_lost", "Cannot reach the SSH tunnel.")
	}
	success := false
	defer func() {
		if !success {
			conn.Close()
		}
	}()
	deadline := time.Now().Add(15 * time.Second)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	conn.SetDeadline(deadline)
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	if _, e = conn.Write([]byte{5, 1, 0}); e != nil {
		return nil, failure("forwarding", "SSH forwarding failed.")
	}
	var greeting [2]byte
	if _, e = io.ReadFull(conn, greeting[:]); e != nil || greeting != [2]byte{5, 0} {
		return nil, failure("forwarding", "SSH forwarding failed.")
	}
	request := []byte{5, 1, 0, 3, byte(len(host))}
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			request = append([]byte{5, 1, 0, 1}, v4...)
		} else {
			request = append([]byte{5, 1, 0, 4}, ip.To16()...)
		}
	} else {
		request = append(request, host...)
	}
	request = append(request, byte(port>>8), byte(port))
	if _, e = conn.Write(request); e != nil {
		return nil, failure("forwarding", "SSH forwarding failed.")
	}
	var response [4]byte
	if _, e = io.ReadFull(conn, response[:]); e != nil || response[0] != 5 || response[1] != 0 || response[2] != 0 {
		return nil, failure("forwarding", "The SSH server cannot reach the database destination.")
	}
	size := 0
	switch response[3] {
	case 1:
		size = 4
	case 4:
		size = 16
	case 3:
		var n [1]byte
		if _, e = io.ReadFull(conn, n[:]); e != nil {
			return nil, failure("forwarding", "SSH forwarding failed.")
		}
		size = int(n[0])
	default:
		return nil, failure("forwarding", "SSH forwarding failed.")
	}
	tail := make([]byte, size+2)
	if _, e = io.ReadFull(conn, tail); e != nil {
		return nil, failure("forwarding", "SSH forwarding failed.")
	}
	conn.SetDeadline(time.Time{})
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	select {
	case <-l.Done():
		return nil, failure("connection_lost", "The SSH tunnel disconnected.")
	default:
	}
	success = true
	return conn, nil
}
