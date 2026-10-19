package mysql

import "strings"

func unsupportedStatement(sql string) bool {
	var words []string
	for len(words) < 10 {
		sql = strings.TrimLeft(sql, " \t\r\n\f\v;")
		if strings.HasPrefix(sql, "--") || strings.HasPrefix(sql, "#") {
			end := strings.IndexAny(sql, "\r\n")
			if end < 0 {
				return false
			}
			sql = sql[end+1:]
			continue
		}
		if strings.HasPrefix(sql, "/*") {
			end := strings.Index(sql[2:], "*/")
			if end < 0 {
				return false
			}
			sql = sql[end+4:]
			continue
		}
		if len(sql) == 0 {
			break
		}
		if len(words) == 0 && sql[0] == '\\' {
			return true
		}
		end := 0
		for end < len(sql) && ((sql[end] >= 'A' && sql[end] <= 'Z') || (sql[end] >= 'a' && sql[end] <= 'z') || sql[end] == '_') {
			end++
		}
		if end == 0 {
			break
		}
		words = append(words, strings.ToUpper(sql[:end]))
		sql = sql[end:]
	}
	if len(words) == 0 {
		return false
	}
	switch words[0] {
	case "SOURCE", "DELIMITER", "TEE", "NOTEE", "PAGER", "NOPAGER", "SYSTEM", "COPY":
		return true
	}
	if words[0] == "LOAD" && len(words) > 1 && (words[1] == "DATA" || words[1] == "XML") {
		for _, word := range words[2:] {
			if word == "INFILE" {
				break
			}
			if word == "LOCAL" {
				return true
			}
		}
	}
	return false
}
