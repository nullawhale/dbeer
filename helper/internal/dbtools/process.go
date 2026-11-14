package dbtools

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

var errTool = errors.New("The selected database utility is unavailable or changed. Select a compatible utility and preview again.")

type toolIdentity struct {
	path, resolved, digest string
	info                   os.FileInfo
}
type toolVersion struct {
	major, minor, patch int
	text                string
}

var pgVersion = regexp.MustCompile(`\(PostgreSQL\) ([0-9]+)(?:\.([0-9]+))?(?:\.([0-9]+))?`)
var mysqlVersion = regexp.MustCompile(`(?i)(?:Ver|Distrib) ([0-9]+)\.([0-9]+)\.([0-9]+)`)

func captureTool(path, name string) (*toolIdentity, error) {
	if !filepath.IsAbs(path) || filepath.Base(path) != name {
		return nil, errTool
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return nil, errTool
	}
	f, info, err := openReadonlyRegular(resolved)
	if err != nil {
		return nil, errTool
	}
	defer f.Close()
	const maxToolSize = 512 * 1024 * 1024
	if info.Mode().Perm()&0111 == 0 || info.Size() > maxToolSize {
		return nil, errTool
	}
	h := sha256.New()
	if count, err := io.Copy(h, io.LimitReader(f, maxToolSize+1)); err != nil || count > maxToolSize {
		return nil, errTool
	}
	after, err := f.Stat()
	if err != nil || after.Size() != info.Size() || !after.ModTime().Equal(info.ModTime()) {
		return nil, errTool
	}
	return &toolIdentity{path: path, resolved: resolved, digest: hex.EncodeToString(h.Sum(nil)), info: info}, nil
}
func (identity *toolIdentity) valid() bool {
	current, err := captureTool(identity.path, filepath.Base(identity.path))
	return err == nil && current.resolved == identity.resolved && os.SameFile(identity.info, current.info) && current.digest == identity.digest
}

type limitedOutput struct {
	bytes  []byte
	limit  int
	cancel context.CancelFunc
}

func (out *limitedOutput) Write(data []byte) (int, error) {
	if len(data) > out.limit-len(out.bytes) {
		out.cancel()
		return 0, io.ErrShortWrite
	}
	out.bytes = append(out.bytes, data...)
	return len(data), nil
}
func process(ctx context.Context, path string, args, env []string, stdin io.Reader, stdout io.Writer) (int, error) {
	supervisor, err := os.Executable()
	if err != nil {
		return -1, err
	}
	life, keepAlive, err := os.Pipe()
	if err != nil {
		return -1, err
	}
	defer life.Close()
	defer keepAlive.Close()
	commandArgs := append([]string{"--dbtools-watchdog", path}, args...)
	cmd := exec.CommandContext(ctx, supervisor, commandArgs...)
	cmd.Env, cmd.Stdin, cmd.Stdout, cmd.Stderr = env, stdin, stdout, io.Discard
	cmd.ExtraFiles = []*os.File{life}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM) }
	cmd.WaitDelay = 2 * time.Second
	if err := cmd.Start(); err != nil {
		return -1, err
	}
	err = cmd.Wait()
	// Descendants may outlive their immediate utility parent. Only this private
	// process group is signalled; SQL tabs and unrelated clients are untouched.
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	code := cmd.ProcessState.ExitCode()
	return code, err
}
func probeTool(ctx context.Context, tool *toolIdentity, engine, home string) (toolVersion, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out := &limitedOutput{limit: 4096, cancel: cancel}
	code, err := process(ctx, tool.path, []string{"--version"}, baseEnvironment(home), nil, out)
	if err != nil || code != 0 {
		return toolVersion{}, errTool
	}
	pattern := pgVersion
	if engine == "mysql" {
		pattern = mysqlVersion
	}
	if engine == "mariadb" {
		pattern = mariaDBToolVersion
	}
	match := pattern.FindStringSubmatch(string(out.bytes))
	if len(match) != 4 {
		return toolVersion{}, errTool
	}
	if engine == "mysql" && (strings.Contains(strings.ToLower(string(out.bytes)), "mariadb") || strings.Contains(strings.ToLower(string(out.bytes)), "percona")) {
		return toolVersion{}, errTool
	}
	major, _ := strconv.Atoi(match[1])
	minor, _ := strconv.Atoi(match[2])
	patch, _ := strconv.Atoi(match[3])
	return toolVersion{major: major, minor: minor, patch: patch, text: strings.TrimPrefix(match[0], "(PostgreSQL) ")}, nil
}
func baseEnvironment(home string) []string {
	return []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + home, "LC_ALL=C", "LANG=C", "TMPDIR=" + home, "PAGER=cat", "PGSYSCONFDIR=" + home, "PSQL_HISTORY=/dev/null", "MYSQL_HISTFILE=/dev/null", "MYSQL_TEST_LOGIN_FILE=" + filepath.Join(home, "no-login")}
}

type countingWriter struct {
	out   io.Writer
	count *atomic.Int64
}

func (w countingWriter) Write(data []byte) (int, error) {
	n, err := w.out.Write(data)
	w.count.Add(int64(n))
	return n, err
}

type countingReader struct {
	in    io.Reader
	count *atomic.Int64
	ctx   context.Context
}

func (r countingReader) Read(data []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	n, err := r.in.Read(data)
	r.count.Add(int64(n))
	return n, err
}
