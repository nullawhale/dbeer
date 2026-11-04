package dbtools

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func certificateFixture(t *testing.T) []byte {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal("cannot generate fixture key")
	}
	certificate := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, certificate, certificate, public, private)
	if err != nil {
		t.Fatal("cannot generate fixture certificate")
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

func TestDatabaseToolsVerifiedTLSRejectsMissingOrInvalidCABeforeProbe(t *testing.T) {
	for _, mode := range []string{"verify-ca", "verify-full"} {
		for _, ca := range []string{"", "missing", "invalid"} {
			t.Run(mode+"-"+ca, func(t *testing.T) {
				var opens atomic.Int32
				m, err := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
					opens.Add(1)
					return &fakeSession{}, nil
				}, Options{Root: t.TempDir()})
				if err != nil {
					t.Fatal("cannot create utility manager")
				}
				defer m.Close()
				c := connection()
				c.SSLMode = mode
				if ca != "" {
					c.SSLRootCert = filepath.Join(t.TempDir(), ca)
					if ca == "invalid" {
						os.WriteFile(c.SSLRootCert, []byte("not a certificate"), 0600)
					}
				}
				r := m.Handle(protocol.Command{Type: "dbtools.preview", RequestID: "ca-preview", DatabaseTools: &protocol.DatabaseToolsRequest{Connection: &c, Operation: "dump", Format: "custom", Path: filepath.Join(t.TempDir(), "dump"), ToolPath: filepath.Join(t.TempDir(), "pg_dump")}})
				if r.Type != "error" || opens.Load() != 0 || !strings.Contains(r.Message, "CA certificate") {
					t.Fatal("invalid utility trust was not rejected before a connection or utility probe")
				}
			})
		}
	}
}

func TestDatabaseToolsCABytesAreBoundToReviewedPlan(t *testing.T) {
	ca := certificateFixture(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "ca.pem")
	os.WriteFile(path, ca, 0600)
	var captured string
	m, err := New(func(_ context.Context, c protocol.Connection) (adapter.Session, error) {
		captured = c.SSLRootCert
		return &fakeSession{}, nil
	}, Options{Root: t.TempDir()})
	if err != nil {
		t.Fatal("cannot create utility manager")
	}
	defer m.Close()
	c := connection()
	c.SSLMode, c.SSLRootCert = "verify-full", path
	dump := filepath.Join(dir, "dump")
	tool := fakeUtility(t, "pg_dump", "exec /bin/cat \"$PGSSLROOTCERT\"")
	r := m.Handle(protocol.Command{Type: "dbtools.preview", RequestID: "ca-preview", DatabaseTools: &protocol.DatabaseToolsRequest{Connection: &c, Operation: "dump", Format: "custom", Path: dump, ToolPath: tool}})
	if r.DatabaseTools == nil || captured == "" || captured == path {
		t.Fatal("preview did not use a retained CA copy")
	}
	info, err := os.Stat(captured)
	if err != nil || info.Mode().Perm() != 0400 {
		t.Fatal("retained CA is not private and immutable")
	}
	os.WriteFile(path, certificateFixture(t), 0600)
	done := await(t, m, start(t, m, *r.DatabaseTools))
	data, err := os.ReadFile(dump)
	if done.State != "completed" || err != nil || string(data) != string(ca) {
		t.Fatal("utility trust changed after review")
	}
}
