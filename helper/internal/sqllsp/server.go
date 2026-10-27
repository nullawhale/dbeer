// Package sqllsp implements the bundled, offline SQL language server. It only
// consumes editor text and a supplied catalog; it has no database dependencies.
package sqllsp

import (
	"bufio"
	"bytes"
	"dbeer/helper/internal/sqlcomplete"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"unicode/utf8"
)

const (
	maxDocumentBytes      = 2 << 20
	maxTotalDocumentBytes = 8 << 20
	maxDocuments          = 32
	maxCatalogEntries     = 2048
	maxCatalogColumns     = 32768
)

type position struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}
type textRange struct {
	Start position `json:"start"`
	End   position `json:"end"`
}
type diagnostic struct {
	Range    textRange `json:"range"`
	Severity int       `json:"severity"`
	Source   string    `json:"source"`
	Message  string    `json:"message"`
}
type document struct {
	text     string
	version  int
	language string
	invalid  bool
}
type catalogEntry = sqlcomplete.Relation
type configuration struct {
	Keyspace string         `json:"keyspace,omitempty"`
	URI      string         `json:"uri"`
	Engine   string         `json:"engine"`
	Catalog  []catalogEntry `json:"catalog"`
}
type server struct {
	transport   *transport
	documents   map[string]document
	contexts    map[string]configuration
	initialized bool
	shutdown    bool
}
type rpcMessage struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

// Run serves standard Content-Length framed JSON-RPC 2.0 until exit or EOF.
// Errors contain transport information only, never editor text or catalog data.
func Run(input io.Reader, output io.Writer) error {
	s := server{transport: &transport{reader: bufio.NewReaderSize(input, 16<<10), writer: output}, documents: make(map[string]document), contexts: make(map[string]configuration)}
	for {
		body, err := s.transport.read()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		var message rpcMessage
		if !json.Valid(body) {
			if err := s.failure(nil, -32700, "Parse error."); err != nil {
				return err
			}
			continue
		}
		if json.Unmarshal(body, &message) != nil || message.JSONRPC != "2.0" || message.Method == "" || !validID(message.ID) {
			if err := s.failure(nil, -32600, "Invalid request."); err != nil {
				return err
			}
			continue
		}
		if message.Method == "exit" {
			if !s.shutdown {
				return errors.New("Language server exited before shutdown.")
			}
			return nil
		}
		if done, err := s.handle(message); done || err != nil {
			return err
		}
	}
}

