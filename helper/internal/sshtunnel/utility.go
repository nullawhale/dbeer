package sshtunnel

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

type askpassBridge struct {
	path, token, secret string
	listener            net.Listener
	mu                  sync.Mutex
	used                bool
	once                sync.Once
}

func newAskpass(path, secret string) (*askpassBridge, error) {
	listener, e := net.Listen("unix", path)
	if e != nil {
		return nil, failure("authentication", "Cannot initialize SSH authentication.")
	}
	_ = os.Chmod(path, 0600)
	b := &askpassBridge{path: path, token: randomToken(), secret: secret, listener: listener}
	go b.serve()
	return b, nil
}
func (b *askpassBridge) Close() {
	b.once.Do(func() { b.listener.Close(); b.mu.Lock(); b.secret = ""; b.mu.Unlock(); os.Remove(b.path) })
}
func (b *askpassBridge) serve() {
	for {
		conn, e := b.listener.Accept()
		if e != nil {
			return
		}
		go func() {
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(5 * time.Second))
			var request struct {
				Token string `json:"token"`
			}
			if json.NewDecoder(io.LimitReader(conn, 512)).Decode(&request) != nil {
				return
			}
			b.mu.Lock()
			if subtle.ConstantTimeCompare([]byte(request.Token), []byte(b.token)) != 1 || b.used {
				b.mu.Unlock()
				return
			}
			b.used = true
			secret := b.secret
			b.secret = ""
			b.mu.Unlock()
			json.NewEncoder(conn).Encode(struct {
				Secret string `json:"secret"`
			}{secret})
		}()
	}
}
func sshEnvironment(executable, socket, token string) []string {
	// Configuration and askpass controls inherited from the shell must not alter
	// authentication, command execution, or the selected SSH destination.
	allowed := map[string]bool{"HOME": true, "USER": true, "LOGNAME": true, "SSH_AUTH_SOCK": true, "TMPDIR": true, "LANG": true, "LC_ALL": true}
	env := []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "DISPLAY=dbeer:0", "SSH_ASKPASS_REQUIRE=force", "SSH_ASKPASS=" + executable, "DBEER_SSH_ASKPASS_SOCKET=" + socket, "DBEER_SSH_ASKPASS_TOKEN=" + token}
	for _, v := range os.Environ() {
		k, _, _ := strings.Cut(v, "=")
		if allowed[k] {
			env = append(env, v)
		}
	}
	return env
}

// RunUtility must be dispatched before starting the framed protocol. Askpass
// uses the same signed executable; secrets travel only over private local IPC.
func RunUtility(args []string) (bool, error) {
	if len(args) > 0 && args[0] == "--ssh-known-host" {
		return true, runKnownHostUtility(args[1:])
	}
	// ssh passes its prompt as argv, so select askpass using the authenticated IPC
	// environment rather than treating or displaying untrusted prompt text.
	if socket := os.Getenv("DBEER_SSH_ASKPASS_SOCKET"); socket != "" && (len(args) == 0 || args[0] != "--ssh-watchdog") {
		conn, e := net.DialTimeout("unix", socket, 3*time.Second)
		if e != nil {
			return true, errors.New("SSH authentication unavailable")
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		if e = json.NewEncoder(conn).Encode(struct {
			Token string `json:"token"`
		}{os.Getenv("DBEER_SSH_ASKPASS_TOKEN")}); e != nil {
			return true, errors.New("SSH authentication unavailable")
		}
		var result struct {
			Secret string `json:"secret"`
		}
		if json.NewDecoder(io.LimitReader(conn, 65536)).Decode(&result) != nil {
			return true, errors.New("SSH authentication unavailable")
		}
		_, e = io.WriteString(os.Stdout, result.Secret+"\n")
		return true, e
	}
	if len(args) > 0 && args[0] == "--ssh-askpass" {
		return true, errors.New("SSH authentication unavailable")
	}
	if len(args) == 0 || args[0] != "--ssh-watchdog" {
		return false, nil
	}
	if len(args) < 3 {
		return true, errors.New("Invalid SSH watchdog invocation")
	}
	// File descriptor 3 is the helper-owned lifetime pipe. A helper crash closes
	// its writer; this independently running supervisor then reaps owned SSH.
	life := os.NewFile(3, "ssh-lifetime")
	if life == nil {
		return true, errors.New("SSH supervision unavailable")
	}
	defer life.Close()
	cmd := exec.Command("/usr/bin/ssh", args[2:]...)
	cmd.Stdin = nil
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	cmd.Env = os.Environ()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if e := cmd.Start(); e != nil {
		return true, errors.New("Cannot start SSH")
	}
	// ProxyJump and ProxyCommand descendants belong to this process group, even
	// when their immediate ssh parent exits before they do.
	defer syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	lost := make(chan struct{})
	go func() { io.Copy(io.Discard, life); close(lost) }()
	select {
	case e := <-exited:
		os.RemoveAll(args[1])
		return true, e
	case <-lost:
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		select {
		case <-exited:
		case <-time.After(1500 * time.Millisecond):
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			<-exited
		}
		os.RemoveAll(args[1])
		return true, nil
	}
}
