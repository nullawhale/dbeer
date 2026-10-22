package comparisonjob

import (
	"context"
	"strings"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/resultartifact"
	"dbeer/helper/internal/resultcompare"
)

// OpenArtifacts only resolves opaque IDs inside the reader's trusted store.
func OpenArtifacts(store *resultartifact.Store) OpenSource {
	return func(ctx context.Context, ref protocol.ArtifactReference) (resultcompare.Source, error) {
		if ref.Kind != "snapshot" || !protocol.ValidArtifactID(ref.ID) {
			return nil, resultcompare.ErrReference
		}
		a, e := store.Open(ctx, strings.ToLower(ref.ID))
		if e != nil {
			return nil, e
		}
		return FromArtifact(a), nil
	}
}

// FromArtifact adapts a verified job-owned capture without exposing its path.
func FromArtifact(a resultartifact.Artifact) resultcompare.Source {
	metadata := a.Metadata()
	columns := make([]resultcompare.Column, len(metadata.Columns))
	for i, c := range metadata.Columns {
		columns[i] = resultcompare.Column{Index: c.Index, Name: c.Name, Engine: c.Engine, NativeType: c.NativeType, Encoding: c.Encoding}
	}
	return &artifactSource{artifact: a, metadata: resultcompare.Metadata{Columns: columns, RowCount: metadata.RowCount, Complete: metadata.Complete()}}
}

type artifactSource struct {
	artifact resultartifact.Artifact
	metadata resultcompare.Metadata
}

func (s *artifactSource) Metadata() resultcompare.Metadata { return s.metadata }
func toRef(ref resultartifact.RowRef) resultcompare.RowRef {
	return resultcompare.RowRef{Index: ref.Index, Offset: ref.Offset, Length: ref.Length, Digest: ref.Digest}
}
func (s *artifactSource) Scan(ctx context.Context, visit func(resultcompare.RowRef, []*string) error) error {
	return s.artifact.Scan(ctx, func(ref resultartifact.RowRef, row []*string) error { return visit(toRef(ref), row) })
}
func (s *artifactSource) ReadRow(ctx context.Context, ref resultcompare.RowRef) ([]*string, error) {
	return s.artifact.ReadRow(ctx, resultartifact.RowRef{Index: ref.Index, Offset: ref.Offset, Length: ref.Length, Digest: ref.Digest})
}
func (s *artifactSource) Close() error { return s.artifact.Close() }
