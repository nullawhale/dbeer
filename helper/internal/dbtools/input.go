package dbtools

import (
	"bufio"
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var dumpRestriction = regexp.MustCompile(`^\\(?:unrestrict|restrict)[ \t]+[A-Za-z0-9]+[ \t]*$`)

// freezeInput takes an immutable private copy during preview. A later rename,
// symlink retarget or in-place edit of the selected input cannot change the
// approved restore. Plain dumps are wrapped in a fresh restricted psql session.
func freezeInput(ctx context.Context, path, dir string, plainPostgres bool) (string, error) {
	source, before, err := openReadonlyRegular(path)
	if err != nil {
		return "", safe("The selected restore file is unavailable.")
	}
	defer source.Close()
	if before.Size() == 0 {
		return "", safe("The selected restore file is empty.")
	}
	destination := filepath.Join(dir, "restore-input")
	out, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return "", err
	}
	defer out.Close()
	if plainPostgres {
		key, err := token()
		if err != nil {
			return "", err
		}
		if _, err = io.WriteString(out, "\\restrict "+key+"\n"); err != nil {
			return "", err
		}
		err = sanitizePostgresDump(ctx, source, out)
		if err != nil {
			return "", err
		}
	} else {
		_, err = io.Copy(out, contextReader{ctx: ctx, in: source})
		if err != nil {
			return "", err
		}
	}
	after, err := source.Stat()
	named, nameErr := os.Stat(path)
	if err != nil || nameErr != nil || !os.SameFile(before, after) || !os.SameFile(after, named) || before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
		return "", safe("The restore file changed while preparing it. Preview the file again.")
	}
	if out.Sync() != nil || out.Close() != nil || os.Chmod(destination, 0400) != nil {
		return "", safe("The private restore input could not be prepared.")
	}
	return destination, nil
}

type contextReader struct {
	ctx context.Context
	in  io.Reader
}

func (r contextReader) Read(data []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.in.Read(data)
}

type dumpLexer struct {
	quote                              byte
	escaped, escapeString, lineComment bool
	commentDepth                       int
	previous                           byte
	dollar, dollarCandidate            string
	dollarMatch                        int
	word                               []byte
	wordLong                           bool
	first, previousWord                string
	fromStdin, copyData                bool
	copyPrefix                         []byte
	copyLong                           bool
}

