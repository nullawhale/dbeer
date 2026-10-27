package sshtunnel

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"dbeer/helper/internal/protocol"
)

// OpenSSH itself interprets Host/Include/Match/ProxyJump/ProxyCommand. The first
// global values below keep every native jump under the same trust and lifetime
// policy. Configured proxy programs retain their own internal authentication.
func configurationText(executable string, s *protocol.SSHSettings) (string, error) {
	files := []string{s.ConfigFile}
	if s.ConfigFile == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", failure("configuration", "Cannot locate the OpenSSH configuration.")
		}
		files = []string{filepath.Join(home, ".ssh", "config"), "/etc/ssh/ssh_config"}
	} else if info, err := os.Stat(s.ConfigFile); err != nil || !info.Mode().IsRegular() {
		return "", failure("configuration", "The selected OpenSSH configuration is unavailable.")
	}
	text := `Host *
  BatchMode yes
  StrictHostKeyChecking yes
  UserKnownHostsFile /dev/null
  GlobalKnownHostsFile /dev/null
  VerifyHostKeyDNS no
  UpdateHostKeys no
  CheckHostIP no
  ControlMaster no
  ControlPath none
  ControlPersist no
  ForkAfterAuthentication no
  ForwardAgent no
  ForwardX11 no
  PermitLocalCommand no
  LocalCommand none
  RemoteCommand none
  RequestTTY no
  Tunnel no
  ClearAllForwardings yes
  ConnectTimeout 10
  ConnectionAttempts 1
  ServerAliveInterval 15
  ServerAliveCountMax 2
  NumberOfPasswordPrompts 0
`
	text += "  KnownHostsCommand " + configurationKnownHostsCommand(executable, "hop") + "\n"
	for _, file := range files {
		text += "Host *\nInclude " + strconv.Quote(strings.ReplaceAll(file, "%", "%%")) + "\n"
	}
	return text, nil
}

func configurationKnownHostsCommand(executable, role string) string {
	return strconv.Quote(strings.ReplaceAll(executable, "%", "%%")) + ` --ssh-known-host "%I" "%h" "%p" "%n" "%H" "%t" "%K" ` + role
}

type knownHostRequest struct {
	Token, Reason, Host, Port, Original, Lookup, Algorithm, Key, Role string
}
type knownHostReply struct {
	Allowed bool
	Lines   string
}
type configurationBridge struct {
	manager     *Manager
	settings    protocol.SSHSettings
	probeOnly   bool
	path, token string
	listener    net.Listener
	result      chan *protocol.SSHProbe
	mu          sync.Mutex
	visited     map[string]bool
}

func newConfigurationBridge(m *Manager, s *protocol.SSHSettings, path string, probeOnly bool) (*configurationBridge, error) {
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, failure("initialization", "Cannot initialize SSH host-key review.")
	}
	if err := os.Chmod(path, 0600); err != nil {
		listener.Close()
		return nil, failure("initialization", "Cannot protect SSH host-key review.")
	}
	b := &configurationBridge{manager: m, settings: *s, probeOnly: probeOnly, path: path, token: randomToken(), listener: listener,
		result: make(chan *protocol.SSHProbe, 1), visited: map[string]bool{}}
	go b.serve()
	return b, nil
}
func (b *configurationBridge) close() { b.listener.Close(); os.Remove(b.path) }
func (b *configurationBridge) serve() {
	for {
		conn, err := b.listener.Accept()
		if err != nil {
			return
		}
		go func() {
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(5 * time.Second))
			var request knownHostRequest
			if json.NewDecoder(io.LimitReader(conn, 65536)).Decode(&request) != nil ||
				subtle.ConstantTimeCompare([]byte(request.Token), []byte(b.token)) != 1 {
				return
			}
			lines, err := b.check(request)
			json.NewEncoder(conn).Encode(knownHostReply{Allowed: err == nil, Lines: lines})
		}()
	}
}

