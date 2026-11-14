package postgres

func (s *Session) StructureMigrationRetire() { closeConnection(s.conn) }
