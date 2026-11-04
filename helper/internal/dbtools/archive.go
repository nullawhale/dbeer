package dbtools

import (
	"context"
	"regexp"
	"strconv"
	"strings"
)

type prefixOutput struct {
	bytes []byte
	limit int
}

func (p *prefixOutput) Write(data []byte) (int, error) {
	n := len(data)
	if len(p.bytes) < p.limit {
		count := min(len(data), p.limit-len(p.bytes))
		p.bytes = append(p.bytes, data[:count]...)
	}
	return n, nil
}

var archiveSourceVersion = regexp.MustCompile(`(?m)^;[ \t]*Dumped from database version: ([0-9]+)(?:\.[0-9]+)*`)

// Listing validates utility/archive compatibility before a restore is approved.
// Only fixed header metadata is inspected; object names and SQL are discarded.
func verifyArchive(ctx context.Context, p *plan, serverVersion string) error {
	input, _, err := openReadonlyRegular(p.input)
	if err != nil {
		return err
	}
	defer input.Close()
	var magic [5]byte
	n, _ := input.Read(magic[:])
	if p.request.Format == "custom" && (n != 5 || string(magic[:]) != "PGDMP") {
		return safe("The selected file is not a PostgreSQL custom-format archive.")
	}
	if p.request.Format == "tar" && n == 5 && string(magic[:]) == "PGDMP" {
		return safe("The selected file is a custom archive. Choose the matching format and preview again.")
	}
	out := &prefixOutput{limit: 16 * 1024}
	code, err := process(ctx, p.tool.path, []string{"--list", p.input}, baseEnvironment(p.dir), nil, out)
	if err != nil || code != 0 {
		return safe("The selected archive is damaged or incompatible with this pg_restore version.")
	}
	format := "CUSTOM"
	if p.request.Format == "tar" {
		format = "TAR"
	}
	if !strings.Contains(string(out.bytes), "Format: "+format) {
		return safe("The selected archive format could not be verified. Choose the matching format.")
	}
	match := archiveSourceVersion.FindStringSubmatch(string(out.bytes))
	if len(match) == 2 {
		source, _ := strconv.Atoi(match[1])
		target, _, _ := serverMajor(serverVersion)
		if source > target {
			return safe("The archive was created from a newer PostgreSQL server. Restore into a compatible server.")
		}
	}
	return nil
}
