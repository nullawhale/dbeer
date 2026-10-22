//go:build !darwin && !linux

package resultartifact

import "os"

// Snapshot comparison currently targets the native macOS client and its shared
// helper. Fail closed where the required descriptor checks are not implemented.
func openManagedRoot(string) (*os.Root, error)                    { return nil, ErrUnavailable }
func openArtifactDirectory(*os.Root, string) (*os.Root, error)    { return nil, ErrUnavailable }
func openRegular(*os.Root, string) (*os.File, os.FileInfo, error) { return nil, nil, ErrUnavailable }
func checkArtifactEntries(*os.Root) error                         { return ErrUnavailable }
func unchanged(*os.File, os.FileInfo) error                       { return ErrUnavailable }
