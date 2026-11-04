package postgres

// DatabaseToolsServerVersion exposes only the server's startup version, never
// credentials, SQL, results or a retained driver buffer.
func (s *Session) DatabaseToolsServerVersion() string {
	return s.conn.PgConn().ParameterStatus("server_version")
}
