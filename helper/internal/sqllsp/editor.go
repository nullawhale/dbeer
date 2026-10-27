package sqllsp

import (
	"dbeer/helper/internal/sqlcomplete"
	"encoding/json"
	"sort"
	"unicode/utf8"
)

func (s *server) editorRequest(m rpcMessage) error {
	var params struct {
		TextDocument struct {
			URI string `json:"uri"`
		} `json:"textDocument"`
		Position *position  `json:"position"`
		Range    *textRange `json:"range"`
		Options  struct {
			InsertSpaces bool   `json:"insertSpaces"`
			TabSize      int    `json:"tabSize"`
			KeywordCase  string `json:"keywordCase"`
		} `json:"options"`
	}
	if json.Unmarshal(m.Params, &params) != nil {
		return s.failure(m.ID, -32602, "Invalid editor tool parameters.")
	}
	d, ok := s.documents[params.TextDocument.URI]
	if !ok || d.invalid {
		return s.response(m.ID, nil)
	}
	context := s.context(d, params.TextDocument.URI)
	var positions func(int) position
	span := func(v sqlcomplete.EditorSpan) textRange { return textRange{positions(v.Start), positions(v.End)} }
	if m.Method == "dbeer/format" {
		start, end := 0, len(d.text)
		if params.Range != nil {
			var a, b bool
			start, a = offsetAt(d.text, params.Range.Start)
			end, b = offsetAt(d.text, params.Range.End)
			if !a || !b || end < start {
				return s.failure(m.ID, -32602, "Invalid formatting range.")
			}
		}
		if !sqlcomplete.SafeEditorRange(d.text, context.Engine, start, end) {
			return s.response(m.ID, map[string]any{"version": d.version, "edits": []textEdit{}, "error": "Select complete tokens, not part of a string, identifier or comment."})
		}
		formatted, err := sqlcomplete.FormatEditor(d.text[start:end], context.Engine, sqlcomplete.FormatOptions{InsertSpaces: params.Options.InsertSpaces, TabSize: params.Options.TabSize, KeywordCase: params.Options.KeywordCase})
		result := map[string]any{"version": d.version, "edits": []textEdit{}}
		if err != nil {
			result["error"] = err.Error()
		} else if formatted != d.text[start:end] {
			result["edits"] = []textEdit{{Range: textRange{positionAt(d.text, start), positionAt(d.text, end)}, NewText: formatted}}
		}
		return s.editorResponse(m.ID, result)
	}
	offset := 0
	if params.Position != nil {
		var valid bool
		offset, valid = offsetAt(d.text, *params.Position)
		if !valid {
			return s.failure(m.ID, -32602, "Invalid editor position.")
		}
	}
	analysis := sqlcomplete.AnalyzeEditor(d.text, offset, sqlcomplete.Context{Engine: context.Engine, Keyspace: context.Keyspace, Catalog: context.Catalog})
	positions = editorPositionIndex(d.text, analysis)
	symbols := []any{}
	folds := []textRange{}
	refs := []textRange{}
	defs := []any{}
	for _, v := range analysis.Symbols {
		symbols = append(symbols, map[string]any{"name": v.Name, "kind": v.Kind, "range": span(v.Range), "selectionRange": span(v.Selection)})
	}
	for _, v := range analysis.Folds[:min(len(analysis.Folds), 4096)] {
		folds = append(folds, span(v))
	}
	for _, v := range analysis.References[:min(len(analysis.References), 4096)] {
		refs = append(refs, span(v))
	}
	for _, v := range analysis.Definitions[:min(len(analysis.Definitions), 128)] {
		if len(v.Detail) > 4096 {
			v.Detail = string([]rune(v.Detail)[:min(len([]rune(v.Detail)), 1000)])
		}
		value := map[string]any{"name": v.Name, "kind": v.Kind, "schema": v.Schema, "detail": v.Detail}
		if v.Range != nil {
			value["range"] = span(*v.Range)
		}
		defs = append(defs, value)
	}
	return s.editorResponse(m.ID, map[string]any{"version": d.version, "symbols": symbols, "folds": folds, "references": refs, "definitions": defs})
}

// Convert all output boundaries in one source pass; thousands of references in
// a single long line must not turn analysis into quadratic rescanning.
func editorPositionIndex(text string, a sqlcomplete.EditorAnalysis) func(int) position {
	targets := []int{0, len(text)}
	add := func(v sqlcomplete.EditorSpan) { targets = append(targets, v.Start, v.End) }
	for _, v := range a.Symbols {
		add(v.Range)
		add(v.Selection)
	}
	for _, v := range a.Folds {
		add(v)
	}
	for _, v := range a.References {
		add(v)
	}
	for _, v := range a.Definitions {
		if v.Range != nil {
			add(*v.Range)
		}
	}
	sort.Ints(targets)
	values := make(map[int]position, len(targets))
	i := 0
	p := position{}
	for _, target := range targets {
		for i < target && i < len(text) {
			r, n := utf8.DecodeRuneInString(text[i:])
			i += n
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
		values[target] = p
	}
	return func(offset int) position { return values[offset] }
}

func (s *server) editorResponse(id json.RawMessage, result map[string]any) error {
	encoded, err := json.Marshal(result)
	if err != nil {
		return err
	}
	if len(encoded)+len(id)+128 > maxFrameBytes {
		if _, formatting := result["edits"]; formatting {
			return s.response(id, map[string]any{"version": result["version"], "edits": []textEdit{}, "error": "Formatted output exceeds the language response limit."})
		}
		return s.response(id, map[string]any{"version": result["version"], "symbols": []any{}, "folds": []any{}, "references": []any{}, "definitions": []any{}})
	}
	return s.response(id, result)
}
