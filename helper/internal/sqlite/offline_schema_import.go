package sqlite

import (
	"context"
	"errors"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
	lib "zombiezen.com/go/sqlite"
)

// ImportDefinitions builds schema facts in a new, private in-memory database.
// Only CREATE TABLE/INDEX/TRIGGER statements are admitted. It has no attached
// databases, extension functions, rows or filesystem-backed main database.
// This is validation, never execution against the user's source or target.
func ImportDefinitions(ctx context.Context, definitions []string, limits sc.Limits) (sc.Capture, error) {
	var empty sc.Capture
	if len(definitions) > limits.Members {
		return empty, sc.ErrLimit
	}
	conn, err := lib.OpenConn(":memory:", lib.OpenReadWrite|lib.OpenCreate|lib.OpenMemory)
	if err != nil {
		return empty, sc.ErrInvalid
	}
	defer conn.Close()
	for category, value := range map[lib.Limit]int32{lib.LimitLength: 1 << 20, lib.LimitSQLLength: 128 << 10, lib.LimitColumn: 1600, lib.LimitExprDepth: 128, lib.LimitAttached: 0, lib.LimitTriggerDepth: 64, lib.LimitVDBEOp: 1_000_000, lib.LimitWorkerThreads: 0} {
		conn.Limit(category, value)
	}
	old := conn.SetInterrupt(ctx.Done())
	defer conn.SetInterrupt(old)
	s := &Session{conn: conn}
	if err = s.exec(ctx, "PRAGMA temp_store=MEMORY"); err == nil {
		err = s.exec(ctx, "PRAGMA trusted_schema=OFF")
	}
	if err == nil {
		err = s.exec(ctx, "PRAGMA foreign_keys=OFF")
	}
	if err != nil {
		return empty, sc.ErrInvalid
	}
	var denied lib.OpType
	if err = conn.SetAuthorizer(lib.AuthorizeFunc(func(a lib.Action) lib.AuthResult {
		if a.Database() != "" && a.Database() != "main" {
			denied = a.Type()
			return lib.AuthResultDeny
		}
		switch a.Type() {
		case lib.OpCreateTable, lib.OpCreateIndex, lib.OpCreateTrigger, lib.OpRead, lib.OpSelect, lib.OpRecursive, lib.OpReindex:
			return lib.AuthResultOK
		case lib.OpInsert, lib.OpUpdate, lib.OpDelete:
			if a.Table() == "sqlite_master" || a.Table() == "sqlite_schema" {
				return lib.AuthResultOK
			}
			denied = a.Type()
			return lib.AuthResultDeny
		case lib.OpFunction:
			// This fresh driver connection does not enable extension loading or
			// register filesystem functions. CREATE INDEX sees only empty tables.
			return lib.AuthResultOK
		default:
			denied = a.Type()
			return lib.AuthResultDeny
		}
	})); err != nil {
		return empty, sc.ErrInvalid
	}
	total := 0
	for _, definition := range definitions {
		total += len(definition)
		if total > limits.Bytes {
			return empty, sc.ErrLimit
		}
		for strings.TrimSpace(definition) != "" {
			if err = ctx.Err(); err != nil {
				return empty, err
			}
			// Inspect the top-level verb before preparing it. The authorizer
			// additionally prevents a prepared definition from escaping main.
			ts, e := ddlScan(definition)
			if e != nil {
				return empty, sc.ErrInvalid
			}
			if len(ts) == 0 {
				break
			}
			if ts[0].word != "CREATE" || ts[0].quoted || len(ts) < 3 {
				return empty, sc.ErrInvalid
			}
			i := 1
			if ts[i].word == "UNIQUE" {
				i++
			}
			if i >= len(ts) || ts[i].quoted || (ts[i].word != "TABLE" && ts[i].word != "INDEX" && ts[i].word != "TRIGGER") {
				return empty, sc.ErrInvalid
			}
			stmt, tail, e := conn.PrepareTransient(definition)
			if e != nil {
				return empty, errors.New("Offline schema preparation failed: " + denied.String())
			}
			if stmt == nil {
				break
			}
			consumed := len(definition) - tail
			if consumed <= 0 {
				stmt.Finalize()
				return empty, sc.ErrInvalid
			}
			if ts[i].word == "TABLE" && !importedTableSyntax(definition[:consumed]) {
				stmt.Finalize()
				return empty, sc.ErrInvalid
			}
			if stmt.ColumnCount() != 0 || stmt.BindParamCount() != 0 {
				stmt.Finalize()
				return empty, sc.ErrInvalid
			}
			_, e = stmt.Step()
			finalizeErr := stmt.Finalize()
			if e != nil || finalizeErr != nil {
				return empty, sc.ErrInvalid
			}
			definition = definition[consumed:]
		}
	}
	// No imported statement is prepared or stepped after this point. Metadata
	// compilation uses the same bounded dependency proof as a live capture.
	s.readOnly = true
	if err = conn.SetAuthorizer(lib.AuthorizeFunc(s.authorize)); err != nil {
		return empty, sc.ErrInvalid
	}
	collector := sc.NewCollector(ctx, limits)
	if err = s.ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{"main"}, Limits: limits}, collector); err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return empty, err
		}
		return empty, sc.ErrInvalid
	}
	return collector.Capture, nil
}

func importedTableSyntax(sql string) bool {
	ts, err := ddlScan(sql)
	if err != nil || len(ts) < 4 || ts[0].word != "CREATE" || ts[1].word != "TABLE" {
		return false
	}
	i := 2
	if ts[i].word == "IF" {
		if len(ts) < 7 || ts[i+1].word != "NOT" || ts[i+2].word != "EXISTS" {
			return false
		}
		i += 3
	}
	first, ok := ddlName(sql, ts[i])
	if !ok {
		return false
	}
	i++
	if i < len(ts) && sql[ts[i].start:ts[i].end] == "." {
		if ddlFold(first) != "MAIN" || i+1 >= len(ts) {
			return false
		}
		if _, ok = ddlName(sql, ts[i+1]); !ok {
			return false
		}
		i += 2
	}
	if i >= len(ts) || !ts[i].group {
		return false
	}
	_, err = parseDDLTable(sql)
	return err == nil
}
