// Package sshtunnel owns OpenSSH processes and never falls back to direct TCP.
package sshtunnel

import (
	"bufio"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
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
	"syscall"
	"time"

	"dbeer/helper/internal/protocol"
)

type Error struct{ Code, Message string }

func (e *Error) Error() string           { return e.Message }
func failure(code, message string) error { return &Error{code, message} }
func randomToken() string {
	var b [32]byte
	if _, e := rand.Read(b[:]); e != nil {
		panic("SSH entropy unavailable")
	}
	return hex.EncodeToString(b[:])
}
func generation(s *protocol.SSHSettings) string {
	b, _ := json.Marshal(s)
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}
func endpoint(s *protocol.SSHSettings) string {
	host := strings.ToLower(s.Host)
	if ip := net.ParseIP(host); ip != nil {
		host = ip.String()
	}
	if s.Port == 22 {
		return host
	}
	return "[" + host + "]:" + strconv.Itoa(s.Port)
}

type hostKey struct{ algorithm, blob string }

func (k hostKey) fingerprint() string {
	b, _ := base64.StdEncoding.DecodeString(k.blob)
	h := sha256.Sum256(b)
	return "SHA256:" + base64.RawStdEncoding.EncodeToString(h[:])
}

type challenge struct {
	generation string
	key        hostKey
	expires    time.Time
	changed    bool
	baseline   string
}

// Probe discovers a key without authenticating. Discovery alone never trusts it.
func (m *Manager) Probe(ctx context.Context, s *protocol.SSHSettings) (*protocol.SSHProbe, error) {
	if s == nil || !s.Valid() {
		return nil, failure("invalid_settings", "Invalid SSH settings.")
	}
	if s.AuthMethod == "openSSH" {
		return m.probeConfiguration(ctx, s)
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/ssh-keyscan", "-T", "5", "-p", strconv.Itoa(s.Port), s.Host)
	var out limitedBuffer
	cmd.Stdout = &out
	cmd.Stderr = io.Discard
	if e := cmd.Run(); e != nil && out.Len() == 0 {
		return nil, failure("unreachable", "Cannot discover the SSH server key.")
	}
	keys := parseKeys(out.Bytes())
	if len(keys) == 0 {
		return nil, failure("unreachable", "Cannot discover the SSH server key.")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return nil, failure("closed", "SSH transport has closed.")
	}
	own, e := readRecords(m.knownHosts, managedEndpoint(s))
	if e != nil {
		return nil, e
	}
	status, key, e := m.checkKnownKeys(s, keys, own)
	if e != nil {
		return nil, e
	}
	r := &protocol.SSHProbe{Status: status, Host: s.Host, Port: s.Port, Algorithm: key.algorithm, Fingerprint: key.fingerprint()}
	if status != "trusted" {
		now := time.Now()
		for token, c := range m.challenges {
			if now.After(c.expires) {
				delete(m.challenges, token)
				delete(m.challengeTargets, token)
			}
		}
		if len(m.challenges) >= 128 {
			return nil, failure("busy", "Too many pending SSH trust requests.")
		}
		token := randomToken()
		m.challenges[token] = challenge{generation(s), key, now.Add(2 * time.Minute), status == "changed", recordsDigest(own)}
		r.ChallengeToken = token
	}
	return r, nil
}
func parseKeys(data []byte) []hostKey {
	var result []hostKey
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) < 3 || strings.HasPrefix(f[0], "#") {
			continue
		}
		if f[1] != "ssh-ed25519" && f[1] != "ecdsa-sha2-nistp256" && f[1] != "ecdsa-sha2-nistp384" && f[1] != "ecdsa-sha2-nistp521" && f[1] != "ssh-rsa" {
			continue
		}
		if b, e := base64.StdEncoding.DecodeString(f[2]); e == nil && len(b) > 16 && len(b) < 32768 {
			result = append(result, hostKey{f[1], f[2]})
		}
	}
	// Prefer modern compact host keys while retaining older supported servers.
	for i, k := range result {
		if k.algorithm == "ssh-ed25519" {
			result[0], result[i] = result[i], result[0]
			break
		}
	}
	return result
}

type record struct {
	marker string
	key    hostKey
}

