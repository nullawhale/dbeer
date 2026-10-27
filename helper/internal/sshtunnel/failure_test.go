package sshtunnel

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

// The fixture runs an actual sshd with an owned host key and authorized client
// key. Only the fixture's process group is stopped, including accepted children.
type failureSSHD struct {
	t                                     *testing.T
	root, identity, key, config, username string
	port                                  int
	process                               *exec.Cmd
}

func newFailureSSHD(t *testing.T, forwarding bool) *failureSSHD {
	t.Helper()
	requireConfigurationIntegration(t)
	root := t.TempDir()
	current, err := user.Current()
	if err != nil {
		t.Fatal("cannot identify the fixture user")
	}
	f := &failureSSHD{t: t, root: root, username: current.Username,
		identity: filepath.Join(root, "client"), key: filepath.Join(root, "host"), config: filepath.Join(root, "sshd")}
	for _, key := range []string{f.identity, f.key} {
		if exec.Command("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key).Run() != nil {
			t.Fatal("cannot generate fixture key")
		}
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f.port = listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	forward := "no"
	if forwarding {
		forward = "local"
	}
	config := fmt.Sprintf("Port %d\nListenAddress 127.0.0.1\nHostKey %s\nPidFile %s\nAuthorizedKeysFile %s\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nAllowUsers %s\nAllowTcpForwarding %s\nPermitTTY no\nForceCommand /usr/bin/false\nLogLevel ERROR\nPerSourcePenalties no\nMaxStartups 100\n", f.port, f.key, f.config+".pid", f.identity+".pub", f.username, forward)
	if os.WriteFile(f.config, []byte(config), 0600) != nil {
		t.Fatal("cannot write fixture configuration")
	}
	t.Cleanup(f.stop)
	f.start()
	return f
}

func (f *failureSSHD) start() {
	f.process = exec.Command("/usr/sbin/sshd", "-D", "-e", "-f", f.config)
	f.process.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if f.process.Start() != nil {
		f.t.Fatal("cannot start fixture sshd")
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(f.port)), 30*time.Millisecond)
		if err == nil {
			c.Close()
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	f.t.Fatal("fixture sshd did not become ready")
}
func (f *failureSSHD) stop() {
	if f.process != nil {
		_ = syscall.Kill(-f.process.Process.Pid, syscall.SIGKILL)
		_ = f.process.Wait()
		f.process = nil
	}
}
func (f *failureSSHD) settings() *protocol.SSHSettings {
	return &protocol.SSHSettings{ProfileID: "failure-fixture", Host: "127.0.0.1", Port: f.port,
		User: f.username, AuthMethod: "privateKey", IdentityFile: f.identity}
}
func trustFailureFixture(t *testing.T, m *Manager, s *protocol.SSHSettings) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	probe, err := m.Probe(ctx, s)
	if err != nil || probe.Status != "unknown" {
		t.Fatal("fresh fixture was not an unknown host")
	}
	if m.Trust(ctx, s, probe.ChallengeToken) != nil {
		t.Fatal("cannot trust the exact fixture key")
	}
}

func TestSSHConfigurationMissingAndRefusingAgentCannotFallback(t *testing.T) {
	f := newFailureSSHD(t, true)
	for _, agent := range []string{"", filepath.Join(t.TempDir(), "missing-agent")} {
		t.Run(fmt.Sprintf("missing-%t", agent == ""), func(t *testing.T) {
			t.Setenv("SSH_AUTH_SOCK", agent)
			m := testManager(t)
			s := f.settings()
			s.AuthMethod, s.IdentityFile = "agent", ""
			trustFailureFixture(t, m, s)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			lease, err := m.Acquire(ctx, s)
			if lease != nil {
				lease.Close()
			}
			if err == nil {
				t.Fatal("missing agent fell back to another authentication method")
			}
		})
	}
	t.Run("refused-signature", func(t *testing.T) {
		// Advertise the actual authorized public key, then reject OpenSSH's
		// signature request. This proves a refusing agent cannot fall back to
		// password authentication or an unrelated private key.
		agentRoot, err := os.MkdirTemp("/tmp", "dbeer-refusing-agent-")
		if err != nil {
			t.Fatal(err)
		}
		defer os.RemoveAll(agentRoot)
		socket := filepath.Join(agentRoot, "agent")
		listener, err := net.Listen("unix", socket)
		if err != nil {
			t.Fatal(err)
		}
		defer listener.Close()
		public, err := os.ReadFile(f.identity + ".pub")
		if err != nil {
			t.Fatal(err)
		}
		fields := strings.Fields(string(public))
		if len(fields) < 2 {
			t.Fatal("invalid authorized fixture key")
		}
		key, err := base64.StdEncoding.DecodeString(fields[1])
		if err != nil {
			t.Fatal(err)
		}
		var refused atomic.Int32
		go func() {
			for {
				conn, err := listener.Accept()
				if err != nil {
					return
				}
				go func() {
					defer conn.Close()
					for {
						var header [4]byte
						if _, err := io.ReadFull(conn, header[:]); err != nil {
							return
						}
						size := binary.BigEndian.Uint32(header[:])
						if size < 1 || size > 65536 {
							return
						}
						request := make([]byte, int(size))
						if _, err := io.ReadFull(conn, request); err != nil {
							return
						}
						response := []byte{5}
						if request[0] == 11 {
							response = []byte{12, 0, 0, 0, 1}
							response = binary.BigEndian.AppendUint32(response, uint32(len(key)))
							response = append(response, key...)
							response = append(response, 0, 0, 0, 0)
						} else if request[0] == 13 {
							refused.Add(1)
						}
						reply := binary.BigEndian.AppendUint32(nil, uint32(len(response)))
						if _, err := conn.Write(append(reply, response...)); err != nil {
							return
						}
					}
				}()
			}
		}()
		t.Setenv("SSH_AUTH_SOCK", socket)
		m := testManager(t)
		s := f.settings()
		s.AuthMethod, s.IdentityFile = "agent", ""
		trustFailureFixture(t, m, s)
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		lease, err := m.Acquire(ctx, s)
		if lease != nil {
			lease.Close()
		}
		if err == nil || refused.Load() == 0 {
			t.Fatal("the agent did not refuse a real signature request or authentication bypassed the refusal")
		}
	})
}

