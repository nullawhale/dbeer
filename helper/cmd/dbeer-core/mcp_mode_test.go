package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestMCPModeRejectsMixedAndUnknownOptions(t *testing.T) {
	for _, args := range [][]string{{"--mcp", "--language-server"}, {"--mcp-extra"}, {"--mcp", "/arbitrary/socket"}} {
		var output bytes.Buffer
		if runCommand(args, strings.NewReader(""), &output, "", "", "") == nil || output.Len() != 0 {
			t.Fatal("MCP mode accepted extra arguments")
		}
	}
}