func matchingRecords(data []byte, host string) []record {
	var result []record
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	for scanner.Scan() {
		f := strings.Fields(scanner.Text())
		if len(f) < 3 || strings.HasPrefix(f[0], "#") {
			continue
		}
		marker := ""
		if strings.HasPrefix(f[0], "@") {
			marker = f[0]
			f = f[1:]
		}
		if len(f) < 3 {
			continue
		}
		if hostMatches(f[0], host) {
			result = append(result, record{marker, hostKey{f[1], f[2]}})
		}
	}
	return result
}
func hostMatches(patterns, host string) bool {
	matched := false
	for _, p := range strings.Split(patterns, ",") {
		neg := strings.HasPrefix(p, "!")
		p = strings.TrimPrefix(p, "!")
		ok := false
		if strings.HasPrefix(p, "|1|") {
			f := strings.Split(p, "|")
			if len(f) == 4 {
				salt, e := base64.StdEncoding.DecodeString(f[2])
				sum, e2 := base64.StdEncoding.DecodeString(f[3])
				if e == nil && e2 == nil {
					h := hmac.New(sha1.New, salt)
					h.Write([]byte(host))
					ok = hmac.Equal(h.Sum(nil), sum)
				}
			}
		} else {
			ok = wildcard(strings.ToLower(p), strings.ToLower(host))
		}
		if ok && neg {
			return false
		}
		matched = matched || ok
	}
	return matched
}

// OpenSSH host patterns use '*' and '?'; brackets are literal endpoint syntax.
func wildcard(pattern, value string) bool {
	p, v, star, back := 0, 0, -1, 0
	for v < len(value) {
		if p < len(pattern) && (pattern[p] == '?' || pattern[p] == value[v]) {
			p++
			v++
		} else if p < len(pattern) && pattern[p] == '*' {
			star = p
			p++
			back = v
		} else if star >= 0 {
			back++
			v = back
			p = star + 1
		} else {
			return false
		}
	}
	for p < len(pattern) && pattern[p] == '*' {
		p++
	}
	return p == len(pattern)
}