func TestSSHConfigurationDeniedForwardingDoesNotReachDestination(t *testing.T) {
	f := newFailureSSHD(t, false)
	m := testManager(t)
	s := f.settings()
	trustFailureFixture(t, m, s)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	lease, err := m.Acquire(ctx, s)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	destination, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer destination.Close()
	if conn, err := lease.DialContext(ctx, "tcp", destination.Addr().String()); err == nil {
		conn.Close()
		t.Fatal("denied SSH forwarding was bypassed")
	}
	destination.(*net.TCPListener).SetDeadline(time.Now().Add(100 * time.Millisecond))
	if conn, err := destination.Accept(); err == nil {
		conn.Close()
		t.Fatal("denied destination received a connection")
	}
}

func TestSSHConfigurationLiveHostKeyChangeRequiresExplicitReplacement(t *testing.T) {
	f := newFailureSSHD(t, true)
	m := testManager(t)
	s := f.settings()
	trustFailureFixture(t, m, s)
	f.stop()
	os.Remove(f.key)
	os.Remove(f.key + ".pub")
	if exec.Command("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", f.key).Run() != nil {
		t.Fatal("cannot rotate fixture host key")
	}
	f.start()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	probe, err := m.Probe(ctx, s)
	if err != nil || probe.Status != "changed" {
		t.Fatal("live changed host key was not reported")
	}
	if lease, err := m.Acquire(ctx, s); err == nil {
		lease.Close()
		t.Fatal("changed host key connected before replacement")
	}
	if m.Trust(ctx, s, probe.ChallengeToken) == nil {
		t.Fatal("changed key was replaced implicitly")
	}
	probe, err = m.Probe(ctx, s)
	if err != nil || probe.Status != "changed" {
		t.Fatal("replacement rejection changed trust")
	}
	if m.Trust(ctx, s, probe.ChallengeToken, true) != nil {
		t.Fatal("explicit host replacement failed")
	}
	lease, err := m.Acquire(ctx, s)
	if err != nil {
		t.Fatal(err)
	}
	lease.Close()
}

func TestSSHConfigurationForwardingPortCollisionRetriesOwnedListener(t *testing.T) {
	f := newFailureSSHD(t, true)
	foreign, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer foreign.Close()
	for _, persistent := range []bool{false, true} {
		t.Run(fmt.Sprintf("persistent-%t", persistent), func(t *testing.T) {
			m := testManager(t)
			s := f.settings()
			trustFailureFixture(t, m, s)
			attempts := 0
			m.forwardingAddress = func() (string, error) {
				attempts++
				if persistent || attempts == 1 {
					return foreign.Addr().String(), nil
				}
				return reserveForwardingAddress()
			}
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			lease, err := m.Acquire(ctx, s)
			if persistent {
				if lease != nil {
					lease.Close()
				}
				var failure *Error
				if !errors.As(err, &failure) || failure.Code != "port_collision" || attempts != 3 {
					t.Fatal("persistent collision did not fail after exactly three attempts")
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				defer lease.Close()
				if attempts != 2 || lease.entry.address == foreign.Addr().String() {
					t.Fatal("collision was not retried onto an owned listener")
				}
			}
		})
	}
}

func TestSSHConfigurationBlockedTCPWriteHonorsDeadline(t *testing.T) {
	f := newFailureSSHD(t, true)
	m := testManager(t)
	s := f.settings()
	trustFailureFixture(t, m, s)
	destination, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer destination.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		conn, err := destination.Accept()
		if err == nil {
			conn.(*net.TCPConn).SetReadBuffer(1024)
			accepted <- conn
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	lease, err := m.Acquire(ctx, s)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	conn, err := lease.DialContext(ctx, "tcp", destination.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	select {
	case server := <-accepted:
		defer server.Close()
	case <-ctx.Done():
		t.Fatal("destination was not reached")
	}
	if conn.SetWriteDeadline(time.Now().Add(150*time.Millisecond)) != nil {
		t.Fatal("write deadline unavailable")
	}
	start := time.Now()
	_, err = io.Copy(conn, io.LimitReader(strings.NewReader(strings.Repeat("x", 32*1024*1024)), 32*1024*1024))
	var timeout net.Error
	if !errors.As(err, &timeout) || !timeout.Timeout() || time.Since(start) > 2*time.Second {
		t.Fatal("blocked SSH TCP write ignored its deadline")
	}
}
