package protocol

import (
	"bytes"
	"encoding/json"
	"net"
	"path/filepath"
	"strings"
	"unicode"
	"unicode/utf8"
)

// SSHSettings exists only at the runtime boundary; secrets must never be saved
// with a profile or included in profile transfer documents.
type SSHSettings struct {
	ProfileID    string `json:"profileId"`
	Host         string `json:"host"`
	Port         int    `json:"port"`
	User         string `json:"user"`
	AuthMethod   string `json:"authMethod"`
	IdentityFile string `json:"identityFile,omitempty"`
	Password     string `json:"password,omitempty"`
	Passphrase   string `json:"passphrase,omitempty"`
}
type SSHTrust struct {
	Token   string `json:"token"`
	Replace bool   `json:"replace,omitempty"`
}
type SSHProbe struct {
	Status         string `json:"status"`
	ChallengeToken string `json:"challengeToken,omitempty"`
	Host           string `json:"host"`
	Port           int    `json:"port"`
	Algorithm      string `json:"algorithm"`
	Fingerprint    string `json:"fingerprint"`
}

func (s SSHSettings) Valid() bool {
	if !ValidID(s.ProfileID) || len(s.Host) == 0 || len(s.Host) > 253 || strings.HasPrefix(s.Host, "-") || s.Port < 1 || s.Port > 65535 || len(s.User) == 0 || len(s.User) > 255 || strings.HasPrefix(s.User, "-") {
		return false
	}
	for _, v := range []string{s.ProfileID, s.Host, s.User, s.IdentityFile, s.Password, s.Passphrase} {
		if !utf8.ValidString(v) || strings.ContainsRune(v, 0) {
			return false
		}
	}
	for _, v := range []string{s.ProfileID, s.Host, s.User} {
		for _, c := range v {
			if unicode.IsSpace(c) || unicode.IsControl(c) {
				return false
			}
		}
	}
	if strings.ContainsAny(s.Host, "/\\@[],*?!|#") || (strings.Contains(s.Host, ":") && net.ParseIP(s.Host) == nil) || strings.ContainsAny(s.User, "@/\\") || len(s.IdentityFile) > 4096 || len(s.Password) > 16384 || len(s.Passphrase) > 16384 {
		return false
	}
	if net.ParseIP(s.Host) == nil {
		for _, c := range s.Host {
			if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-') {
				return false
			}
		}
	}
	switch s.AuthMethod {
	case "agent":
		return s.IdentityFile == "" && s.Password == "" && s.Passphrase == ""
	case "privateKey":
		return filepath.IsAbs(s.IdentityFile) && s.Password == ""
	case "password":
		return s.IdentityFile == "" && s.Passphrase == ""
	default:
		return false
	}
}
func parseSSH(raw json.RawMessage) (*SSHSettings, bool) {
	var s SSHSettings
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || d.Decode(&s) != nil || !s.Valid() {
		return nil, false
	}
	return &s, true
}
