package protocol

import (
	"net"
	"strings"
	"unicode/utf8"
)

// MongoDBSettings contains portable, non-secret topology/authentication metadata.
// Passwords continue to use Connection.Password or the local password command.
type MongoDBSettings struct {
	AuthSource       string `json:"authSource,omitempty"`
	AuthMechanism    string `json:"authMechanism,omitempty"`
	ReplicaSet       string `json:"replicaSet,omitempty"`
	DirectConnection bool   `json:"directConnection,omitempty"`
}

func (s MongoDBSettings) Valid() bool {
	for _, text := range []string{s.AuthSource, s.ReplicaSet} {
		if len(text) > 1024 || !utf8.ValidString(text) || strings.ContainsAny(text, "\x00\r\n") {
			return false
		}
	}
	return s.AuthMechanism == "" || s.AuthMechanism == "SCRAM-SHA-256" || s.AuthMechanism == "SCRAM-SHA-1"
}

func (c Connection) validMongoDB() bool {
	if c.MongoDB != nil && !c.MongoDB.Valid() || c.LocalDatacenter != "" || c.Consistency != "" ||
		len(c.ContactPoints) > 32 || c.User == "" && c.Password != "" || c.SSLMode != "disable" && c.SSLMode != "verify-full" {
		return false
	}
	for _, value := range []string{c.Host, c.Database, c.User} {
		if len(value) > 1024 || !utf8.ValidString(value) || strings.ContainsRune(value, 0) {
			return false
		}
	}
	if !mongoHost(c.Host) {
		return false
	}
	for _, host := range c.ContactPoints {
		if !mongoHost(host) {
			return false
		}
	}
	if c.SSH != nil && (c.MongoDB == nil || !c.MongoDB.DirectConnection) {
		return false
	}
	if c.MongoDB != nil && c.MongoDB.DirectConnection && len(c.ContactPoints) > 1 {
		return false
	}
	return c.SSH == nil || len(c.ContactPoints) == 0
}

func mongoHost(host string) bool {
	return host != "" && len(host) <= 1024 && utf8.ValidString(host) && !strings.ContainsAny(host, " \t\n\r\x00/@?#,\\[]%") && (!strings.Contains(host, ":") || net.ParseIP(host) != nil)
}