func readRecords(path, host string) ([]record, error) {
	file, e := os.Open(path)
	if errors.Is(e, os.ErrNotExist) {
		return nil, nil
	}
	if e != nil {
		return nil, failure("trust_store", "Cannot read SSH host-key records.")
	}
	defer file.Close()
	data, e := io.ReadAll(io.LimitReader(file, 8*1024*1024+1))
	if errors.Is(e, os.ErrNotExist) {
		return nil, nil
	}
	if e != nil {
		return nil, failure("trust_store", "Cannot read SSH host-key records.")
	}
	if len(data) > 8*1024*1024 {
		return nil, failure("trust_store", "SSH host-key records exceed the size limit.")
	}
	for _, line := range bytes.Split(data, []byte("\n")) {
		if len(line) >= 1024*1024 {
			return nil, failure("trust_store", "SSH host-key record exceeds the size limit.")
		}
	}
	return matchingRecords(data, host), nil
}
func (m *Manager) checkKeys(s *protocol.SSHSettings, keys []hostKey) (string, hostKey, error) {
	own, e := readRecords(m.knownHosts, managedEndpoint(s))
	if e != nil {
		return "", hostKey{}, e
	}
	return m.checkKnownKeys(s, keys, own)
}
func (m *Manager) checkKnownKeys(s *protocol.SSHSettings, keys []hostKey, own []record) (string, hostKey, error) {
	host := endpoint(s)
	if len(keys) == 0 {
		return "", hostKey{}, failure("unreachable", "Cannot discover the SSH server key.")
	}
	records := append([]record{}, own...)
	for _, path := range m.systemKnownHosts {
		rs, e := readRecords(path, host)
		if e != nil {
			return "", hostKey{}, e
		}
		if len(rs) > 0 {
			matched := false
			for _, r := range rs {
				for _, k := range keys {
					if r.marker == "" && r.key == k {
						matched = true
					}
				}
			}
			if !matched {
				for _, r := range rs {
					if r.marker == "@revoked" {
						return "", hostKey{}, failure("host_key_revoked", "The SSH server key is revoked. Review your SSH known_hosts files.")
					}
				}
				return "", hostKey{}, failure("host_key_changed", "The SSH server key differs from your SSH known_hosts records. Review those records before connecting.")
			}
		}
		records = append(records, rs...)
	}
	for _, r := range records {
		if r.marker == "@revoked" {
			return "", hostKey{}, failure("host_key_revoked", "The SSH server key is revoked. Review your SSH known_hosts files.")
		}
		if r.marker == "@cert-authority" {
			return "", hostKey{}, failure("host_certificate", "SSH host certificate authorities are not supported by this connection mode.")
		}
	}
	if len(own) > 0 {
		records = own
	}
	for _, k := range keys {
		for _, r := range records {
			if r.marker == "" && k == r.key {
				return "trusted", k, nil
			}
		}
	}
	if len(records) > 0 && len(own) == 0 {
		return "", hostKey{}, failure("host_key_changed", "The SSH server key differs from your SSH known_hosts records. Review those records before connecting.")
	}
	if len(records) > 0 {
		return "changed", keys[0], nil
	}
	return "unknown", keys[0], nil
}
func (m *Manager) Trust(ctx context.Context, s *protocol.SSHSettings, token string, replace ...bool) error {
	if e := ctx.Err(); e != nil {
		return e
	}
	if s == nil || !s.Valid() {
		return failure("invalid_settings", "Invalid SSH settings.")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.challenges[token]
	delete(m.challenges, token)
	target := m.challengeTargets[token]
	delete(m.challengeTargets, token)
	if !ok || m.closed || time.Now().After(c.expires) || c.generation != generation(s) {
		return failure("stale_challenge", "The SSH trust request expired or does not match this connection.")
	}
	if target != nil {
		s = target
	}
	if c.changed && (len(replace) == 0 || !replace[0]) {
		return failure("replacement_required", "Replacing an SSH server key requires explicit confirmation.")
	}
	if e := os.MkdirAll(filepath.Dir(m.knownHosts), 0700); e != nil {
		return failure("trust_store", "Cannot save the SSH server key.")
	}
	lock, e := os.OpenFile(m.knownHosts+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		return failure("trust_store", "Cannot lock SSH host-key records.")
	}
	defer lock.Close()
	lockCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if err := lockTrustFile(lockCtx, lock); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	current, err := readRecords(m.knownHosts, managedEndpoint(s))
	if err != nil {
		return err
	}
	if _, _, err = m.checkKnownKeys(s, []hostKey{c.key}, current); err != nil {
		return err
	}
	if recordsDigest(current) != c.baseline {
		if len(current) == 1 && current[0].marker == "" && current[0].key == c.key {
			return nil
		}
		return failure("stale_challenge", "The SSH trust records changed. Review the server key again.")
	}
	// An atomic replacement prevents partially written trust records. Trust is only
	// written under a cross-helper lock; system records remain read-only.
	data, e := os.ReadFile(m.knownHosts)
	if e != nil && !errors.Is(e, os.ErrNotExist) {
		return failure("trust_store", "Cannot read SSH host-key records.")
	}
	var lines []string
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		if len(matchingRecords([]byte(line), managedEndpoint(s))) == 0 {
			lines = append(lines, line)
		}
	}
	lines = append(lines, fmt.Sprintf("%s %s %s", managedEndpoint(s), c.key.algorithm, c.key.blob))
	file, e := os.CreateTemp(filepath.Dir(m.knownHosts), ".ssh-trust-")
	if e != nil {
		return failure("trust_store", "Cannot save the SSH server key.")
	}
	defer os.Remove(file.Name())
	if _, e = file.WriteString(strings.Join(lines, "\n") + "\n"); e == nil {
		e = file.Sync()
	}
	closeErr := file.Close()
	if e == nil {
		e = closeErr
	}
	if e == nil {
		e = os.Rename(file.Name(), m.knownHosts)
	}
	if e != nil {
		return failure("trust_store", "Cannot save the SSH server key.")
	}
	return nil
}

// Never accumulate untrusted command output without a bound.
type limitedBuffer struct{ bytes.Buffer }

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if b.Len()+len(p) > 256*1024 {
		return 0, errors.New("output limit")
	}
	return b.Buffer.Write(p)
}

func managedEndpoint(s *protocol.SSHSettings) string {
	sum := sha256.Sum256([]byte(s.ProfileID + "\x00" + endpoint(s)))
	return "dbeer-profile-" + hex.EncodeToString(sum[:])
}

func recordsDigest(records []record) string {
	if len(records) == 0 {
		return ""
	}
	h := sha256.New()
	for _, r := range records {
		fmt.Fprintf(h, "%s\x00%s\x00%s\n", r.marker, r.key.algorithm, r.key.blob)
	}
	return hex.EncodeToString(h.Sum(nil))
}

func lockTrustFile(ctx context.Context, file *os.File) error {
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	for {
		err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return nil
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EAGAIN {
			return failure("trust_store", "Cannot lock SSH host-key records.")
		}
		select {
		case <-ctx.Done():
			return failure("trust_store_busy", "SSH host-key records are busy. Try the connection again.")
		case <-ticker.C:
		}
	}
}
