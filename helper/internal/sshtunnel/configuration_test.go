package sshtunnel

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func configurationSettings(path string) *protocol.SSHSettings {
	return &protocol.SSHSettings{ProfileID: "configuration-profile", Host: "database-route", AuthMethod: "openSSH", ConfigFile: path}
}

func TestSSHConfigurationDefaultsPrecedeIncludesAndBlockUnownedActions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ssh configuration")
	os.WriteFile(path, []byte("Host fixture\n HostName example.invalid\n"), 0600)
	s := configurationSettings(path)
	text, err := configurationText("/synthetic/helper path", s)
	if err != nil {
		t.Fatal(err)
	}
	for _, option := range []string{"StrictHostKeyChecking yes", "ClearAllForwardings yes", "ForwardAgent no", "ForwardX11 no", "PermitLocalCommand no", "BatchMode yes", "ControlPath none", "ForkAfterAuthentication no", "--ssh-known-host"} {
		if !strings.Contains(text, option) || strings.Index(text, option) > strings.Index(text, "Include ") {
			t.Fatalf("missing enforced option %s", option)
		}
	}
	if !strings.Contains(text, strconv.Quote(path)) {
		t.Fatal("configuration path not preserved")
	}
	s.ConfigFile = filepath.Join(t.TempDir(), "missing")
	if _, err := configurationText("/synthetic/helper", s); err == nil {
		t.Fatal("missing explicit config silently used defaults")
	}
}

func TestSSHConfigurationBridgeBindsActualHopTrustToOriginalProfile(t *testing.T) {
	m := testManager(t)
	s := configurationSettings("")
	b := &configurationBridge{manager: m, settings: *s, result: make(chan *protocol.SSHProbe, 1), visited: map[string]bool{}}
	key := testKey('c')
	r := knownHostRequest{Reason: "HOSTNAME", Host: "jump.example", Port: "2222", Original: "jump-alias", Lookup: "[jump.example]:2222", Algorithm: key.algorithm, Key: key.blob, Role: "hop"}
	if _, err := b.check(r); err == nil {
		t.Fatal("unknown hop authenticated")
	}
	probe := <-b.result
	if probe.Host != r.Host || probe.Port != 2222 || probe.Status != "unknown" {
		t.Fatal("probe did not describe actual hop")
	}
	other := *s
	other.Host = "different-route"
	if m.Trust(context.Background(), &other, probe.ChallengeToken) == nil {
		t.Fatal("cross-route trust accepted")
	}
	b.check(r)
	probe = <-b.result
	if err := m.Trust(context.Background(), s, probe.ChallengeToken); err != nil {
		t.Fatal(err)
	}
	line, err := b.check(r)
	if err != nil || !strings.Contains(line, key.blob) || !strings.HasPrefix(line, r.Lookup+" ") {
		t.Fatal("reviewed hop not pinned")
	}
	r.Key = testKey('d').blob
	b.check(r)
	changed := <-b.result
	if changed.Status != "changed" {
		t.Fatal("changed hop accepted")
	}
	if m.Trust(context.Background(), s, changed.ChallengeToken) == nil {
		t.Fatal("changed key replaced without explicit approval")
	}
	b.check(r)
	changed = <-b.result
	if err := m.Trust(context.Background(), s, changed.ChallengeToken, true); err != nil {
		t.Fatal(err)
	}
	line, err = b.check(r)
	if err != nil || !strings.Contains(line, r.Key) {
		t.Fatal("explicit replacement not pinned")
	}
	imported := *s
	imported.ProfileID = "imported-profile"
	otherBridge := &configurationBridge{manager: m, settings: imported, result: make(chan *protocol.SSHProbe, 1), visited: map[string]bool{}}
	otherBridge.check(r)
	if result := <-otherBridge.result; result.Status != "unknown" {
		t.Fatal("profile import inherited local trust")
	}
}

