// Package sqlite implements local, independently owned SQLite sessions.
package sqlite

import (
	"context"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	lib "zombiezen.com/go/sqlite"
)

type Session struct {
	adapter.TransportBinding
	conn              *lib.Conn
	settings          protocol.Connection
	path              string
	identity          os.FileInfo
	readOnly          bool
	internal          bool
	closed            bool
	attachAllowed     string
	attachmentChanged bool
	attachments       map[string]os.FileInfo
	attachPath        string
	attachIdentity    os.FileInfo
	allowVacuum       bool
}

func localFile(path string) (os.FileInfo, error) {
	if !filepath.IsAbs(path) || strings.ContainsRune(path, 0) || strings.HasPrefix(path, "file:") {
		return nil, errors.New("Choose an existing local SQLite file.")
	}
	i, err := os.Stat(path)
	if err != nil || !i.Mode().IsRegular() {
		return nil, errors.New("The SQLite file is missing or unavailable.")
	}
	if !localFilesystem(path) {
		return nil, errors.New("Choose a SQLite file on a local filesystem.")
	}
	return i, nil
}

func Open(ctx context.Context, settings protocol.Connection) (adapter.Session, error) {
	if settings.SQLite == nil {
		return nil, &adapter.ConnectionError{Category: "connection", Message: "Choose a SQLite database file."}
	}
	i, err := localFile(settings.SQLite.Path)
	if err != nil {
		return nil, &adapter.ConnectionError{Category: "connection", Message: err.Error()}
	}
	ro := settings.Policy != nil && settings.Policy.ReadOnly
	flags := lib.OpenReadWrite | lib.OpenURI
	if ro {
		flags = lib.OpenReadOnly | lib.OpenURI
	}
	conn, err := lib.OpenConn(settings.SQLite.Path, flags)
	if err != nil {
		return nil, &adapter.ConnectionError{Category: "connection", Message: "The file could not be opened as a SQLite database."}
	}
	s := &Session{conn: conn, settings: settings, path: settings.SQLite.Path, identity: i, readOnly: ro, TransportBinding: adapter.TransportBinding{Transport: adapter.TransportFromContext(ctx)}}
	// SQLite's built-in busy handler sleeps without observing sqlite3_interrupt.
	// Keep its wait short so Stop remains responsive; callers retry explicitly.
	conn.SetBusyTimeout(100 * time.Millisecond)
	if err = s.exec(ctx, "PRAGMA foreign_keys=ON"); err == nil {
		err = s.exec(ctx, "PRAGMA trusted_schema=OFF")
	}
	if err == nil {
		_, _, err = s.query(ctx, "SELECT count(*) FROM sqlite_schema")
	}
	if err == nil {
		err = conn.SetAuthorizer(lib.AuthorizeFunc(s.authorize))
	}
	if err != nil {
		conn.Close()
		return nil, &adapter.ConnectionError{Category: "connection", Message: "The SQLite database could not be initialized."}
	}
	return s, nil
}

// Create is intentionally separate from Open and reserves its destination.
func Create(ctx context.Context, path string) error {
	if !filepath.IsAbs(path) || strings.ContainsRune(path, 0) {
		return errors.New("Choose a local destination for the SQLite database.")
	}
	if !localFilesystem(filepath.Dir(path)) {
		return errors.New("Choose a destination on a local filesystem.")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return errors.New("The SQLite destination exists or cannot be created.")
	}
	i, _ := f.Stat()
	f.Close()
	cleanup := func() {
		if current, e := os.Stat(path); e == nil && i != nil && os.SameFile(i, current) {
			_ = os.Remove(path)
		}
	}
	c, err := lib.OpenConn(path, lib.OpenReadWrite)
	if err != nil {
		cleanup()
		return errors.New("The SQLite database could not be created.")
	}
	s := &Session{conn: c, path: path, identity: i}
	err = s.exec(ctx, "PRAGMA user_version=0")
	closeErr := c.Close()
	if err != nil || closeErr != nil {
		cleanup()
		return errors.New("The SQLite database could not be initialized.")
	}
	return nil
}

func (s *Session) Close() {
	if !s.closed {
		s.closed = true
		_ = s.conn.Close()
		s.CloseTransport()
	}
}
func (s *Session) TransactionStatus() string {
	if s.closed {
		return "idle"
	}
	if s.conn.AutocommitEnabled() {
		return "idle"
	}
	return "transaction"
}
func (s *Session) SetReadOnly(ctx context.Context, readOnly bool) error {
	if s.TransactionStatus() != "idle" {
		return errors.New("Finish the transaction before changing readonly mode.")
	}
	if !readOnly && s.settings.Policy != nil && s.settings.Policy.ReadOnly {
		return errors.New("Reconnect to change the file access mode.")
	}
	s.readOnly = readOnly
	return nil
}
func (s *Session) checkIdentity() error {
	i, e := localFile(s.path)
	if e != nil || !os.SameFile(i, s.identity) {
		return errors.New("The SQLite file changed. Disconnect and explicitly reconnect before continuing.")
	}
	for path, original := range s.attachments {
		current, err := localFile(path)
		if err != nil || !os.SameFile(original, current) {
			return errors.New("An attached SQLite file changed. Disconnect and explicitly reconnect before continuing.")
		}
	}
	return nil
}

