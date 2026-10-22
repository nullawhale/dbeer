//go:build darwin || linux

package resultartifact

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestSymlinksHardlinksAndSpecialFilesRejected(t *testing.T) {
	for _, name := range []string{"root symlink", "artifact symlink", "manifest symlink", "rows symlink", "manifest hardlink", "rows hardlink", "settings symlink", "rows directory", "rows FIFO", "extra file", "writable root", "writable artifact", "writable rows"} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			directory := writeArtifact(t, root, fixtureManifest(t), fixtureRows(t))
			outside := t.TempDir()
			outsideDirectory := writeArtifact(t, outside, fixtureManifest(t), fixtureRows(t))
			var err error
			switch name {
			case "root symlink":
				link := filepath.Join(t.TempDir(), "snapshots")
				err = os.Symlink(root, link)
				root = link
			case "artifact symlink":
				err = os.RemoveAll(directory)
				if err == nil {
					err = os.Symlink(outsideDirectory, directory)
				}
			case "manifest symlink", "rows symlink", "manifest hardlink", "rows hardlink":
				file := "rows.jsonl"
				if name == "manifest symlink" || name == "manifest hardlink" {
					file = "manifest.json"
				}
				err = os.Remove(filepath.Join(directory, file))
				if err == nil {
					if name == "manifest symlink" || name == "rows symlink" {
						err = os.Symlink(filepath.Join(outsideDirectory, file), filepath.Join(directory, file))
					} else {
						err = os.Link(filepath.Join(outsideDirectory, file), filepath.Join(directory, file))
					}
				}
			case "settings symlink":
				settings := filepath.Join(outside, "settings.json")
				err = os.WriteFile(settings, []byte(`{"version":1,"quotaBytes":100000}`), 0o600)
				if err == nil {
					err = os.Symlink(settings, filepath.Join(root, "settings.json"))
				}
			case "rows directory", "rows FIFO":
				path := filepath.Join(directory, "rows.jsonl")
				err = os.Remove(path)
				if err == nil {
					if name == "rows directory" {
						err = os.Mkdir(path, 0o700)
					} else {
						err = syscall.Mkfifo(path, 0o600)
					}
				}
			case "extra file":
				err = os.WriteFile(filepath.Join(directory, "unexpected"), []byte("unexpected"), 0o600)
			case "writable root":
				err = os.Chmod(root, 0o777)
			case "writable artifact":
				err = os.Chmod(directory, 0o777)
			case "writable rows":
				err = os.Chmod(filepath.Join(directory, "rows.jsonl"), 0o666)
			}
			if err != nil {
				t.Fatal(err)
			}
			artifact, err := NewStore(root).Open(context.Background(), fixtureID)
			if artifact != nil {
				artifact.Close()
			}
			if !errors.Is(err, ErrCorrupt) && !errors.Is(err, ErrUnavailable) {
				t.Fatalf("unsafe artifact accepted: %v", err)
			}
		})
	}
}

func TestManagedPathsAndMissingArtifacts(t *testing.T) {
	for _, root := range []string{"", ".", "/", "bad\x00path"} {
		if _, err := NewStore(root).Open(context.Background(), fixtureID); !errors.Is(err, ErrUnavailable) {
			t.Fatalf("invalid root %q: %v", root, err)
		}
	}
	if _, err := NewStore(filepath.Join(t.TempDir(), "missing")).Open(context.Background(), fixtureID); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("missing root: %v", err)
	}
	if _, err := NewStore(t.TempDir()).Open(context.Background(), fixtureID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing snapshot: %v", err)
	}
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, fixtureID), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewStore(root).Open(context.Background(), fixtureID); !errors.Is(err, ErrCorrupt) {
		t.Fatalf("snapshot is regular file: %v", err)
	}
}

func TestRelativeSymlinksWithinManagedRootAreRejected(t *testing.T) {
	for _, name := range []string{"directory", "manifest.json", "rows.jsonl"} {
		root := t.TempDir()
		directory := writeArtifact(t, root, fixtureManifest(t), fixtureRows(t))
		backing := filepath.Join(root, "backing")
		if name == "directory" {
			if err := os.Rename(directory, backing); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink("backing", directory); err != nil {
				t.Fatal(err)
			}
		} else {
			if err := os.Mkdir(backing, 0o700); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(directory, name)
			if err := os.Rename(path, filepath.Join(backing, name)); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink("../backing/"+name, path); err != nil {
				t.Fatal(err)
			}
		}
		if artifact, err := NewStore(root).Open(context.Background(), fixtureID); artifact != nil || !errors.Is(err, ErrCorrupt) {
			if artifact != nil {
				artifact.Close()
			}
			t.Fatalf("relative %s symlink accepted: %v", name, err)
		}
	}
}

