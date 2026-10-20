package sqllsp

import (
	"dbeer/helper/internal/sqlcomplete"
	"unicode/utf16"
)

type signatureParameter struct {
	Label [2]int `json:"label"`
}
type signatureInformation struct {
	Label           string               `json:"label"`
	Parameters      []signatureParameter `json:"parameters"`
	ActiveParameter *int                 `json:"activeParameter,omitempty"`
}
type signatureResult struct {
	Signatures      []signatureInformation `json:"signatures"`
	ActiveSignature int                    `json:"activeSignature"`
	ActiveParameter *int                   `json:"activeParameter,omitempty"`
}

func signatureHelp(text string, offset int, context configuration) *signatureResult {
	help := sqlcomplete.Signatures(text, offset, sqlcomplete.Context{Engine: context.Engine, Catalog: context.Catalog, Keyspace: context.Keyspace})
	if help == nil {
		return nil
	}
	result := &signatureResult{ActiveSignature: help.ActiveSignature, Signatures: []signatureInformation{}}
	for _, value := range help.Signatures {
		item := signatureInformation{Label: value.Label, Parameters: []signatureParameter{}}
		if value.ActiveParameter >= 0 {
			active := value.ActiveParameter
			item.ActiveParameter = &active
		}
		for _, span := range value.Parameters {
			item.Parameters = append(item.Parameters, signatureParameter{Label: [2]int{len(utf16.Encode([]rune(value.Label[:span.Start]))), len(utf16.Encode([]rune(value.Label[:span.End])))}})
		}
		result.Signatures = append(result.Signatures, item)
	}
	result.ActiveParameter = result.Signatures[result.ActiveSignature].ActiveParameter
	return result
}