func TestSSHConfigurationFinalProbeStopsBeforeAuthenticationAndRejectsInvalidLookups(t *testing.T) {
	m := testManager(t)
	s := configurationSettings("")
	b := &configurationBridge{manager: m, settings: *s, probeOnly: true, result: make(chan *protocol.SSHProbe, 1), visited: map[string]bool{}}
	key := testKey('a')
	r := knownHostRequest{Reason: "HOSTNAME", Host: "final.example", Port: "22", Original: s.Host, Lookup: "final.example", Algorithm: key.algorithm, Key: key.blob, Role: "final"}
	b.check(r)
	probe := <-b.result
	if err := m.Trust(context.Background(), s, probe.ChallengeToken); err != nil {
		t.Fatal(err)
	}
	// An alias reused by a jump must not be mistaken for the final connection.
	r.Role = "hop"
	if _, err := b.check(r); err != nil {
		t.Fatal("trusted jump with reused alias stopped the probe")
	}
	select {
	case <-b.result:
		t.Fatal("jump reported the final probe result")
	default:
	}
	r.Role = "final"
	if _, err := b.check(r); err == nil {
		t.Fatal("probe authenticated final server")
	}
	if probe := <-b.result; probe.Status != "trusted" {
		t.Fatal("trusted final probe failed")
	}
	for _, change := range []func(*knownHostRequest){func(r *knownHostRequest) { r.Host = "host;command" }, func(r *knownHostRequest) { r.Port = "0" }, func(r *knownHostRequest) { r.Lookup = "host\nforged" }, func(r *knownHostRequest) { r.Key = "malformed" }, func(r *knownHostRequest) { r.Reason = "OTHER" }} {
		bad := r
		change(&bad)
		if _, err := b.check(bad); err == nil {
			t.Fatal("invalid lookup accepted")
		}
	}
}

