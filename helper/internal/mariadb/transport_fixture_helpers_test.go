package mariadb

import "strings"

func dataQuoteIdentifier(name string) string { return "`" + strings.ReplaceAll(name, "`", "``") + "`" }
