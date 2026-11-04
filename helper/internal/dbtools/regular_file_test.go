package dbtools

import (
	"context"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestDatabaseToolsRejectsNamedPipesBeforeBlockingOpen(t *testing.T) {
	for _, kind := range []string{"restore", "certificate", "utility", "utility-recheck"} {
		t.Run(kind, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "pg_dump")
			var identity *toolIdentity
			if kind == "utility-recheck" {
				if os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0700) != nil {
					t.Fatal("cannot create utility identity fixture")
				}
				var err error
				identity, err = captureTool(path, "pg_dump")
				if err != nil || os.Remove(path) != nil {
					t.Fatal("cannot replace utility identity fixture")
				}
			}
			if syscall.Mkfifo(path, 0700) != nil {
				t.Fatal("cannot create named pipe fixture")
			}
			rejected := make(chan bool, 1)
			go func() {
				switch kind {
				case "restore":
					_, err := freezeInput(context.Background(), path, dir, false)
					rejected <- err != nil
				case "certificate":
					c := connection()
					c.SSLRootCert = path
					rejected <- freezeRootCertificate(&c, dir) != nil
				case "utility":
					_, err := captureTool(path, "pg_dump")
					rejected <- err != nil
				case "utility-recheck":
					rejected <- !identity.valid()
				}
			}()
			select {
			case invalid := <-rejected:
				if !invalid {
					t.Fatal("named pipe was accepted as a regular file")
				}
			case <-time.After(time.Second):
				// Release an old blocking reader before reporting the regression,
				// so the test does not leave a hung worker behind.
				writer, _ := os.OpenFile(path, os.O_RDWR|syscall.O_NONBLOCK, 0)
				if writer != nil {
					writer.Close()
				}
				select {
				case <-rejected:
				case <-time.After(time.Second):
				}
				t.Fatal("named pipe blocked utility preparation")
			}
		})
	}
}

func TestDatabaseToolsRejectsOversizedExecutableBeforeHashing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pg_dump")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0700)
	if err != nil {
		t.Fatal("cannot create executable size fixture")
	}
	err = file.Truncate(512*1024*1024 + 1)
	file.Close()
	if err != nil {
		t.Fatal("cannot size sparse executable fixture")
	}
	if _, err := captureTool(path, "pg_dump"); err == nil {
		t.Fatal("oversized executable was hashed and accepted")
	}
}
