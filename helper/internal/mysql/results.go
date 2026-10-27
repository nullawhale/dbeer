package mysql

import (
	"dbeer/helper/internal/protocol"
	"encoding/binary"
	"encoding/json"
	"errors"

	wire "github.com/go-mysql-org/go-mysql/mysql"
)

const maxResultSets = 1024
const maxResultColumns = 4096

func (session *Session) executeResults(sql string, parent *collector, target *wire.Result) (err error) {
	defer func() {
		if recover() != nil {
			err = wire.ErrMalformPacket
		}
	}()
	err = session.work.client.ExecuteSelectStreaming(sql, target, parent.row, parent.columns)
	if err != nil {
		return err
	}
	if target.Status&wire.SERVER_MORE_RESULTS_EXISTS == 0 {
		return nil
	}
	parent.needsStatusProbe = true
	remainingRows, remainingBytes := MaxResultRows, MaxResultBytes
	capture := func(current *collector, result *wire.Result) {
		response := current.finishSingle(result, 0, "")
		set := protocol.ResultSet{Columns: response.Columns, Rows: response.Rows, CommandTag: response.CommandTag, RowCount: response.RowCount, DisplayedRowCount: response.DisplayedRowCount, Truncated: response.Truncated, DisplayNotice: response.DisplayNotice, StorageTokens: response.StorageTokens, Source: response.Source}
		if set.Columns == nil {
			set.Columns = []protocol.Column{}
		}
		if set.Rows == nil {
			set.Rows = [][]*string{}
		}
		if len(parent.resultSets) < maxResultSets {
			parent.resultSets = append(parent.resultSets, set)
			encoded, _ := json.Marshal(set)
			remainingRows -= len(set.Rows)
			remainingBytes -= len(encoded)
		} else {
			parent.omittedResults = true
		}
	}
	capture(parent, target)
	status := target.Status
	index := 1
	for status&wire.SERVER_MORE_RESULTS_EXISTS != 0 {
		current := newCollector(protocol.Command{RequestID: parent.response.RequestID, SessionID: parent.response.SessionID, QueryID: parent.response.QueryID})
		current.maxRows, current.maxBytes = remainingRows, remainingBytes
		current.delivery, current.resultIndex = parent.delivery, index
		index++
		if len(parent.resultSets) >= maxResultSets {
			current.maxRows, current.maxBytes = 0, 0
		}
		next := wire.NewResult(nil)
		err = session.readNextResult(current, next)
		status = next.Status
		if err == nil {
			capture(current, next)
		}
		next.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

// Subsequent CALL results have no public streaming reader in go-mysql v1.16.
// Read them through its exported packet API, retaining one row at a time.
// DEPRECATE_EOF is disabled during handshake so EOF is exactly five bytes.
func (session *Session) readNextResult(collector *collector, target *wire.Result) (err error) {
	defer func() {
		if recover() != nil {
			err = wire.ErrMalformPacket
		}
	}()
	packet, err := session.work.client.ReadPacket()
	if err != nil {
		return err
	}
	if len(packet) == 0 {
		return wire.ErrMalformPacket
	}
	switch packet[0] {
	case wire.OK_HEADER:
		if !validOKPacket(packet) {
			return wire.ErrMalformPacket
		}
		loaded := session.work.client.HandleOKPacket(packet)
		if loaded == nil {
			return wire.ErrMalformPacket
		}
		target.Status, target.AffectedRows, target.InsertId, target.Warnings = loaded.Status, loaded.AffectedRows, loaded.InsertId, loaded.Warnings
		loaded.Close()
		return nil
	case wire.ERR_HEADER:
		if len(packet) < 9 {
			return wire.ErrMalformPacket
		}
		return session.work.client.HandleErrorPacket(packet)
	case wire.LocalInFile_HEADER:
		// LOCAL_FILES is never negotiated and no API opens server-named files.
		return errors.New("local file transfer is unsupported")
	}
	count, size, ok := lengthEncoded(packet)
	if !ok || size != len(packet) || count == 0 || count > maxResultColumns {
		return wire.ErrMalformPacket
	}
	fields := make([]*wire.Field, int(count))
	for index := range fields {
		data, err := session.work.client.ReadPacket()
		if err != nil {
			return err
		}
		if len(data) == 0 {
			return wire.ErrMalformPacket
		}
		if data[0] == wire.ERR_HEADER {
			if len(data) < 9 {
				return wire.ErrMalformPacket
			}
			return session.work.client.HandleErrorPacket(data)
		}
		field, err := wire.FieldData(data).Parse()
		if err != nil {
			return err
		}
		fields[index] = field
	}
	eof, err := session.work.client.ReadPacket()
	if err != nil {
		return err
	}
	if len(eof) != 5 || eof[0] != wire.EOF_HEADER {
		return wire.ErrMalformPacket
	}
	target.Resultset = wire.NewResultset(int(count))
	target.Fields = fields
	if err := collector.columns(target); err != nil {
		return err
	}
	var values []wire.FieldValue
	var data []byte
	for {
		data, err = session.work.client.ReadPacketReuseMem(data[:0])
		if err != nil {
			return err
		}
		if len(data) == 0 {
			return wire.ErrMalformPacket
		}
		if data[0] == wire.EOF_HEADER && len(data) == 5 {
			target.Warnings = binary.LittleEndian.Uint16(data[1:3])
			target.Status = binary.LittleEndian.Uint16(data[3:5])
			return nil
		}
		if data[0] == wire.ERR_HEADER {
			if len(data) < 9 {
				return wire.ErrMalformPacket
			}
			return session.work.client.HandleErrorPacket(data)
		}
		values, err = wire.RowData(data).Parse(fields, false, values)
		if err != nil {
			return err
		}
		if err := collector.row(values); err != nil {
			return err
		}
	}
}

func lengthEncoded(data []byte) (uint64, int, bool) {
	if len(data) == 0 {
		return 0, 0, false
	}
	size := 1
	switch data[0] {
	case 0xfb, 0xff:
		return 0, 0, false
	case 0xfc:
		size = 3
	case 0xfd:
		size = 4
	case 0xfe:
		size = 9
	}
	if len(data) < size {
		return 0, 0, false
	}
	value, _, read := wire.LengthEncodedInt(data)
	return value, read, true
}

func validOKPacket(data []byte) bool {
	if len(data) < 1 || data[0] != wire.OK_HEADER {
		return false
	}
	_, first, ok := lengthEncoded(data[1:])
	if !ok {
		return false
	}
	_, second, ok := lengthEncoded(data[1+first:])
	return ok && len(data) >= 1+first+second+4
}
