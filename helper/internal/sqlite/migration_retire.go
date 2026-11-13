package sqlite

func (s *Session) StructureMigrationRetire() { s.structureUncertain = true; s.Close() }
