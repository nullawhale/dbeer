package adapter

import (
	"context"
	"net"
)

// Transport is a leased connection generation. Its lifetime encloses all work
// and auxiliary connections of one independently owned database session.
type Transport interface {
	DialContext(context.Context, string, string) (net.Conn, error)
	Close() error
	Done() <-chan struct{}
}

type transportKey struct{}

func WithTransport(ctx context.Context, transport Transport) context.Context {
	return context.WithValue(ctx, transportKey{}, transport)
}

func TransportFromContext(ctx context.Context) Transport {
	transport, _ := ctx.Value(transportKey{}).(Transport)
	return transport
}

// TransportBinding is embedded by concrete adapters, preserving every optional
// session interface while exposing transport failure to the exclusive owner.
type TransportBinding struct{ Transport Transport }

func (binding TransportBinding) TransportDone() <-chan struct{} {
	if binding.Transport == nil {
		return nil
	}
	return binding.Transport.Done()
}

func (binding TransportBinding) CloseTransport() {
	if binding.Transport != nil {
		_ = binding.Transport.Close()
	}
}
