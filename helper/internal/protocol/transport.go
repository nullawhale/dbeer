package protocol

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"sync"
)

type Reader struct {
	input *bufio.Reader
}

func NewReader(input io.Reader) *Reader {
	return &Reader{input: bufio.NewReaderSize(input, 64*1024)}
}

func (reader *Reader) Read() (Command, error) {
	var frame []byte
	tooLarge := false
	for {
		part, err := reader.input.ReadSlice('\n')
		complete := len(part) > 0 && part[len(part)-1] == '\n'
		if complete {
			part = part[:len(part)-1]
		}
		if len(frame)+len(part) > MaxFrameBytes {
			tooLarge = true
			frame = nil
		}
		if !tooLarge {
			frame = append(frame, part...)
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if err != nil && !errors.Is(err, io.EOF) {
			return Command{}, errors.New("Cannot read protocol input.")
		}
		if tooLarge {
			return Command{}, &ProtocolError{Message: "Protocol message exceeds the size limit."}
		}
		if errors.Is(err, io.EOF) {
			if len(frame) == 0 {
				return Command{}, io.EOF
			}
			return Command{}, &ProtocolError{Message: "Protocol message is missing its newline terminator."}
		}
		return ParseCommand(frame)
	}
}

// Writer serializes whole frames, including their newline, across goroutines.
type Writer struct {
	mu     sync.Mutex
	output io.Writer
}

func NewWriter(output io.Writer) *Writer { return &Writer{output: output} }

func (writer *Writer) Write(response Response) error {
	frame, err := json.Marshal(response)
	if err != nil {
		return errors.New("Cannot encode protocol response.")
	}
	if len(frame) > MaxFrameBytes {
		return errors.New("Protocol response exceeds the size limit.")
	}
	frame = append(frame, '\n')
	writer.mu.Lock()
	defer writer.mu.Unlock()
	for len(frame) > 0 {
		count, err := writer.output.Write(frame)
		if err != nil {
			return errors.New("Cannot write protocol output.")
		}
		if count <= 0 || count > len(frame) {
			return io.ErrShortWrite
		}
		frame = frame[count:]
	}
	return nil
}