func TestSSHConfigurationBrokerRequiresItsPrivateToken(t *testing.T) {
	m := testManager(t)
	b, err := newConfigurationBridge(m, configurationSettings(""), filepath.Join(m.temp, "key-check"), true)
	if err != nil {
		t.Fatal(err)
	}
	defer b.close()
	conn, err := net.Dial("unix", b.path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	json.NewEncoder(conn).Encode(knownHostRequest{Token: "wrong", Reason: "ORDER", Host: "fixture", Port: "22"})
	conn.SetReadDeadline(time.Now().Add(time.Second))
	var response knownHostReply
	if json.NewDecoder(conn).Decode(&response) == nil {
		t.Fatal("unauthorized lookup received a response")
	}
	if len(m.challenges) != 0 {
		t.Fatal("unauthorized lookup created trust")
	}
}

type configurationSSHD struct {
	port    int
	keyPath string
}

func startConfigurationSSHD(t *testing.T, root, clientKey string, index int) configurationSSHD {
	t.Helper()
	key := filepath.Join(root, fmt.Sprintf("host-%d", index))
	cmd := exec.Command("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key)
	if err := cmd.Run(); err != nil {
		t.Fatal("cannot generate fixture host key")
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	current, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	config := filepath.Join(root, fmt.Sprintf("sshd-%d", index))
	text := fmt.Sprintf("Port %d\nListenAddress 127.0.0.1\nHostKey %s\nPidFile %s\nAuthorizedKeysFile %s\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nAllowUsers %s\nAllowTcpForwarding local\nPermitTTY no\nForceCommand /usr/bin/false\nLogLevel ERROR\n", port, key, config+".pid", clientKey+".pub", current.Username)
	if os.WriteFile(config, []byte(text), 0600) != nil {
		t.Fatal("cannot write fixture config")
	}
	server := exec.Command("/usr/sbin/sshd", "-D", "-e", "-f", config)
	server.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := server.Start(); err != nil {
		t.Fatal("cannot start fixture sshd")
	}
	t.Cleanup(func() { syscall.Kill(-server.Process.Pid, syscall.SIGKILL); server.Wait() })
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 50*time.Millisecond)
		if err == nil {
			conn.Close()
			return configurationSSHD{port, key}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("fixture sshd did not become ready")
	return configurationSSHD{}
}

func requireConfigurationIntegration(t *testing.T) {
	t.Helper()
	if os.Getenv("DBEER_TEST_SSH_CONFIG") != "1" {
		t.Skip("requires scripts/test-ssh-config.sh")
	}
}

func TestSSHConfigurationLiveAliasesIncludesMultiHopAndProxyCommand(t *testing.T) {
	requireConfigurationIntegration(t)
	root := t.TempDir()
	identity := filepath.Join(root, "client")
	if exec.Command("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", identity).Run() != nil {
		t.Fatal("cannot generate fixture key")
	}
	current, _ := user.Current()
	hops := []configurationSSHD{startConfigurationSSHD(t, root, identity, 1), startConfigurationSSHD(t, root, identity, 2), startConfigurationSSHD(t, root, identity, 3)}
	include := filepath.Join(root, "included hosts.conf")
	config := filepath.Join(root, "ssh config")
	text := fmt.Sprintf("Host first\n HostName 127.0.0.1\n Port %d\nHost second\n HostName 127.0.0.1\n Port %d\nHost database-route\n HostName 127.0.0.1\n Port %d\n ProxyJump first,second\nHost proxy-route\n HostName 127.0.0.1\n Port %d\n ProxyCommand /usr/bin/nc %%h %%p\nHost *\n User %s\n IdentityFile %s\n IdentitiesOnly yes\n StrictHostKeyChecking no\n ForwardAgent yes\n LocalForward 127.0.0.1:1 localhost:1\n", hops[0].port, hops[1].port, hops[2].port, hops[2].port, current.Username, identity)
	os.WriteFile(include, []byte(text), 0600)
	os.WriteFile(config, []byte("Include "+strconv.Quote(include)+"\n"), 0600)
	m := testManager(t)
	s := configurationSettings(config)
	// Race-instrumented utility subprocesses include the race runtime's exit
	// delay; the full sequence includes multiple separately reviewed handshakes.
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	for index := 0; index < 3; index++ {
		probe, err := m.Probe(ctx, s)
		if err != nil {
			t.Fatal(err)
		}
		if probe.Status != "unknown" || probe.Port != hops[index].port {
			t.Fatalf("hop %d was not reviewed in order: %+v", index, probe)
		}
		if err := m.Trust(ctx, s, probe.ChallengeToken); err != nil {
			t.Fatal(err)
		}
	}
	if probe, err := m.Probe(ctx, s); err != nil || probe.Status != "trusted" {
		t.Fatalf("final probe: %v", err)
	}
	lease, err := m.Acquire(ctx, s)
	if err != nil {
		t.Fatal(err)
	}
	second, err := m.Acquire(ctx, s)
	if err != nil {
		lease.Close()
		t.Fatal(err)
	}
	if lease.entry != second.entry {
		t.Fatal("same route did not share supervised transport")
	}
	echo, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		for {
			conn, err := echo.Accept()
			if err != nil {
				return
			}
			go func() { defer conn.Close(); io.Copy(conn, conn) }()
		}
	}()
	check := func(lease *Lease) {
		t.Helper()
		conn, err := lease.DialContext(ctx, "tcp", echo.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(3 * time.Second))
		conn.Write([]byte("route-fixture"))
		data := make([]byte, 13)
		if _, err := io.ReadFull(conn, data); err != nil || string(data) != "route-fixture" {
			t.Fatal("forwarded bytes changed")
		}
	}
	check(lease)
	lease.Close()
	check(second)
	second.Close()
	s.Host = "proxy-route"
	if probe, err := m.Probe(ctx, s); err != nil || probe.Status != "trusted" {
		t.Fatalf("proxy probe: %v", err)
	}
	proxy, err := m.Acquire(ctx, s)
	if err != nil {
		t.Fatal(err)
	}
	check(proxy)
	proxy.Close()
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(m.temp); !os.IsNotExist(err) {
		t.Fatal("owned configuration artifacts remained")
	}
}

func TestSSHConfigurationCancellationReapsProxyCommand(t *testing.T) {
	requireConfigurationIntegration(t)
	for _, shutdown := range []bool{false, true} {
		t.Run(fmt.Sprintf("manager-close-%t", shutdown), func(t *testing.T) { testConfigurationCancellation(t, shutdown) })
	}
}

func testConfigurationCancellation(t *testing.T, shutdown bool) {
	root := t.TempDir()
	marker := filepath.Join(root, "proxy.pid")
	script := filepath.Join(root, "proxy")
	os.WriteFile(script, []byte("#!/bin/sh\necho $$ > "+strconv.Quote(marker)+"\ntrap '' TERM\nexec /bin/sleep 30\n"), 0700)
	config := filepath.Join(root, "config")
	os.WriteFile(config, []byte("Host database-route\n HostName example.invalid\n ProxyCommand "+strconv.Quote(script)+"\n"), 0600)
	m := testManager(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := m.Probe(ctx, configurationSettings(config)); done <- err }()
	var pid int
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if data, err := os.ReadFile(marker); err == nil {
			pid, _ = strconv.Atoi(strings.TrimSpace(string(data)))
			if pid > 0 {
				break
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	if pid <= 0 {
		t.Fatal("proxy command did not start")
	}
	if shutdown {
		m.Close()
	} else {
		cancel()
	}
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled probe succeeded")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("probe did not stop")
	}
	for time.Now().Before(deadline) {
		if syscall.Kill(pid, 0) != nil {
			if shutdown {
				if _, err := os.Stat(m.temp); !os.IsNotExist(err) {
					t.Fatal("manager shutdown left its probe directory")
				}
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("proxy command survived cancellation")
}

func TestSSHConfigurationCrashWorker(t *testing.T) {
	config := os.Getenv("DBEER_SSH_CRASH_CONFIG")
	if config == "" {
		t.Skip("only invoked by the helper-crash test")
	}
	m := testManager(t)
	if err := os.WriteFile(config+".manager", []byte(m.temp), 0600); err != nil {
		t.Fatal(err)
	}
	m.Probe(context.Background(), configurationSettings(config))
}

func TestSSHConfigurationHelperCrashReapsProxyCommand(t *testing.T) {
	requireConfigurationIntegration(t)
	root := t.TempDir()
	marker := filepath.Join(root, "proxy.pid")
	script := filepath.Join(root, "proxy")
	os.WriteFile(script, []byte("#!/bin/sh\necho $$ > "+strconv.Quote(marker)+"\ntrap '' TERM\nexec /bin/sleep 30\n"), 0700)
	config := filepath.Join(root, "config")
	os.WriteFile(config, []byte("Host database-route\n HostName example.invalid\n ProxyCommand "+strconv.Quote(script)+"\n"), 0600)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	worker := exec.Command(executable, "-test.run=^TestSSHConfigurationCrashWorker$")
	worker.Env = append(os.Environ(), "DBEER_SSH_CRASH_CONFIG="+config)
	if err := worker.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		worker.Process.Kill()
		worker.Wait()
		if data, err := os.ReadFile(config + ".manager"); err == nil {
			os.Remove(string(data))
		}
	})
	var pid int
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if data, err := os.ReadFile(marker); err == nil {
			pid, _ = strconv.Atoi(strings.TrimSpace(string(data)))
			if pid > 0 {
				break
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	if pid <= 0 {
		t.Fatal("crash fixture proxy did not start")
	}
	if err := worker.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	worker.Wait()
	deadline = time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if syscall.Kill(pid, 0) != nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("proxy command survived helper SIGKILL")
}