func validID(id json.RawMessage) bool {
	if len(id) == 0 {
		return true
	}
	id = bytes.TrimSpace(id)
	return len(id) > 0 && (id[0] == '"' || id[0] == '-' || id[0] >= '0' && id[0] <= '9')
}
func (s *server) response(id json.RawMessage, result any) error {
	return s.transport.write(struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Result  any             `json:"result"`
	}{"2.0", id, result})
}
func (s *server) failure(id json.RawMessage, code int, message string) error {
	if len(id) == 0 {
		id = json.RawMessage("null")
	}
	return s.transport.write(map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": message}})
}
func (s *server) handle(m rpcMessage) (bool, error) {
	request := len(m.ID) > 0
	if m.Method == "initialize" && request && !s.initialized && !s.shutdown {
		s.initialized = true
		return false, s.response(m.ID, map[string]any{"capabilities": map[string]any{"positionEncoding": "utf-16", "textDocumentSync": map[string]any{"openClose": true, "change": 1}, "completionProvider": map[string]any{"triggerCharacters": []string{".", "\"", "`"}}, "signatureHelpProvider": map[string]any{"triggerCharacters": []string{"(", ","}, "retriggerCharacters": []string{")"}}}, "serverInfo": map[string]string{"name": "DBeer SQL", "version": "1"}})
	}
	if !s.initialized || s.shutdown {
		if request {
			code := -32002
			if s.shutdown {
				code = -32600
			}
			return false, s.failure(m.ID, code, "Language server is not active.")
		}
		return false, nil
	}
	switch m.Method {
	case "initialized", "$/cancelRequest", "$/setTrace":
		return false, nil
	case "shutdown":
		if request {
			s.shutdown = true
			return false, s.response(m.ID, nil)
		}
	case "textDocument/didOpen":
		var params struct {
			TextDocument struct {
				URI        string `json:"uri"`
				LanguageID string `json:"languageId"`
				Version    int    `json:"version"`
				Text       string `json:"text"`
			} `json:"textDocument"`
		}
		if json.Unmarshal(m.Params, &params) == nil {
			d := params.TextDocument
			if old, exists := s.documents[d.URI]; !exists || d.Version > old.version {
				return false, s.updateDocument(d.URI, d.Text, d.Version, d.LanguageID)
			}
		}
	case "textDocument/didChange":
		var params struct {
			TextDocument struct {
				URI     string `json:"uri"`
				Version int    `json:"version"`
			} `json:"textDocument"`
			ContentChanges []struct {
				Range json.RawMessage `json:"range"`
				Text  string          `json:"text"`
			} `json:"contentChanges"`
		}
		if json.Unmarshal(m.Params, &params) == nil && len(params.ContentChanges) == 1 && len(params.ContentChanges[0].Range) == 0 {
			uri := params.TextDocument.URI
			if d, exists := s.documents[uri]; exists && params.TextDocument.Version > d.version {
				return false, s.updateDocument(uri, params.ContentChanges[0].Text, params.TextDocument.Version, d.language)
			}
		}
	case "textDocument/didClose":
		var params struct {
			TextDocument struct {
				URI string `json:"uri"`
			} `json:"textDocument"`
		}
		if json.Unmarshal(m.Params, &params) == nil {
			uri := params.TextDocument.URI
			if uri == "" || len(uri) > 4096 {
				return false, nil
			}
			delete(s.documents, uri)
			delete(s.contexts, uri)
			return false, s.transport.write(map[string]any{"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": map[string]any{"uri": uri, "diagnostics": []diagnostic{}}})
		}
	case "workspace/didChangeConfiguration":
		var params struct {
			Settings struct {
				DBeer configuration `json:"dbeer"`
			} `json:"settings"`
		}
		if json.Unmarshal(m.Params, &params) == nil {
			context := params.Settings.DBeer
			if boundedConfiguration(context) && (len(s.contexts) < maxDocuments || s.contexts[context.URI].URI != "") {
				s.contexts[context.URI] = context
				if _, exists := s.documents[context.URI]; exists {
					return false, s.publish(context.URI)
				}
			}
		}
	case "textDocument/completion", "textDocument/signatureHelp":
		if !request {
			break
		}
		var params struct {
			TextDocument struct {
				URI string `json:"uri"`
			} `json:"textDocument"`
			Position position `json:"position"`
		}
		if json.Unmarshal(m.Params, &params) != nil {
			return false, s.failure(m.ID, -32602, "Invalid completion parameters.")
		}
		if m.Method == "textDocument/signatureHelp" {
			var value *signatureResult
			if d, exists := s.documents[params.TextDocument.URI]; exists && !d.invalid {
				if offset, ok := offsetAt(d.text, params.Position); ok {
					value = signatureHelp(d.text, offset, s.context(d, params.TextDocument.URI))
				}
			}
			return false, s.response(m.ID, value)
		}
		items := []completionItem{}
		if d, exists := s.documents[params.TextDocument.URI]; exists && !d.invalid {
			context := s.context(d, params.TextDocument.URI)
			if offset, ok := offsetAt(d.text, params.Position); ok {
				items = complete(d.text, offset, context)
			}
		}
		return false, s.response(m.ID, map[string]any{"isIncomplete": false, "items": items})
	default:
		if request {
			return false, s.failure(m.ID, -32601, "Method not found.")
		}
	}
	return false, nil
}

func (s *server) updateDocument(uri, text string, version int, language string) error {
	if uri == "" || len(uri) > 4096 {
		return nil
	}
	if _, exists := s.documents[uri]; !exists && len(s.documents) >= maxDocuments {
		return nil
	}
	d := document{text: text, version: version, language: language}
	if !s.acceptDocument(uri, text) {
		// Retain the newest version, but discard the text. A bounded-out change
		// must never leave completions operating on an older document snapshot.
		d.text, d.invalid = "", true
	}
	s.documents[uri] = d
	return s.publish(uri)
}

func (s *server) acceptDocument(uri, text string) bool {
	if uri == "" || len(uri) > 4096 || len(text) > maxDocumentBytes || !utf8.ValidString(text) {
		return false
	}
	if _, exists := s.documents[uri]; !exists && len(s.documents) >= maxDocuments {
		return false
	}
	total := len(text)
	for existing, d := range s.documents {
		if existing != uri {
			total += len(d.text)
		}
	}
	return total <= maxTotalDocumentBytes
}
func boundedConfiguration(c configuration) bool {
	if len(c.Keyspace) > 1024 || strings.ContainsRune(c.Keyspace, 0) || c.URI == "" || len(c.URI) > 4096 || (c.Engine != "postgresql" && c.Engine != "mysql" && c.Engine != "cassandra" && c.Engine != "mongodb") || len(c.Catalog) > maxCatalogEntries {
		return false
	}
	columns, keyColumns, parameters := 0, 0, 0
	for _, entry := range c.Catalog {
		if (entry.Kind != "table" && entry.Kind != "view" && entry.Kind != "function" && entry.Kind != "type") || entry.Name == "" || len(entry.Name) > 1024 || len(entry.Schema) > 1024 {
			return false
		}
		for _, keys := range [][]string{entry.PartitionKeys, entry.ClusteringColumns, entry.StaticColumns} {
			if len(keys) > 4096 {
				return false
			}
			for _, key := range keys {
				if key == "" || len(key) > 1024 {
					return false
				}
			}
		}
		columns += len(entry.Columns) + len(entry.PartitionKeys) + len(entry.ClusteringColumns) + len(entry.StaticColumns)
		if columns > maxCatalogColumns {
			return false
		}
		for _, column := range entry.Columns {
			if len(column) > 1024 {
				return false
			}
		}
		if len(entry.ForeignKeys) > 64 {
			return false
		}
		for _, key := range entry.ForeignKeys {
			if len(key.Name) > 1024 || key.TargetTable == "" || len(key.TargetTable) > 1024 || len(key.TargetSchema) > 1024 || len(key.Columns) == 0 || len(key.Columns) > 32 {
				return false
			}
			keyColumns += len(key.Columns)
			if keyColumns > 8192 {
				return false
			}
			for _, pair := range key.Columns {
				if pair.Source == "" || pair.Target == "" || len(pair.Source) > 1024 || len(pair.Target) > 1024 {
					return false
				}
			}
		}
		if len(entry.Signatures) > 32 {
			return false
		}
		for _, signature := range entry.Signatures {
			if signature.ReturnType == "" || len(signature.ReturnType) > 4096 || len(signature.Parameters) > 256 {
				return false
			}
			parameters += len(signature.Parameters)
			if parameters > 8192 {
				return false
			}
			for _, parameter := range signature.Parameters {
				if len(parameter.Name) > 1024 || parameter.Type == "" || len(parameter.Type) > 1024 || parameter.Position < 0 || parameter.Position > 256 {
					return false
				}
			}
		}
	}
	return true
}
func (s *server) context(d document, uri string) configuration {
	c := s.contexts[uri]
	if c.Engine == "" {
		c.Engine = d.language
	}
	if c.Engine != "mysql" && c.Engine != "cassandra" && c.Engine != "mongodb" {
		c.Engine = "postgresql"
	}
	return c
}
func (s *server) publish(uri string) error {
	d := s.documents[uri]
	diagnostics := []diagnostic{}
	for _, value := range sqlcomplete.Diagnostics(d.text, s.context(d, uri).Engine) {
		diagnostics = append(diagnostics, diagnostic{Range: textRange{Start: positionAt(d.text, value.Start), End: positionAt(d.text, value.End)}, Severity: 1, Source: "DBeer SQL", Message: value.Message})
	}
	return s.transport.write(map[string]any{"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": map[string]any{"uri": uri, "version": d.version, "diagnostics": diagnostics}})
}

func positionAt(text string, offset int) position {
	p := position{}
	for i := 0; i < len(text) && i < offset; {
		r, size := utf8.DecodeRuneInString(text[i:])
		i += size
		if r == '\r' || r == '\n' {
			if r == '\r' && i < len(text) && text[i] == '\n' {
				i++
			}
			p.Line++
			p.Character = 0
		} else if r > 0xFFFF {
			p.Character += 2
		} else {
			p.Character++
		}
	}
	return p
}
func offsetAt(text string, p position) (int, bool) {
	if p.Line < 0 || p.Character < 0 {
		return 0, false
	}
	line, character := 0, 0
	for i := 0; i < len(text); {
		if line == p.Line && character == p.Character {
			return i, true
		}
		r, size := utf8.DecodeRuneInString(text[i:])
		i += size
		if r == '\r' || r == '\n' {
			if line == p.Line {
				return 0, false
			}
			if r == '\r' && i < len(text) && text[i] == '\n' {
				i++
			}
			line++
			character = 0
		} else {
			if r > 0xFFFF {
				character += 2
			} else {
				character++
			}
			if line == p.Line && character > p.Character {
				return 0, false
			}
		}
	}
	return len(text), line == p.Line && character == p.Character
}
