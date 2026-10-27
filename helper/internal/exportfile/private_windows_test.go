//go:build windows

package exportfile

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"unsafe"

	"dbeer/helper/internal/protocol"
)

// These fixtures and fault targets belong exclusively to this test under build/.
func ownedWindowsDirectory(t *testing.T) string {
	t.Helper()
	root := filepath.Join("..", "..", "..", "build", "gpui", "quality-windows-export-tests")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal("cannot create owned test root")
	}
	directory, err := os.MkdirTemp(root, "case-")
	if err != nil {
		t.Fatal("cannot create owned test directory")
	}
	directory, err = filepath.Abs(directory)
	if err != nil {
		t.Fatal("cannot resolve owned test directory")
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	return directory
}

func privateDescriptor(t *testing.T, file *os.File) string {
	t.Helper()
	advapi := syscall.NewLazyDLL("advapi32.dll")
	get := advapi.NewProc("GetKernelObjectSecurity")
	convert := advapi.NewProc("ConvertSecurityDescriptorToStringSecurityDescriptorW")
	var needed uint32
	_, _, _ = get.Call(file.Fd(), 4, 0, 0, uintptr(unsafe.Pointer(&needed)))
	if needed == 0 {
		t.Fatal("cannot size private descriptor")
	}
	buffer := make([]byte, needed)
	ok, _, _ := get.Call(file.Fd(), 4, uintptr(unsafe.Pointer(&buffer[0])), uintptr(needed), uintptr(unsafe.Pointer(&needed)))
	if ok == 0 {
		t.Fatal("cannot inspect private descriptor")
	}
	var text *uint16
	ok, _, _ = convert.Call(uintptr(unsafe.Pointer(&buffer[0])), 1, 4, uintptr(unsafe.Pointer(&text)), 0)
	if ok == 0 {
		t.Fatal("cannot encode private descriptor")
	}
	defer syscall.LocalFree(syscall.Handle(uintptr(unsafe.Pointer(text))))
	length := 0
	for *(*uint16)(unsafe.Add(unsafe.Pointer(text), length*2)) != 0 {
		length++
	}
	return syscall.UTF16ToString(unsafe.Slice(text, length))
}

func TestWindowsProtectedDescriptorExistsAtCreationAndFullExportsPublish(t *testing.T) {
	directory := ownedWindowsDirectory(t)
	// Inspect the same creation primitive before the first byte is written.
	empty, err := createTemporary(directory)
	if err != nil {
		t.Fatal("private CREATE_NEW failed")
	}
	descriptor := privateDescriptor(t, empty)
	if !strings.HasPrefix(descriptor, "D:P(A;;FA;;;") || strings.Count(descriptor, "(A;") != 1 {
		t.Fatal("temporary inherited a broader descriptor")
	}
	if info, err := empty.Stat(); err != nil || info.Size() != 0 {
		t.Fatal("creation wrote content before the private boundary")
	}
	name := empty.Name()
	_ = empty.Close()
	_ = os.Remove(name)
	for _, format := range []string{"json", "csv"} {
		path := filepath.Join(directory, "output."+format)
		writer, err := New(protocol.ExportRequest{Path: path, Format: format})
		if err != nil {
			t.Fatal("ordinary Windows export creation failed")
		}
		if privateDescriptor(t, writer.file) != descriptor {
			t.Fatal("writer lost the private staging descriptor")
		}
		if writer.Begin(0, []protocol.Column{{Index: 0, Name: "x"}}) != nil || writer.Row(0, []*string{pointer("synthetic")}) != nil || writer.End(0, protocol.ResultSet{RowCount: 1, CommandTag: "SELECT 1"}) != nil || writer.Commit() != nil {
			writer.Abort()
			t.Fatal("full export did not publish")
		}
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal("published export missing")
		}
		if format == "csv" && string(data) != "x\nsynthetic\n" {
			t.Fatal("CSV bytes changed")
		}
		if format == "json" {
			var document struct{ ResultSets []struct{ Rows [][]string } }
			if json.Unmarshal(data, &document) != nil || len(document.ResultSets) != 1 || len(document.ResultSets[0].Rows) != 1 || document.ResultSets[0].Rows[0][0] != "synthetic" {
				t.Fatal("JSON bytes changed")
			}
		}
	}
	temporary, _ := filepath.Glob(filepath.Join(directory, ".dbeer-export-*"))
	if len(temporary) != 0 {
		t.Fatal("successful publication retained staging files")
	}
}
