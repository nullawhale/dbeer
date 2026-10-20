package sqllsp

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

const maxFrameBytes = 4 << 20

type transport struct {
	reader *bufio.Reader
	writer io.Writer
}

func (t *transport) read() ([]byte, error) {
	length, headerBytes := -1, 0
	for {
		line, err := t.reader.ReadSlice('\n')
		if err != nil {
			if errors.Is(err, io.EOF) && headerBytes == 0 {
				return nil, io.EOF
			}
			return nil, errors.New("Invalid language server frame header.")
		}
		headerBytes += len(line)
		if headerBytes > 16<<10 {
			return nil, errors.New("Language server frame header exceeds its limit.")
		}
		value := strings.TrimSpace(string(line))
		if value == "" {
			break
		}
		name, value, found := strings.Cut(value, ":")
		if !found {
			return nil, errors.New("Invalid language server frame header.")
		}
		if strings.EqualFold(name, "Content-Length") {
			if length != -1 {
				return nil, errors.New("Duplicate language server content length.")
			}
			length, err = strconv.Atoi(strings.TrimSpace(value))
			if err != nil || length < 0 || length > maxFrameBytes {
				return nil, errors.New("Invalid language server content length.")
			}
		}
	}
	if length < 0 {
		return nil, errors.New("Missing language server content length.")
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(t.reader, body); err != nil {
		return nil, errors.New("Incomplete language server frame.")
	}
	return body, nil
}

func (t *transport) write(value any) error {
	body, err := json.Marshal(value)
	if err != nil {
		return errors.New("Unable to encode language server response.")
	}
	if len(body) > maxFrameBytes {
		return errors.New("Language server response exceeds its frame limit.")
	}
	if _, err = fmt.Fprintf(t.writer, "Content-Length: %d\r\n\r\n", len(body)); err != nil {
		return err
	}
	n, err := t.writer.Write(body)
	if err == nil && n != len(body) {
		return io.ErrShortWrite
	}
	return err
}
