package mysql

import "strings"

// DatabaseToolsServerVersion returns an owned server handshake value.
func (s *Session) DatabaseToolsServerVersion() string {
	return strings.Clone(s.work.client.GetServerVersion())
}
