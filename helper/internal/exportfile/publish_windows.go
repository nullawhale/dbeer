//go:build windows

package exportfile

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

var replaceFile = syscall.NewLazyDLL("kernel32.dll").NewProc("ReplaceFileW")
var moveFileEx = syscall.NewLazyDLL("kernel32.dll").NewProc("MoveFileExW")

func (d *destination) lock() error                  { return nil }
func openDestination(path string) (*os.File, error) { return os.Open(path) }
func (d *destination) publish(temporary string) error {
	if !d.valid() {
		return ErrIO
	}
	if d.info != nil && d.info.Mode().Perm()&0200 == 0 {
		return ErrIO
	}
	target, err := widePath(d.path)
	if err != nil {
		return ErrIO
	}
	source, err := widePath(temporary)
	if err != nil {
		return ErrIO
	}
	// Close retained destination read handle before replacement. ReplaceFile preserves target DACL/attributes.
	if d.file != nil {
		_ = d.file.Close()
		d.file = nil
	}
	var ok uintptr
	var callErr error
	if d.info != nil {
		ok, _, callErr = replaceFile.Call(uintptr(unsafe.Pointer(target)), uintptr(unsafe.Pointer(source)), 0, 0, 0, 0)
	} else {
		// MOVEFILE_WRITE_THROUGH, deliberately without REPLACE_EXISTING for captured absence.
		ok, _, callErr = moveFileEx.Call(uintptr(unsafe.Pointer(source)), uintptr(unsafe.Pointer(target)), 8)
	}
	if ok != 0 {
		return nil
	}
	// These documented replacement failures can move either file. Do not retry or claim preservation.
	if callErr == syscall.Errno(1175) || callErr == syscall.Errno(1176) || callErr == syscall.Errno(1177) {
		return ErrPublicationUnknown
	}
	return ErrIO
}

// CREATE_NEW installs the protected owner-only descriptor atomically, before
// either the JSON prefix or any query bytes can reach the staging file.
func createTemporary(parent string) (*os.File, error) {
	token, err := syscall.OpenCurrentProcessToken()
	if err != nil {
		return nil, ErrIO
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return nil, ErrIO
	}
	sid, err := user.User.Sid.String()
	if err != nil {
		return nil, ErrIO
	}
	sddl, err := syscall.UTF16PtrFromString("D:P(A;;FA;;;" + sid + ")")
	if err != nil {
		return nil, ErrIO
	}
	convert := syscall.NewLazyDLL("advapi32.dll").NewProc("ConvertStringSecurityDescriptorToSecurityDescriptorW")
	var descriptor uintptr
	ok, _, _ := convert.Call(uintptr(unsafe.Pointer(sddl)), 1, uintptr(unsafe.Pointer(&descriptor)), 0)
	if ok == 0 {
		return nil, ErrIO
	}
	defer syscall.LocalFree(syscall.Handle(descriptor))
	attributes := syscall.SecurityAttributes{Length: uint32(unsafe.Sizeof(syscall.SecurityAttributes{})), SecurityDescriptor: descriptor}
	for attempt := 0; attempt < 100; attempt++ {
		var random [16]byte
		if _, err := rand.Read(random[:]); err != nil {
			return nil, ErrIO
		}
		path := filepath.Join(parent, ".dbeer-export-"+hex.EncodeToString(random[:]))
		name, err := widePath(path)
		if err != nil {
			return nil, ErrIO
		}
		// READ/WRITE, DELETE, READ_CONTROL and WRITE_DAC on this exact retained handle.
		handle, err := syscall.CreateFile(name, 0xc0070000, syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE|syscall.FILE_SHARE_DELETE, &attributes, syscall.CREATE_NEW, syscall.FILE_ATTRIBUTE_NORMAL, 0)
		if err == syscall.ERROR_FILE_EXISTS || err == syscall.ERROR_ALREADY_EXISTS {
			continue
		}
		if err != nil {
			return nil, ErrIO
		}
		return os.NewFile(uintptr(handle), path), nil
	}
	return nil, ErrIO
}

func fileIdentity(file *os.File) (string, error) {
	var info syscall.ByHandleFileInformation
	if syscall.GetFileInformationByHandle(syscall.Handle(file.Fd()), &info) != nil {
		return "", ErrIO
	}
	return fmt.Sprintf("%d:%d", info.VolumeSerialNumber, uint64(info.FileIndexHigh)<<32|uint64(info.FileIndexLow)), nil
}

func widePath(path string) (*uint16, error) {
	if !strings.HasPrefix(path, `\\?\`) {
		if strings.HasPrefix(path, `\\`) {
			path = `\\?\UNC\` + path[2:]
		} else {
			path = `\\?\` + path
		}
	}
	return syscall.UTF16PtrFromString(path)
}
