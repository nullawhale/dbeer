package sshtunnel

import (
	"context"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"dbeer/helper/internal/protocol"
)

type Options struct {
	KnownHostsPath   string
	SystemKnownHosts []string
}
type Manager struct {
	mu               sync.Mutex
	entries          map[string]*entry
	challenges       map[string]challenge
	knownHosts       string
	systemKnownHosts []string
	temp             string
	closed           bool
}
type entry struct {
	key         string
	refs        int
	ready, done chan struct{}
	doneOnce    sync.Once
	cancel      context.CancelFunc
	stop        func()
	address     string
	exited      <-chan struct{}
	err         error
}
type Lease struct {
	manager *Manager
	entry   *entry
	once    sync.Once
}

func NewManager() (*Manager, error) {
	config, e := os.UserConfigDir()
	if e != nil {
		return nil, failure("initialization", "Cannot locate the SSH trust store.")
	}
	home, e := os.UserHomeDir()
	if e != nil {
		return nil, failure("initialization", "Cannot locate SSH host-key records.")
	}
	return NewManagerWithOptions(Options{filepath.Join(config, "DBeer", "ssh_known_hosts"), []string{filepath.Join(home, ".ssh", "known_hosts"), filepath.Join(home, ".ssh", "known_hosts2"), "/etc/ssh/ssh_known_hosts", "/etc/ssh/ssh_known_hosts2"}})
}
func NewManagerWithOptions(o Options) (*Manager, error) {
	if !filepath.IsAbs(o.KnownHostsPath) {
		return nil, failure("initialization", "Invalid SSH trust-store location.")
	}
	temp, e := os.MkdirTemp("/tmp", "dbeer-ssh-")
	if e != nil {
		return nil, failure("initialization", "Cannot initialize SSH transport.")
	}
	return &Manager{entries: map[string]*entry{}, challenges: map[string]challenge{}, knownHosts: o.KnownHostsPath, systemKnownHosts: o.SystemKnownHosts, temp: temp}, nil
}
func (m *Manager) Acquire(ctx context.Context, s *protocol.SSHSettings) (*Lease, error) {
	if s == nil || !s.Valid() {
		return nil, failure("invalid_settings", "Invalid SSH settings.")
	}
	if e := ctx.Err(); e != nil {
		return nil, e
	}
	key := generation(s)
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return nil, failure("closed", "SSH transport has closed.")
	}
	e := m.entries[key]
	if e == nil {
		startCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		e = &entry{key: key, ready: make(chan struct{}), done: make(chan struct{}), cancel: cancel}
		m.entries[key] = e
		settings := *s
		go m.start(startCtx, e, &settings)
	}
	e.refs++
	m.mu.Unlock()
	lease := &Lease{manager: m, entry: e}
	select {
	case <-ctx.Done():
		lease.Close()
		return nil, ctx.Err()
	case <-e.ready:
	}
	m.mu.Lock()
	err := e.err
	m.mu.Unlock()
	if err != nil {
		lease.Close()
		return nil, err
	}
	if ctx.Err() != nil {
		lease.Close()
		return nil, ctx.Err()
	}
	return lease, nil
}
func (l *Lease) Done() <-chan struct{} { return l.entry.done }
func (l *Lease) Err() error            { l.manager.mu.Lock(); defer l.manager.mu.Unlock(); return l.entry.err }
func (l *Lease) Close() error {
	last := false
	l.once.Do(func() {
		m := l.manager
		m.mu.Lock()
		e := l.entry
		e.refs--
		if e.refs == 0 {
			last = true
			if m.entries[e.key] == e {
				delete(m.entries, e.key)
			}
			e.cancel()
			if e.stop != nil {
				e.stop()
			}
			e.doneOnce.Do(func() { close(e.done) })
		}
		m.mu.Unlock()
	})
	if last {
		l.manager.waitForEntry(l.entry, time.Now().Add(3*time.Second))
	}
	return nil
}
func (m *Manager) waitForEntry(e *entry, deadline time.Time) {
	if e.ready == nil {
		return
	}
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return
	}
	timer := time.NewTimer(remaining)
	defer timer.Stop()
	select {
	case <-e.ready:
	case <-timer.C:
		return
	}
	m.mu.Lock()
	exited := e.exited
	m.mu.Unlock()
	if exited != nil {
		select {
		case <-exited:
		case <-timer.C:
		}
	}
}
func (m *Manager) Close() error {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return nil
	}
	m.closed = true
	entries := make([]*entry, 0, len(m.entries))
	for _, e := range m.entries {
		entries = append(entries, e)
		e.cancel()
		if e.stop != nil {
			e.stop()
		}
		e.doneOnce.Do(func() { close(e.done) })
	}
	m.entries = map[string]*entry{}
	m.challenges = map[string]challenge{}
	m.mu.Unlock()
	deadline := time.Now().Add(3 * time.Second)
	for _, e := range entries {
		m.waitForEntry(e, deadline)
	}
	_ = os.Remove(m.temp)
	return nil
}
func (m *Manager) start(ctx context.Context, e *entry, s *protocol.SSHSettings) {
	address, stop, exited, err := m.launch(ctx, s)
	s.Password = ""
	s.Passphrase = ""
	m.mu.Lock()
	e.address = address
	e.stop = stop
	e.exited = exited
	e.err = err
	abandoned := m.closed || e.refs == 0
	if err != nil || abandoned {
		if stop != nil {
			stop()
		}
		if err == nil {
			e.err = failure("closed", "SSH transport has closed.")
		}
		e.doneOnce.Do(func() { close(e.done) })
	}
	close(e.ready)
	m.mu.Unlock()
	if err != nil || abandoned {
		return
	}
	<-exited
	m.mu.Lock()
	if e.err == nil {
		e.err = failure("connection_lost", "The SSH tunnel disconnected.")
	}
	if m.entries[e.key] == e {
		delete(m.entries, e.key)
	}
	e.doneOnce.Do(func() { close(e.done) })
	m.mu.Unlock()
}
func (m *Manager) launch(ctx context.Context, s *protocol.SSHSettings) (string, func(), <-chan struct{}, error) {
	for attempt := 0; attempt < 3; attempt++ {
		address, stop, exited, err := m.launchAttempt(ctx, s)
		if e, ok := err.(*Error); ok && e.Code == "port_collision" && ctx.Err() == nil {
			continue
		}
		return address, stop, exited, err
	}
	return "", nil, nil, failure("port_collision", "Cannot allocate an owned SSH forwarding port.")
}
func (m *Manager) launchAttempt(ctx context.Context, s *protocol.SSHSettings) (string, func(), <-chan struct{}, error) {
	probe, err := m.Probe(ctx, s)
	if err != nil {
		return "", nil, nil, err
	}
	if probe.Status != "trusted" {
		return "", nil, nil, failure("host_key_untrusted", "Review and trust the SSH server key before connecting.")
	}
	// Use exactly the probed trusted key on the authenticated connection. No
	// global known_hosts mutation or OpenSSH automatic host-key updates occur.
	// Find the exact key again from trusted records (fingerprint from Probe).
	m.mu.Lock()
	records, readErr := readRecords(m.knownHosts, managedEndpoint(s))
	for _, p := range m.systemKnownHosts {
		r, x := readRecords(p, endpoint(s))
		if x != nil {
			readErr = x
		}
		records = append(records, r...)
	}
	m.mu.Unlock()
	if readErr != nil {
		return "", nil, nil, readErr
	}
	var pinned hostKey
	for _, r := range records {
		if r.marker == "" && r.key.fingerprint() == probe.Fingerprint {
			pinned = r.key
			break
		}
	}
	if pinned.blob == "" {
		return "", nil, nil, failure("host_key_changed", "The SSH server key changed during connection.")
	}
	dir, err := os.MkdirTemp(m.temp, "tunnel-")
	if err != nil {
		return "", nil, nil, failure("initialization", "Cannot initialize SSH transport.")
	}
	cleanup := true
	defer func() {
		if cleanup {
			os.RemoveAll(dir)
		}
	}()
	known := filepath.Join(dir, "known_hosts")
	if os.WriteFile(known, []byte(endpoint(s)+" "+pinned.algorithm+" "+pinned.blob+"\n"), 0600) != nil {
		return "", nil, nil, failure("initialization", "Cannot initialize SSH host-key verification.")
	}
	// Reserving and handing off a port has a race; ExitOnForwardFailure plus an
	// owned control socket proves this SSH process owns the final listener.
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return "", nil, nil, failure("initialization", "Cannot allocate SSH forwarding.")
	}
	address := listener.Addr().String()
	listener.Close()
	control := filepath.Join(dir, "control")
	args := []string{"-F", "/dev/null", "-N", "-T", "-M", "-S", control, "-D", address, "-p", strconv.Itoa(s.Port), "-l", s.User,
		"-o", "ExitOnForwardFailure=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + known, "-o", "GlobalKnownHostsFile=/dev/null", "-o", "UpdateHostKeys=no", "-o", "CheckHostIP=no", "-o", "HostKeyAlgorithms=" + hostKeyAlgorithms(pinned.algorithm),
		"-o", "ConnectTimeout=10", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no", "-o", "ControlPersist=no", "-o", "NumberOfPasswordPrompts=1"}
	switch s.AuthMethod {
	case "agent":
		if os.Getenv("SSH_AUTH_SOCK") == "" {
			return "", nil, nil, failure("agent_unavailable", "The SSH agent is unavailable.")
		}
		args = append(args, "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-o", "IdentityFile=none", "-o", "BatchMode=yes")
	case "privateKey":
		if info, x := os.Stat(s.IdentityFile); x != nil || !info.Mode().IsRegular() {
			return "", nil, nil, failure("identity_file", "The selected SSH private key is unavailable.")
		}
		args = append(args, "-i", s.IdentityFile, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no")
	case "password":
		args = append(args, "-o", "PubkeyAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-o", "PreferredAuthentications=password")
	}
	args = append(args, "--", s.Host)
	executable, err := os.Executable()
	if err != nil {
		return "", nil, nil, failure("initialization", "Cannot locate the SSH authentication helper.")
	}
	secret := s.Password
	if s.AuthMethod == "privateKey" {
		secret = s.Passphrase
	}
	bridge, err := newAskpass(filepath.Join(dir, "askpass"), secret)
	if err != nil {
		return "", nil, nil, err
	}
	lifeRead, lifeWrite, err := os.Pipe()
	if err != nil {
		bridge.Close()
		return "", nil, nil, failure("initialization", "Cannot supervise SSH transport.")
	}
	cmd := exec.Command(executable, append([]string{"--ssh-watchdog", dir}, args...)...)
	cmd.ExtraFiles = []*os.File{lifeRead}
	cmd.Env = sshEnvironment(executable, bridge.path, bridge.token)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err = cmd.Start(); err != nil {
		lifeRead.Close()
		lifeWrite.Close()
		bridge.Close()
		return "", nil, nil, failure("initialization", "Cannot launch SSH transport.")
	}
	lifeRead.Close()
	cleanup = false
	var once sync.Once
	stop := func() { once.Do(func() { lifeWrite.Close(); bridge.Close() }) }
	exited := make(chan struct{})
	go func() { cmd.Wait(); stop(); os.RemoveAll(dir); close(exited) }()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			stop()
			return "", stop, exited, failure("timeout", "SSH connection was cancelled or timed out.")
		case <-exited:
			if conn, e := net.DialTimeout("tcp", address, 100*time.Millisecond); e == nil {
				conn.Close()
				return "", nil, exited, failure("port_collision", "The SSH forwarding port was claimed by another process.")
			}
			return "", nil, exited, failure("authentication", "SSH authentication or forwarding failed. Check credentials and server permissions.")
		case <-ticker.C:
			checkCtx, cancel := context.WithTimeout(ctx, time.Second)
			check := exec.CommandContext(checkCtx, "/usr/bin/ssh", "-F", "/dev/null", "-S", control, "-O", "check", "--", s.Host)
			check.Stdout = io.Discard
			check.Stderr = io.Discard
			ok := check.Run() == nil
			cancel()
			if ok {
				return address, stop, exited, nil
			}
		}
	}
}

func hostKeyAlgorithms(algorithm string) string {
	if algorithm == "ssh-rsa" {
		return "rsa-sha2-512,rsa-sha2-256"
	}
	return algorithm
}