func (b *configurationBridge) check(r knownHostRequest) (string, error) {
	port, err := strconv.Atoi(r.Port)
	target := protocol.SSHSettings{ProfileID: b.settings.ProfileID, Host: r.Host, Port: port, User: "configuration", AuthMethod: "agent"}
	if err != nil || !target.Valid() || len(r.Lookup) > 1024 || strings.ContainsAny(r.Lookup, "\r\n\x00") ||
		(r.Reason != "ORDER" && r.Reason != "HOSTNAME") || (r.Role != "hop" && r.Role != "final") ||
		(r.Role == "final" && r.Original != b.settings.Host) {
		return "", errors.New("Invalid SSH key lookup")
	}
	b.mu.Lock()
	b.visited[endpoint(&target)] = true
	tooMany := len(b.visited) > 16
	b.mu.Unlock()
	if tooMany {
		return "", errors.New("SSH route exceeds the hop limit")
	}
	m := b.manager
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return "", errors.New("SSH transport closed")
	}
	own, err := readRecords(m.knownHosts, managedEndpoint(&target))
	if err != nil {
		return "", err
	}
	if r.Reason == "ORDER" {
		records := append([]record{}, own...)
		for _, path := range m.systemKnownHosts {
			rs, e := readRecords(path, endpoint(&target))
			if e != nil {
				return "", e
			}
			records = append(records, rs...)
		}
		var lines strings.Builder
		for _, record := range records {
			if record.marker == "" {
				fmt.Fprintf(&lines, "%s %s %s\n", r.Lookup, record.key.algorithm, record.key.blob)
			}
		}
		return lines.String(), nil
	}
	keys := parseKeys([]byte("host " + r.Algorithm + " " + r.Key))
	if len(keys) != 1 {
		return "", errors.New("Unsupported SSH host key")
	}
	status, key, err := m.checkKnownKeys(&target, keys, own)
	if err != nil {
		return "", err
	}
	probe := &protocol.SSHProbe{Status: status, Host: target.Host, Port: target.Port, Algorithm: key.algorithm, Fingerprint: key.fingerprint()}
	if status != "trusted" {
		now := time.Now()
		for token, challenge := range m.challenges {
			if now.After(challenge.expires) {
				delete(m.challenges, token)
				delete(m.challengeTargets, token)
			}
		}
		if len(m.challenges) >= 128 {
			return "", errors.New("Too many pending SSH trust reviews")
		}
		token := randomToken()
		m.challenges[token] = challenge{generation(&b.settings), key, now.Add(2 * time.Minute), status == "changed", recordsDigest(own)}
		m.challengeTargets[token] = &target
		probe.ChallengeToken = token
	}
	if status != "trusted" || (b.probeOnly && r.Role == "final") {
		select {
		case b.result <- probe:
		default:
		}
		// Stop before authenticating an unreviewed hop, and before final-server
		// authentication during a pure key probe, even when that key is trusted.
		return "", errors.New("SSH host-key probe complete")
	}
	return fmt.Sprintf("%s %s %s\n", r.Lookup, key.algorithm, key.blob), nil
}

func runKnownHostUtility(args []string) error {
	if len(args) != 8 {
		return errors.New("Invalid SSH host-key lookup")
	}
	path, token := os.Getenv("DBEER_SSH_HOSTKEY_SOCKET"), os.Getenv("DBEER_SSH_HOSTKEY_TOKEN")
	if path == "" || token == "" {
		return errors.New("SSH host-key review unavailable")
	}
	conn, err := net.DialTimeout("unix", path, 3*time.Second)
	if err != nil {
		return errors.New("SSH host-key review unavailable")
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	request := knownHostRequest{token, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]}
	if json.NewEncoder(conn).Encode(request) != nil {
		return errors.New("SSH host-key review unavailable")
	}
	var reply knownHostReply
	if json.NewDecoder(io.LimitReader(conn, 256*1024)).Decode(&reply) != nil || !reply.Allowed {
		return errors.New("SSH host-key review required")
	}
	_, err = io.WriteString(os.Stdout, reply.Lines)
	return err
}

func (m *Manager) probeConfiguration(ctx context.Context, s *protocol.SSHSettings) (*protocol.SSHProbe, error) {
	_, stop, exited, result, err := m.runConfiguration(ctx, s, true)
	if stop != nil {
		stop()
		waitConfigurationExit(exited)
	}
	return result, err
}
func (m *Manager) launchConfiguration(ctx context.Context, s *protocol.SSHSettings) (string, func(), <-chan struct{}, error) {
	address, stop, exited, _, err := m.runConfiguration(ctx, s, false)
	return address, stop, exited, err
}
func waitConfigurationExit(exited <-chan struct{}) {
	if exited == nil {
		return
	}
	select {
	case <-exited:
	case <-time.After(3 * time.Second):
	}
}