func (s *Session) refreshAttachments(ctx context.Context) error {
	rows, _, err := s.query(ctx, "PRAGMA database_list")
	if err != nil {
		return err
	}
	next := map[string]os.FileInfo{}
	for _, row := range rows {
		if len(row) < 3 || text(row[1]) == "main" || text(row[1]) == "temp" {
			continue
		}
		path := text(row[2])
		info, err := localFile(path)
		if err != nil {
			return err
		}
		if original, ok := s.attachments[path]; ok && !os.SameFile(original, info) {
			return errors.New("An attached SQLite file changed.")
		}
		if s.attachIdentity != nil && s.attachPath == path && !os.SameFile(s.attachIdentity, info) {
			return errors.New("The attached SQLite file changed while it was being opened.")
		}
		next[path] = info
	}
	s.attachments = next
	return nil
}

func (s *Session) authorize(a lib.Action) lib.AuthResult {
	if s.internal {
		return lib.AuthResultOK
	}
	switch a.Type() {
	case lib.OpFunction:
		// Extension loading remains disabled; no filesystem functions are registered.
	case lib.OpAttach:
		if s.allowVacuum && !s.readOnly && a.File() == "" {
			return lib.AuthResultOK
		}
		if a.File() != s.attachAllowed || s.attachAllowed == "" {
			return lib.AuthResultDeny
		}
		s.attachmentChanged = true
	case lib.OpDetach:
		s.attachmentChanged = true
	case lib.OpPragma:
		p := strings.ToLower(a.Pragma())
		if p == "writable_schema" || p == "trusted_schema" || p == "temp_store_directory" || p == "data_store_directory" || p == "query_only" {
			return lib.AuthResultDeny
		}
		if a.PragmaArg() != "" {
			// Metadata pragmas take arguments without changing the database.
			switch p {
			case "table_info", "table_xinfo", "index_info", "index_xinfo", "index_list", "foreign_key_list", "foreign_key_check", "integrity_check", "quick_check":
			default:
				if s.readOnly {
					return lib.AuthResultDeny
				}
			}
			if p == "journal_mode" && strings.EqualFold(a.PragmaArg(), "off") {
				return lib.AuthResultDeny
			}
		}
	}
	if s.readOnly {
		switch a.Type() {
		case lib.OpSelect, lib.OpRead, lib.OpFunction, lib.OpTransaction, lib.OpSavepoint, lib.OpRecursive, lib.OpPragma, lib.OpAttach, lib.OpDetach:
		default:
			return lib.AuthResultDeny
		}
	}
	return lib.AuthResultOK
}

var attachPattern = regexp.MustCompile(`(?is)^\s*ATTACH\s+(?:DATABASE\s+)?'((?:''|[^'])*)'\s+AS\s+([A-Za-z_][A-Za-z0-9_]*|"(?:""|[^"])+"|` + "`(?:``|[^`])+`" + `|\[(?:[^\]])+\])\s*;?(.*)$`)
var detachPattern = regexp.MustCompile(`(?is)^\s*DETACH\s+(?:DATABASE\s+)?([A-Za-z_][A-Za-z0-9_]*|"(?:""|[^"])+"|` + "`(?:``|[^`])+`" + `|\[(?:[^\]])+\])\s*;?(.*)$`)

func (s *Session) IsReadOnlyOperation(op protocol.OperationRequest) bool {
	if !s.readOnly || op.Type != "execute" || op.Parameters != nil {
		return false
	}
	sql := sqlStart(op.SQL)
	if m := attachPattern.FindStringSubmatch(sql); m != nil && emptyTail(m[3]) {
		path := strings.ReplaceAll(m[1], "''", "'")
		return filepath.IsAbs(path) && !strings.ContainsRune(path, 0)
	}
	if m := detachPattern.FindStringSubmatch(sql); m != nil && emptyTail(m[2]) {
		return true
	}
	return false
}

var vacuumPattern = regexp.MustCompile(`(?is)^VACUUM(?:\s+(?:main|"main"))?\s*;?\s*$`)

func (s *Session) prepareUserSQL(sql string) (string, error) {
	s.attachAllowed = ""
	s.attachmentChanged = false
	s.attachIdentity = nil
	s.attachPath = ""
	start := sqlStart(sql)
	s.allowVacuum = vacuumPattern.MatchString(start)
	if m := attachPattern.FindStringSubmatch(start); m != nil && emptyTail(m[3]) {
		p := strings.ReplaceAll(m[1], "''", "'")
		info, err := localFile(p)
		if err != nil {
			return "", err
		}
		s.attachIdentity = info
		s.attachPath = p
		mode := "mode=rw"
		if s.readOnly {
			mode = "mode=ro"
		}
		u := url.URL{Scheme: "file", Path: p, RawQuery: mode}
		s.attachAllowed = u.String()
		return "ATTACH DATABASE '" + strings.ReplaceAll(s.attachAllowed, "'", "''") + "' AS " + m[2], nil
	}
	return sql, nil
}

func (s *Session) Execute(ctx context.Context, c protocol.Command) protocol.Response {
	return s.ExecuteWithSink(ctx, c, nil)
}
func (s *Session) ExecuteWithSink(ctx context.Context, c protocol.Command, sink adapter.ResultSink) protocol.Response {
	if err := s.checkIdentity(); err != nil {
		return s.fail(c, ctx, err)
	}
	if c.Catalog != nil {
		return s.catalog(ctx, c, sink)
	}
	if c.Changes != nil {
		return s.changes(ctx, c)
	}
	if strings.HasPrefix(c.Type, "import.") {
		return s.tableImport(ctx, c)
	}
	return s.execute(ctx, c, sink)
}

// SQLiteFiles identifies every file currently accessible to this physical session.
func (s *Session) SQLiteFiles() []string {
	files := []string{s.path}
	for path := range s.attachments {
		files = append(files, path)
	}
	sort.Strings(files)
	return files
}
