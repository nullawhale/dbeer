package mariadb

import (
	"dbeer/helper/internal/insertformat"
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/protocol"
)

func FormatInserts(request protocol.InsertFormatRequest) (string, error) {
	if request.Engine != "mariadb" || !request.Valid() {
		return "", insertformat.ErrInvalid
	}
	return mysql.FormatBacktickInserts(request)
}