func (l *dumpLexer) normal() bool {
	return l.quote == 0 && l.commentDepth == 0 && l.dollar == "" && l.dollarCandidate == "" && !l.lineComment && !l.copyData
}
func (l *dumpLexer) flushWord() {
	if len(l.word) == 0 && !l.wordLong {
		return
	}
	word := strings.ToUpper(string(l.word))
	if l.wordLong {
		word = ""
	}
	if l.first == "" {
		l.first = word
	}
	if l.previousWord == "FROM" && word == "STDIN" {
		l.fromStdin = true
	}
	l.previousWord = word
	l.word = nil
	l.wordLong = false
}
func asciiWord(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '_'
}
func (l *dumpLexer) scan(data []byte) error {
	for index := 0; index < len(data); index++ {
		b := data[index]
		if b == 0 {
			return safe("Plain SQL restore does not support binary input. Choose the archive format that matches the file.")
		}
		if l.lineComment {
			if b == '\n' {
				l.lineComment = false
				l.previous = 0
			}
			continue
		}
		if l.commentDepth > 0 {
			if l.previous == '/' && b == '*' {
				l.commentDepth++
				l.previous = 0
			} else if l.previous == '*' && b == '/' {
				l.commentDepth--
				l.previous = 0
			} else {
				l.previous = b
			}
			continue
		}
		if l.dollar != "" {
			if b == l.dollar[l.dollarMatch] {
				l.dollarMatch++
			} else if b == '$' {
				l.dollarMatch = 1
			} else {
				l.dollarMatch = 0
			}
			if l.dollarMatch == len(l.dollar) {
				l.dollar = ""
				l.dollarMatch = 0
			}
			continue
		}
		if l.quote != 0 {
			if l.escaped {
				l.escaped = false
				continue
			}
			if l.quote == '\'' && l.escapeString && b == '\\' {
				l.escaped = true
				continue
			}
			if b == l.quote {
				l.quote = 0
			}
			continue
		}
		if l.dollarCandidate != "" {
			if b == '$' {
				l.dollar = l.dollarCandidate + "$"
				l.dollarCandidate = ""
				continue
			}
			if asciiWord(b) && len(l.dollarCandidate) < 4096 {
				l.dollarCandidate += string(b)
				continue
			}
			l.dollarCandidate = ""
		}
		if l.previous == '-' && b == '-' {
			l.flushWord()
			l.lineComment = true
			l.previous = 0
			continue
		}
		if l.previous == '/' && b == '*' {
			l.flushWord()
			l.commentDepth = 1
			l.previous = 0
			continue
		}
		if b == '\\' {
			return safe("The SQL file contains local psql commands. Restore a pg_dump SQL file without custom client commands.")
		}
		if b == '\'' || b == '"' {
			l.escapeString = string(l.word) == "E" || string(l.word) == "e"
			l.flushWord()
			l.quote = b
			l.previous = 0
			continue
		}
		if b == '$' && len(l.word) == 0 && !l.wordLong {
			l.dollarCandidate = "$"
			l.previous = 0
			continue
		}
		if asciiWord(b) || b == '$' {
			if len(l.word) < 64 {
				l.word = append(l.word, b)
			} else {
				l.wordLong = true
			}
			l.previous = b
			continue
		}
		l.flushWord()
		if b == ';' {
			l.copyData = l.first == "COPY" && l.fromStdin
			l.first, l.previousWord = "", ""
			l.fromStdin = false
			if l.copyData {
				if len(bytes.TrimSpace(data[index+1:])) != 0 {
					return safe("Unsupported COPY input layout in the SQL file.")
				}
				l.previous = 0
				return nil
			}
		}
		l.previous = b
	}
	return nil
}
func (l *dumpLexer) copy(data []byte) {
	for _, b := range data {
		if !l.copyLong {
			if len(l.copyPrefix) < 4 {
				l.copyPrefix = append(l.copyPrefix, b)
			} else {
				l.copyLong = true
			}
		}
		if b == '\n' {
			if !l.copyLong && (bytes.Equal(l.copyPrefix, []byte("\\.\n")) || bytes.Equal(l.copyPrefix, []byte("\\.\r\n"))) {
				l.copyData = false
			}
			l.copyPrefix = nil
			l.copyLong = false
		}
	}
}
func sanitizePostgresDump(ctx context.Context, in io.Reader, out io.Writer) error {
	reader := bufio.NewReaderSize(in, 64*1024)
	lexer := dumpLexer{}
	lineStart := true
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		data, err := reader.ReadSlice('\n')
		if len(data) > 0 {
			if lexer.copyData {
				lexer.copy(data)
			} else if lineStart && lexer.normal() && dumpRestriction.Match(bytes.TrimSpace(data)) {
				// Modern pg_dump wrappers are replaced, not trusted: an input's
				// public key cannot unlock the private restricted client session.
				lineStart = err != bufio.ErrBufferFull
				if err == io.EOF {
					break
				}
				if err != nil && err != bufio.ErrBufferFull {
					return err
				}
				continue
			} else if e := lexer.scan(data); e != nil {
				return e
			}
			if _, e := out.Write(data); e != nil {
				return e
			}
			lineStart = err != bufio.ErrBufferFull
		}
		if err == io.EOF {
			break
		}
		if err != nil && err != bufio.ErrBufferFull {
			return err
		}
	}
	if lexer.copyData || lexer.quote != 0 || lexer.commentDepth != 0 || lexer.dollar != "" {
		return safe("The SQL file has incomplete COPY data, a quoted value or a comment.")
	}
	_, err := io.WriteString(out, "\n")
	return err
}
