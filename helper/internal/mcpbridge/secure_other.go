//go:build !darwin && !linux

package mcpbridge

import (
	"context"
	"net"
)

func dialBroker(context.Context) (net.Conn, error) { return nil, errUnavailable }
