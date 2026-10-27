package sshtunnel

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"dbeer/helper/internal/protocol"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	if handled, e := RunUtility(os.Args[1:]); handled {
		if e != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}
func testManager(t *testing.T) *Manager {
	t.Helper()
	m, e := NewManagerWithOptions(Options{KnownHostsPath: filepath.Join(t.TempDir(), "known_hosts")})
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { m.Close() })
	return m
}
func testSettings() *protocol.SSHSettings {
	return &protocol.SSHSettings{ProfileID: "profile-one", Host: "db.example.test", Port: 2222, User: "dbeer", AuthMethod: "agent"}
}
func testKey(value byte) hostKey {
	return hostKey{"ssh-ed25519", base64.StdEncoding.EncodeToString([]byte(strings.Repeat(string(value), 32)))}
}
func TestHostPatternsAndHashedRecords(t *testing.T) {
	salt := []byte("salt")
	host := "[db.example.test]:2222"
	h := hmac.New(sha1.New, salt)
	h.Write([]byte(host))
	hashed := "|1|" + base64.StdEncoding.EncodeToString(salt) + "|" + base64.StdEncoding.EncodeToString(h.Sum(nil))
	for _, p := range []string{host, "*.test]:2222", hashed, "wrong," + host} {
		if !hostMatches(p, host) {
			t.Errorf("did not match %q", p)
		}
	}
	for _, p := range []string{"wrong", "*test]:2222,!" + host, hashed + "invalid"} {
		if hostMatches(p, host) {
			t.Errorf("unexpected match %q", p)
		}
	}
}
func TestTrustChallenges(t *testing.T) {
	m := testManager(t)
	s := testSettings()
	k := testKey('a')
	token := randomToken()
	m.challenges[token] = challenge{generation(s), k, time.Now().Add(time.Minute), false, ""}
	other := *s
	other.ProfileID = "other"
	if m.Trust(context.Background(), &other, token) == nil {
		t.Fatal("cross-profile accepted")
	}
	if m.Trust(context.Background(), s, token) == nil {
		t.Fatal("consumed token accepted")
	}
	expired := randomToken()
	m.challenges[expired] = challenge{generation: generation(s), key: k, expires: time.Now().Add(-time.Second)}
	if m.Trust(context.Background(), s, expired) == nil {
		t.Fatal("expired trust challenge accepted")
	}
	if _, err := os.Stat(m.knownHosts); !os.IsNotExist(err) {
		t.Fatal("rejected trust challenge changed persistent trust")
	}
	token = randomToken()
	m.challenges[token] = challenge{generation(s), k, time.Now().Add(time.Minute), false, ""}
	if e := m.Trust(context.Background(), s, token); e != nil {
		t.Fatal(e)
	}
	info, e := os.Stat(m.knownHosts)
	if e != nil || info.Mode().Perm() != 0600 {
		t.Fatal("trust file permissions")
	}
	status, actual, e := m.checkKeys(s, []hostKey{k})
	if e != nil || status != "trusted" || actual != k {
		t.Fatalf("trusted: %s %v", status, e)
	}
	if m.Trust(context.Background(), s, token) == nil {
		t.Fatal("duplicate accepted")
	}
}
func TestChangedRevokedAndSystemConflict(t *testing.T) {
	m := testManager(t)
	s := testSettings()
	old, next := testKey('a'), testKey('b')
	os.WriteFile(m.knownHosts, []byte(managedEndpoint(s)+" "+old.algorithm+" "+old.blob+"\n"), 0600)
	status, _, e := m.checkKeys(s, []hostKey{next})
	if e != nil || status != "changed" {
		t.Fatalf("changed: %s %v", status, e)
	}
	token := randomToken()
	m.challenges[token] = challenge{generation(s), next, time.Now().Add(time.Minute), true, recordsDigest([]record{{"", old}})}
	if m.Trust(context.Background(), s, token) == nil {
		t.Fatal("implicit replacement")
	}
	token = randomToken()
	m.challenges[token] = challenge{generation(s), next, time.Now().Add(time.Minute), true, recordsDigest([]record{{"", old}})}
	if e = m.Trust(context.Background(), s, token, true); e != nil {
		t.Fatal(e)
	}
	system := filepath.Join(t.TempDir(), "system_hosts")
	m.systemKnownHosts = []string{system}
	os.WriteFile(system, []byte(endpoint(s)+" "+old.algorithm+" "+old.blob+"\n"), 0600)
	if _, _, e = m.checkKeys(s, []hostKey{next}); e == nil {
		t.Fatal("own trust bypassed conflicting system record")
	}
	os.WriteFile(system, []byte("@revoked "+endpoint(s)+" "+old.algorithm+" "+old.blob+"\n"), 0600)
	if _, _, e = m.checkKeys(s, []hostKey{next}); e == nil {
		t.Fatal("revoked endpoint accepted")
	}
}
func TestAskpassAuthorizationOneUse(t *testing.T) {
	path := filepath.Join("/tmp", "dbeer-ap-"+randomToken()[:12])
	b, e := newAskpass(path, "fixture-secret")
	if e != nil {
		t.Fatal(e)
	}
	defer b.Close()
	request := func(token string) string {
		conn, e := net.Dial("unix", path)
		if e != nil {
			t.Fatal(e)
		}
		defer conn.Close()
		json.NewEncoder(conn).Encode(map[string]string{"token": token})
		var r struct{ Secret string }
		json.NewDecoder(conn).Decode(&r)
		return r.Secret
	}
	if request("wrong") != "" {
		t.Fatal("unauthorized secret")
	}
	if request(b.token) != "fixture-secret" {
		t.Fatal("missing secret")
	}
	if request(b.token) != "" {
		t.Fatal("duplicate secret")
	}
}
func TestSOCKSRemoteDNSAndDeadlines(t *testing.T) {
	listener, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer listener.Close()
	seen := make(chan string, 1)
	go func() {
		conn, e := listener.Accept()
		if e != nil {
			return
		}
		defer conn.Close()
		var greeting [3]byte
		io.ReadFull(conn, greeting[:])
		conn.Write([]byte{5, 0})
		var header [5]byte
		io.ReadFull(conn, header[:])
		target := make([]byte, int(header[4])+2)
		io.ReadFull(conn, target)
		seen <- string(target[:len(target)-2])
		conn.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 1})
		io.Copy(io.Discard, conn)
	}()
	m := testManager(t)
	lease := &Lease{manager: m, entry: &entry{address: listener.Addr().String(), done: make(chan struct{})}}
	conn, e := lease.DialContext(context.Background(), "tcp", "bastion-only.example:5432")
	if e != nil {
		t.Fatal(e)
	}
	defer conn.Close()
	if target := <-seen; target != "bastion-only.example" {
		t.Fatalf("target %q", target)
	}
	conn.SetReadDeadline(time.Now().Add(30 * time.Millisecond))
	var b [1]byte
	if _, e = conn.Read(b[:]); e == nil {
		t.Fatal("deadline ignored")
	}
}
func TestSOCKSCancellation(t *testing.T) {
	listener, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer listener.Close()
	go func() {
		conn, e := listener.Accept()
		if e == nil {
			defer conn.Close()
			io.Copy(io.Discard, conn)
		}
	}()
	m := testManager(t)
	lease := &Lease{manager: m, entry: &entry{address: listener.Addr().String(), done: make(chan struct{})}}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	start := time.Now()
	if c, e := lease.DialContext(ctx, "tcp", "remote:5432"); e == nil {
		c.Close()
		t.Fatal("stalled SOCKS accepted")
	}
	if time.Since(start) > time.Second {
		t.Fatal("cancellation blocked")
	}
}
func TestLeaseIsolation(t *testing.T) {
	m := testManager(t)
	e := &entry{key: "generation", refs: 2, done: make(chan struct{}), cancel: func() {}}
	m.entries[e.key] = e
	a, b := &Lease{manager: m, entry: e}, &Lease{manager: m, entry: e}
	a.Close()
	select {
	case <-b.Done():
		t.Fatal("other owner closed")
	default:
	}
	b.Close()
	select {
	case <-b.Done():
	default:
		t.Fatal("last release did not close")
	}
}
func TestLocalSSHDIntegration(t *testing.T) {
	port, err := strconv.Atoi(os.Getenv("DBEER_SSH_TEST_PORT"))
	if err != nil {
		t.Skip("DBEER_SSH_TEST_PORT unset")
	}
	identity := os.Getenv("DBEER_SSH_TEST_IDENTITY")
	if identity == "" {
		t.Fatal("DBEER_SSH_TEST_IDENTITY required")
	}
	user := os.Getenv("DBEER_SSH_TEST_USER")
	if user == "" {
		user = os.Getenv("USER")
	}
	m := testManager(t)
	s := &protocol.SSHSettings{ProfileID: "local-fixture", Host: "127.0.0.1", Port: port, User: user, AuthMethod: "privateKey", IdentityFile: identity, Passphrase: os.Getenv("DBEER_SSH_TEST_PASSPHRASE")}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	probe, e := m.Probe(ctx, s)
	if e != nil {
		t.Fatal(e)
	}
	if probe.Status != "unknown" {
		t.Fatalf("expected unknown: %v", probe)
	}
	if l, e := m.Acquire(ctx, s); e == nil {
		l.Close()
		t.Fatal("untrusted connected")
	}
	if e = m.Trust(ctx, s, probe.ChallengeToken); e != nil {
		t.Fatal(e)
	}
	echo, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer echo.Close()
	go func() {
		for {
			c, e := echo.Accept()
			if e != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	var leases [8]*Lease
	var errs [8]error
	var wg sync.WaitGroup
	for i := range leases {
		wg.Add(1)
		go func() { defer wg.Done(); leases[i], errs[i] = m.Acquire(ctx, s) }()
	}
	wg.Wait()
	for _, e := range errs {
		if e != nil {
			t.Fatal(e)
		}
	}
	for _, l := range leases {
		if l.entry != leases[0].entry {
			t.Fatal("startup not deduplicated")
		}
	}
	leases[0].Close()
	conn, e := leases[1].DialContext(ctx, "tcp", echo.Addr().String())
	if e != nil {
		t.Fatal(e)
	}
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	const data = "SSH tunneled echo"
	fmt.Fprint(conn, data)
	got := make([]byte, len(data))
	if _, e = io.ReadFull(conn, got); e != nil || string(got) != data {
		t.Fatalf("echo: %v", e)
	}
	conn.Close()
	for _, l := range leases {
		l.Close()
	}
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		c, e := net.DialTimeout("tcp", leases[0].entry.address, 50*time.Millisecond)
		if e != nil {
			return
		}
		c.Close()
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("listener remained after last release")
}

func TestProfileScopedManagedTrust(t *testing.T) {
	m := testManager(t)
	s := testSettings()
	key := testKey('c')
	token := randomToken()
	m.challenges[token] = challenge{generation(s), key, time.Now().Add(time.Minute), false, ""}
	if err := m.Trust(context.Background(), s, token); err != nil {
		t.Fatal(err)
	}
	imported := *s
	imported.ProfileID = "imported-new-uuid"
	status, _, err := m.checkKeys(&imported, []hostKey{key})
	if err != nil || status != "unknown" {
		t.Fatalf("import inherited trust: %s %v", status, err)
	}
}
func TestRSAUsesSHA2Signatures(t *testing.T) {
	if got := hostKeyAlgorithms("ssh-rsa"); got != "rsa-sha2-512,rsa-sha2-256" {
		t.Fatalf("unsafe RSA algorithms: %s", got)
	}
}
func TestStartupWaiterCancellationIsIndependent(t *testing.T) {
	m := testManager(t)
	s := testSettings()
	var cancelled bool
	entry := &entry{key: generation(s), refs: 1, ready: make(chan struct{}), done: make(chan struct{}), cancel: func() { cancelled = true }}
	m.entries[entry.key] = entry
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := m.Acquire(ctx, s); err == nil {
		t.Fatal("cancelled waiter succeeded")
	}
	if cancelled {
		t.Fatal("existing owner cancelled")
	}
	// A waiter that cancels after joining startup must release only its reference.
	ctx, cancel = context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() { _, err := m.Acquire(ctx, s); result <- err }()
	deadline := time.Now().Add(time.Second)
	for {
		m.mu.Lock()
		joined := entry.refs == 2
		m.mu.Unlock()
		if joined {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("waiter never joined")
		}
		time.Sleep(time.Millisecond)
	}
	cancel()
	if err := <-result; err == nil {
		t.Fatal("cancelled waiter succeeded")
	}
	if cancelled {
		t.Fatal("joined waiter cancelled existing owner")
	}
	close(entry.ready)
	owner := &Lease{manager: m, entry: entry}
	owner.Close()
	if !cancelled {
		t.Fatal("last owner did not cancel startup")
	}
}
func TestSSHWatchdogCrashChild(t *testing.T) {
	if os.Getenv("DBEER_SSH_CRASH_CHILD") != "1" {
		t.Skip("watchdog child subprocess")
	}
	port, _ := strconv.Atoi(os.Getenv("DBEER_SSH_TEST_PORT"))
	m, err := NewManagerWithOptions(Options{KnownHostsPath: os.Getenv("DBEER_SSH_CRASH_TRUST")})
	if err != nil {
		t.Fatal(err)
	}
	s := &protocol.SSHSettings{ProfileID: "watchdog-fixture", Host: "127.0.0.1", Port: port, User: os.Getenv("USER"), AuthMethod: "privateKey", IdentityFile: os.Getenv("DBEER_SSH_TEST_IDENTITY"), Passphrase: os.Getenv("DBEER_SSH_TEST_PASSPHRASE")}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	probe, err := m.Probe(ctx, s)
	if err != nil {
		t.Fatal(err)
	}
	if probe.Status != "trusted" {
		if err = m.Trust(ctx, s, probe.ChallengeToken); err != nil {
			t.Fatal(err)
		}
	}
	lease, err := m.Acquire(ctx, s)
	if err != nil {
		t.Fatal(err)
	}
	json.NewEncoder(os.Stdout).Encode(map[string]string{"address": lease.entry.address, "temp": m.temp})
	select {}
}
func TestSSHWatchdogSurvivesParentCrash(t *testing.T) {
	if os.Getenv("DBEER_SSH_TEST_PORT") == "" {
		t.Skip("DBEER_SSH_TEST_PORT unset")
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, executable, "-test.run=^TestSSHWatchdogCrashChild$")
	cmd.Env = append(os.Environ(), "DBEER_SSH_CRASH_CHILD=1", "DBEER_SSH_CRASH_TRUST="+filepath.Join(t.TempDir(), "known_hosts"))
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { cmd.Process.Kill(); cmd.Wait() }()
	scanner := bufio.NewScanner(stdout)
	var result struct{ Address, Temp string }
	var output []string
	for scanner.Scan() {
		if json.Unmarshal(scanner.Bytes(), &result) == nil && result.Address != "" {
			break
		}
		output = append(output, scanner.Text())
	}
	if result.Address == "" {
		t.Fatalf("watchdog child failed: %s", strings.Join(output, "\n"))
	}
	defer os.RemoveAll(result.Temp)
	if err = cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	cmd.Wait()
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", result.Address, 50*time.Millisecond)
		if err != nil {
			return
		}
		conn.Close()
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("watchdog left SSH listener after parent SIGKILL")
}

func TestStaleUnknownChallengeCannotReplaceNewTrust(t *testing.T) {
	m := testManager(t)
	s := testSettings()
	a, b := testKey('a'), testKey('b')
	one, two := randomToken(), randomToken()
	m.challenges[one] = challenge{generation(s), a, time.Now().Add(time.Minute), false, ""}
	m.challenges[two] = challenge{generation(s), b, time.Now().Add(time.Minute), false, ""}
	if err := m.Trust(context.Background(), s, one); err != nil {
		t.Fatal(err)
	}
	if err := m.Trust(context.Background(), s, two); err == nil {
		t.Fatal("stale unknown challenge replaced trusted key")
	}
	status, key, err := m.checkKeys(s, []hostKey{a})
	if err != nil || status != "trusted" || key != a {
		t.Fatal("original trust changed")
	}
}

func TestTrustChangesAcrossHelpersAreSerialized(t *testing.T) {
	first := testManager(t)
	second, err := NewManagerWithOptions(Options{KnownHostsPath: first.knownHosts})
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	s := testSettings()
	a, b := testKey('a'), testKey('b')
	one, two := randomToken(), randomToken()
	first.challenges[one] = challenge{generation(s), a, time.Now().Add(time.Minute), false, ""}
	second.challenges[two] = challenge{generation(s), b, time.Now().Add(time.Minute), false, ""}
	if err = first.Trust(context.Background(), s, one); err != nil {
		t.Fatal(err)
	}
	if err = second.Trust(context.Background(), s, two, true); err == nil {
		t.Fatal("another helper's stale challenge overwrote trust")
	}
	other := *s
	other.ProfileID = "other-profile"
	token := randomToken()
	second.challenges[token] = challenge{generation(&other), b, time.Now().Add(time.Minute), false, ""}
	if err = second.Trust(context.Background(), &other, token); err != nil {
		t.Fatal(err)
	}
	status, key, err := first.checkKeys(s, []hostKey{a})
	if err != nil || status != "trusted" || key != a {
		t.Fatal("another profile's trust was lost")
	}
}
func TestTrustFileLockWaitIsBounded(t *testing.T) {
	m := testManager(t)
	s := testSettings()
	token := randomToken()
	m.challenges[token] = challenge{generation(s), testKey('a'), time.Now().Add(time.Minute), false, ""}
	file, err := os.OpenFile(m.knownHosts+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	defer syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	start := time.Now()
	if err = m.Trust(ctx, s, token); err == nil {
		t.Fatal("locked trust file accepted write")
	}
	if time.Since(start) > time.Second {
		t.Fatal("trust lock ignored cancellation")
	}
}

func TestHashedRevokedRecordUsesCanonicalHostCase(t *testing.T) {
	m := testManager(t)
	s := testSettings()
	s.Host = "DB.EXAMPLE.TEST"
	salt := []byte("revocation-salt")
	h := hmac.New(sha1.New, salt)
	h.Write([]byte("[db.example.test]:2222"))
	hashed := "|1|" + base64.StdEncoding.EncodeToString(salt) + "|" + base64.StdEncoding.EncodeToString(h.Sum(nil))
	key := testKey('a')
	system := filepath.Join(t.TempDir(), "system_hosts")
	m.systemKnownHosts = []string{system}
	os.WriteFile(system, []byte("@revoked "+hashed+" "+key.algorithm+" "+key.blob+"\n"), 0600)
	if _, _, err := m.checkKeys(s, []hostKey{key}); err == nil {
		t.Fatal("uppercase hostname bypassed hashed revocation")
	}
}
