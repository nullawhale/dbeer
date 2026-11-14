package mariadb

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"regexp"
	"strconv"
	"strings"
)

type nativeServerInfo struct{ version, comment, identity string }

var nativeVersionPattern = regexp.MustCompile(`^([0-9]+)\.([0-9]+)\.([0-9]+)(?:[-+].*)?$`)

func supportedNativeVersion(version, comment string) bool {
	if !strings.Contains(strings.ToLower(version+" "+comment), "mariadb") {
		return false
	}
	parts := nativeVersionPattern.FindStringSubmatch(version)
	if len(parts) != 4 {
		return false
	}
	major, e1 := strconv.Atoi(parts[1])
	minor, e2 := strconv.Atoi(parts[2])
	patch, e3 := strconv.Atoi(parts[3])
	return e1 == nil && e2 == nil && e3 == nil && (major == 10 && minor == 11 && patch >= 9 || major == 11 && minor == 4 && patch >= 3)
}

func observeNativeServer(c *connection) (nativeServerInfo, error) {
	var info nativeServerInfo
	result, err := c.client.Execute("SELECT VERSION(), @@version_comment, @@server_uid, CONNECTION_ID()")
	if err != nil {
		return info, err
	}
	defer result.Close()
	if result.RowNumber() != 1 {
		return info, errors.New("invalid native server observation")
	}
	version, e1 := result.GetString(0, 0)
	comment, e2 := result.GetString(0, 1)
	uid, e3 := result.GetString(0, 2)
	id, e4 := result.GetUint(0, 3)
	raw, e5 := base64.StdEncoding.DecodeString(uid)
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil || e5 != nil || id == 0 || id != uint64(c.client.GetConnectionID()) || len(raw) != 20 || base64.StdEncoding.EncodeToString(raw) != uid || !supportedNativeVersion(version, comment) {
		return info, errors.New("native server identity is unavailable or unsupported")
	}
	info.version, info.comment = strings.Clone(version), strings.Clone(comment)
	sum := sha256.Sum256([]byte(version + "\x00" + comment + "\x00" + uid))
	info.identity = hex.EncodeToString(sum[:])
	return info, nil
}

func serverIdentity(c *connection) (string, error) {
	info, err := observeNativeServer(c)
	return info.identity, err
}

func (s *Session) nativeServerObservation() (version, versionComment, identity string) {
	return s.serverVersion, s.explainVendor, s.serverIdentity
}
