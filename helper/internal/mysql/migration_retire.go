package mysql

// Keep the owner and leased tunnel available for retained local status only.
func (s *Session) StructureMigrationRetire() {
	s.transaction.Store("unknown")
	_ = s.work.transport.Close()
}