func (m *Manager) runConfiguration(ctx context.Context, s *protocol.SSHSettings, probeOnly bool) (string, func(), <-chan struct{}, *protocol.SSHProbe, error) {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return "", nil, nil, nil, failure("closed", "SSH transport has closed.")
	}
	m.configurationOperations.Add(1)
	m.mu.Unlock()
	defer m.configurationOperations.Done()
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	executable, err := os.Executable()
	if err != nil {
		return "", nil, nil, nil, failure("initialization", "Cannot locate SSH supervision.")
	}
	config, err := configurationText(executable, s)
	if err != nil {
		return "", nil, nil, nil, err
	}
	dir, err := os.MkdirTemp(m.temp, "configuration-")
	if err != nil {
		return "", nil, nil, nil, failure("initialization", "Cannot initialize SSH configuration.")
	}
	cleanup := true
	defer func() {
		if cleanup {
			os.RemoveAll(dir)
		}
	}()
	configPath, control := filepath.Join(dir, "config"), filepath.Join(dir, "control")
	if os.WriteFile(configPath, []byte(config), 0600) != nil {
		return "", nil, nil, nil, failure("initialization", "Cannot prepare SSH configuration.")
	}
	bridge, err := newConfigurationBridge(m, s, filepath.Join(dir, "hostkeys"), probeOnly)
	if err != nil {
		return "", nil, nil, nil, err
	}
	lifeRead, lifeWrite, err := os.Pipe()
	if err != nil {
		bridge.close()
		return "", nil, nil, nil, failure("initialization", "Cannot supervise SSH configuration.")
	}
	// Unlike -F, this command-line override is not propagated by OpenSSH's
	// generated ProxyJump children. It identifies the final connection even if
	// a route reuses an alias with different user/port Match conditions.
	args := []string{"--ssh-watchdog", dir, "-F", configPath, "-N", "-T", "-M", "-S", control,
		"-o", "KnownHostsCommand=" + configurationKnownHostsCommand(executable, "final"), "--", s.Host}
	cmd := exec.Command(executable, args...)
	cmd.ExtraFiles = []*os.File{lifeRead}
	cmd.Env = append(sshEnvironment(executable, "", ""), "DBEER_SSH_HOSTKEY_SOCKET="+bridge.path, "DBEER_SSH_HOSTKEY_TOKEN="+bridge.token)
	cmd.Stdout, cmd.Stderr = io.Discard, io.Discard
	if err := cmd.Start(); err != nil {
		lifeRead.Close()
		lifeWrite.Close()
		bridge.close()
		return "", nil, nil, nil, failure("initialization", "Cannot launch SSH configuration.")
	}
	lifeRead.Close()
	cleanup = false
	var once sync.Once
	stop := func() { once.Do(func() { lifeWrite.Close(); bridge.close() }) }
	exited := make(chan struct{})
	go func() {
		cmd.Wait()
		stop()
		os.RemoveAll(dir)
		m.mu.Lock()
		closed := m.closed
		m.mu.Unlock()
		if closed {
			os.Remove(m.temp)
		}
		close(exited)
	}()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	failed := func(result *protocol.SSHProbe, err error) (string, func(), <-chan struct{}, *protocol.SSHProbe, error) {
		stop()
		waitConfigurationExit(exited)
		return "", stop, exited, result, err
	}
	for {
		select {
		case result := <-bridge.result:
			if probeOnly {
				return failed(result, nil)
			}
			return failed(nil, failure("host_key_untrusted", "An SSH route key changed or requires review. Reconnect to review the route."))
		case <-ctx.Done():
			return failed(nil, ctx.Err())
		case <-m.done:
			return failed(nil, failure("closed", "SSH transport has closed."))
		case <-exited:
			select {
			case result := <-bridge.result:
				if probeOnly {
					return failed(result, nil)
				}
			default:
			}
			return failed(nil, failure("configuration", "Cannot establish the OpenSSH route. Check the local configuration, agent or key, host keys and forwarding permissions."))
		case <-ticker.C:
			if probeOnly {
				continue
			}
			check := exec.CommandContext(ctx, "/usr/bin/ssh", "-F", "/dev/null", "-S", control, "-O", "check", "--", s.Host)
			check.Stdout, check.Stderr = io.Discard, io.Discard
			if check.Run() != nil {
				continue
			}
			listener, err := net.Listen("tcp4", "127.0.0.1:0")
			if err != nil {
				return failed(nil, failure("initialization", "Cannot allocate SSH forwarding."))
			}
			address := listener.Addr().String()
			listener.Close()
			// ClearAllForwardings suppresses user-configured listeners. Only this
			// explicit control request installs DBeer's owned loopback SOCKS port.
			forward := exec.CommandContext(ctx, "/usr/bin/ssh", "-F", "/dev/null", "-S", control, "-O", "forward", "-D", address, "--", s.Host)
			forward.Stdout, forward.Stderr = io.Discard, io.Discard
			if forward.Run() != nil {
				return failed(nil, failure("forwarding", "Cannot install the owned SSH forwarding listener."))
			}
			return address, stop, exited, nil, nil
		}
	}
}