func TestRowsMutationAndReplacementAfterValidationRejected(t *testing.T) {
	for _, mutation := range []string{"in place", "in place restored mtime", "truncate", "replace", "hardlink", "during scan"} {
		t.Run(mutation, func(t *testing.T) {
			artifact, directory := openFixture(t)
			var ref RowRef
			if err := artifact.Scan(context.Background(), func(value RowRef, _ []*string) error { ref = value; return nil }); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(directory, "rows.jsonl")
			before, err := os.Stat(path)
			if err != nil {
				t.Fatal(err)
			}
			rows := bytes.Replace(fixtureRows(t), []byte("NULL"), []byte("NOPE"), 1)
			mutate := func() error {
				switch mutation {
				case "replace":
					replacement := filepath.Join(t.TempDir(), "replacement")
					if err := os.WriteFile(replacement, fixtureRows(t), 0o600); err != nil {
						return err
					}
					return os.Rename(replacement, path)
				case "truncate":
					return os.Truncate(path, 0)
				case "hardlink":
					return os.Link(path, filepath.Join(t.TempDir(), "linked"))
				default:
					if err := os.WriteFile(path, rows, 0o600); err != nil {
						return err
					}
					if mutation == "in place restored mtime" {
						return os.Chtimes(path, before.ModTime(), before.ModTime())
					}
					return nil
				}
			}
			if mutation == "during scan" {
				var once bool
				err := artifact.Scan(context.Background(), func(RowRef, []*string) error {
					if !once {
						once = true
						return mutate()
					}
					return nil
				})
				if !errors.Is(err, ErrCorrupt) {
					t.Fatalf("mutation during scan accepted: %v", err)
				}
			} else if err := mutate(); err != nil {
				t.Fatal(err)
			}
			if _, err := artifact.ReadRow(context.Background(), ref); !errors.Is(err, ErrCorrupt) {
				t.Fatalf("read accepted changed rows: %v", err)
			}
			if err := artifact.Scan(context.Background(), nil); !errors.Is(err, ErrCorrupt) {
				t.Fatalf("scan accepted changed rows: %v", err)
			}
		})
	}
}

func TestPinnedStoreAndArtifactDirectorySurviveParentRename(t *testing.T) {
	artifact, directory := openFixture(t)
	root := filepath.Dir(directory)
	newRoot := root + "-renamed"
	if err := os.Rename(root, newRoot); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(newRoot) })
	// Replacing the old path with an unrelated directory cannot redirect a reader
	// that has already pinned and validated its own row descriptor.
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := artifact.Scan(context.Background(), nil); err != nil {
		t.Fatalf("pinned reader followed renamed parent: %v", err)
	}
}

func TestConcurrentRowReplacementNeverFollowsLinksOrBlocksOnFIFO(t *testing.T) {
	root := t.TempDir()
	rows := fixtureRows(t)
	directory := writeArtifact(t, root, fixtureManifest(t), rows)
	path := filepath.Join(directory, "rows.jsonl")
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(outside, []byte("outside the managed store"), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stop := make(chan struct{})
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		for {
			select {
			case <-stop:
				return
			default:
			}
			_ = os.Remove(path)
			_ = syscall.Mkfifo(path, 0o600)
			_ = os.Remove(path)
			_ = os.Symlink(outside, path)
			_ = os.Remove(path)
			_ = os.WriteFile(path, rows, 0o600)
		}
	}()
	defer func() { close(stop); <-stopped }()
	for range 100 {
		artifact, err := NewStore(root).Open(ctx, fixtureID)
		if err != nil {
			if !errors.Is(err, ErrCorrupt) && !errors.Is(err, ErrNotFound) {
				t.Fatalf("replacement race: %v", err)
			}
			continue
		}
		var count int
		err = artifact.Scan(ctx, func(_ RowRef, row []*string) error {
			if len(row) != 3 {
				t.Error("replacement yielded an invalid row")
			}
			count++
			return nil
		})
		artifact.Close()
		if err != nil && !errors.Is(err, ErrCorrupt) {
			t.Fatalf("replacement scan: %v", err)
		}
		if err == nil && count != 3 {
			t.Fatalf("replacement yielded an unvalidated count: %d", count)
		}
	}
	if ctx.Err() != nil {
		t.Fatal("descriptor opens blocked during FIFO replacement")
	}
}

type changedInfo struct {
	os.FileInfo
	stat syscall.Stat_t
}

func (i changedInfo) Sys() any { return &i.stat }

func TestOwnershipAndLinkCountValidation(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "file")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"owner", "nlink"} {
		fake := changedInfo{FileInfo: info, stat: *info.Sys().(*syscall.Stat_t)}
		if field == "owner" {
			fake.stat.Uid++
		} else {
			fake.stat.Nlink = 2
		}
		if ownedRegular(fake) {
			t.Fatalf("unsafe %s accepted", field)
		}
	}
	info, err = os.Stat(root)
	if err != nil {
		t.Fatal(err)
	}
	fake := changedInfo{FileInfo: info, stat: *info.Sys().(*syscall.Stat_t)}
	fake.stat.Uid++
	if ownedDirectory(fake) {
		t.Fatal("foreign-owned directory accepted")
	}
}
