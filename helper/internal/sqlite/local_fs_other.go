//go:build !darwin

package sqlite

// Native macOS connections enforce MNT_LOCAL. Other platforms retain helper
// portability without claiming filesystem classification for their prototypes.
func localFilesystem(path string) bool { return true }
