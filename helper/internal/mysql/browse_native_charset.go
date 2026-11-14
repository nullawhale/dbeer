package mysql

import (
	"unicode/utf8"

	"golang.org/x/text/encoding/charmap"
)

// Character sets are authoritative target metadata. Only proven encodings are
// accepted for native text operands; no replacement characters are permitted.
func nativeBrowseTextCharset(kind, charset, value string) error {
	fail := func() error {
		return invalidSettings("The native filter text cannot be retained by the target character set.")
	}
	if !utf8.ValidString(value) {
		return fail()
	}
	switch kind {
	case "char", "varchar", "tinytext", "text", "mediumtext", "longtext", "enum", "set":
	default:
		return nil // Numeric, temporal and JSON inputs have their own encodings.
	}
	switch charset {
	case "utf8mb4", "utf16", "utf16le", "utf32":
		return nil
	case "utf8", "utf8mb3", "ucs2":
		for _, r := range value {
			if r > 0xffff {
				return fail()
			}
		}
		return nil
	case "ascii":
		for _, r := range value {
			if r > 127 {
				return fail()
			}
		}
		return nil
	case "latin1":
		// MySQL's latin1 mapping is Windows-1252, rather than ISO-8859-1.
		encoded, err := charmap.Windows1252.NewEncoder().String(value)
		if err != nil {
			return fail()
		}
		decoded, err := charmap.Windows1252.NewDecoder().String(encoded)
		if err != nil || decoded != value {
			return fail()
		}
		return nil
	default:
		return fail()
	}
}

const nativeBrowseEncodingMessage = "Native cell filters require UTF-8 (utf8mb4) client, connection, and result encodings. Restore the connection's UTF-8 encoding and retry."

// Prepared SQL identifiers, metadata names, and result text use independent
// server encodings. A binary operand alone cannot make those paths lossless.
func (session *Session) requireNativeMetadataEncoding() error {
	settings, err := session.work.client.Execute(`SELECT @@SESSION.character_set_client,@@SESSION.character_set_connection,@@SESSION.character_set_results`)
	if err != nil {
		return err
	}
	defer settings.Close()
	if settings.RowNumber() != 1 {
		return invalidSettings(nativeBrowseEncodingMessage)
	}
	for index := 0; index < 3; index++ {
		value, err := settings.GetString(0, index)
		if err != nil || value != "utf8mb4" {
			return invalidSettings(nativeBrowseEncodingMessage)
		}
	}
	return nil
}
