package sqllsp

import (
	"dbeer/helper/internal/sqlcomplete"
	"unicode/utf16"
)

type textEdit struct {
	Range   textRange `json:"range"`
	NewText string    `json:"newText"`
}
type completionItem struct {
	Label      string          `json:"label"`
	InsertText string          `json:"insertText"`
	Kind       int             `json:"kind"`
	Detail     string          `json:"detail"`
	TextEdit   textEdit        `json:"textEdit"`
	Data       *completionData `json:"data,omitempty"`
}

// Private LSP data: half-open UTF-16 offsets within label, not the document.
type completionData struct {
	MatchRanges [][2]int `json:"dbeerMatchRanges"`
}

func complete(text string, offset int, context configuration) []completionItem {
	values := sqlcomplete.Complete(text, offset, sqlcomplete.Context{Engine: context.Engine, Catalog: context.Catalog})
	items := make([]completionItem, 0, len(values))
	for _, value := range values {
		item := completionItem{Label: value.Label, InsertText: value.InsertText, Kind: value.Kind, Detail: value.Detail,
			TextEdit: textEdit{Range: textRange{Start: positionAt(text, value.Start), End: positionAt(text, value.End)}, NewText: value.InsertText}}
		if len(value.Matches) > 0 {
			item.Data = &completionData{}
			for _, span := range value.Matches {
				item.Data.MatchRanges = append(item.Data.MatchRanges, [2]int{
					len(utf16.Encode([]rune(value.Label[:span.Start]))),
					len(utf16.Encode([]rune(value.Label[:span.End]))),
				})
			}
		}
		items = append(items, item)
	}
	return items
}
