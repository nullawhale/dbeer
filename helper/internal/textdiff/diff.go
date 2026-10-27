// Package textdiff prepares bounded, platform-independent visual text differences.
// Tokenization, token LCS, and changed-range merging are adapted from
// github.com/umputun/revdiff/app/ui/worddiff (MIT; see LICENSE.revdiff).
// Source reviewed: master/app/ui/worddiff/worddiff.go, retrieved 2026-10-23.
package textdiff

import (
	"context"
	"encoding/json"
	"regexp"
	"strings"
	"unicode/utf8"
)

// Limits cover the entire request, rather than each changed line independently.
const MaxTextBytes = 128 << 10
const maxLines = 2000
const maxWork = 2_000_000
const maxOutputBytes = 512 << 10

type Side struct {
	Kind       string `json:"kind"`
	TotalBytes int64  `json:"totalBytes"`
}
type Range struct {
	Start int `json:"start"`
	End   int `json:"end"`
}
type Line struct {
	Number     int     `json:"number"`
	Text       string  `json:"text"`
	Highlights []Range `json:"highlights"`
}
type Pair struct {
	Kind   string `json:"kind"`
	Source *Line  `json:"source,omitempty"`
	Target *Line  `json:"target,omitempty"`
}
type Diff struct {
	FormatVersion int    `json:"formatVersion"`
	Status        string `json:"status"`
	Source        Side   `json:"source"`
	Target        Side   `json:"target"`
	Lines         []Pair `json:"lines"`
}

// Input retains semantic states separately from text. TotalBytes records the
// original size if a caller has already bounded a large captured value.
type Input struct {
	Kind       string
	Text       string
	TotalBytes int64
	Limited    bool
}

func Text(s string) Input { return Input{Kind: "text", Text: s, TotalBytes: int64(len(s))} }
func trim(s string, limit int) string {
	if len(s) <= limit {
		return s
	}
	end := limit
	for end > 0 && !utf8.RuneStart(s[end]) {
		end--
	}
	return s[:end]
}
func lines(v Input) []string {
	if v.Kind != "text" {
		return nil
	}
	// Retain the terminal empty line: adding a final newline is a real change.
	return strings.Split(v.Text, "\n")
}
func full(number int, s string, changed bool) *Line {
	l := &Line{Number: number, Text: s, Highlights: []Range{}}
	if changed && len(s) > 0 {
		l.Highlights = append(l.Highlights, Range{0, len(s)})
	}
	return l
}

// Compare returns exact line alignment and UTF-8 byte highlight ranges. A limited
// result explicitly signals truncation or coarse highlighting; it never claims
// equality when its computation or representation budget is exhausted.
func Compare(ctx context.Context, source, target Input) (Diff, error) {
	d := Diff{FormatVersion: 1, Status: "complete", Source: Side{source.Kind, source.TotalBytes}, Target: Side{target.Kind, target.TotalBytes}, Lines: []Pair{}}
	if err := ctx.Err(); err != nil {
		return d, err
	}
	if source.Kind == "binary" || target.Kind == "binary" {
		d.Status = "binary"
		return d, nil
	}
	if !utf8.ValidString(source.Text) || !utf8.ValidString(target.Text) {
		d.Status = "binary"
		if !utf8.ValidString(source.Text) {
			d.Source.Kind = "binary"
		}
		if !utf8.ValidString(target.Text) {
			d.Target.Kind = "binary"
		}
		return d, nil
	}
	if source.Limited || target.Limited || len(source.Text) > MaxTextBytes || len(target.Text) > MaxTextBytes {
		return limited(ctx, d, source, target)
	}
	a, b := lines(source), lines(target)
	if len(a) > maxLines || len(b) > maxLines {
		return limited(ctx, d, source, target)
	}
	budget := maxWork
	keptA, keptB, ok, err := lcs(ctx, a, b, &budget)
	if err != nil {
		return d, err
	}
	if !ok {
		return limited(ctx, d, source, target)
	}
	appendBlock := func(i, j, endA, endB int) error {
		for i < endA || j < endB {
			p := Pair{}
			if i < endA {
				p.Source = full(i+1, a[i], true)
				i++
			}
			if j < endB {
				p.Target = full(j+1, b[j], true)
				j++
			}
			switch {
			case p.Source == nil:
				p.Kind = "targetOnly"
			case p.Target == nil:
				p.Kind = "sourceOnly"
			default:
				p.Kind = "changed"
				ra, rb, exact, e := intra(ctx, p.Source.Text, p.Target.Text, &budget)
				if e != nil {
					return e
				}
				if exact {
					p.Source.Highlights = ra
					p.Target.Highlights = rb
				} else {
					d.Status = "limited"
				}
			}
			d.Lines = append(d.Lines, p)
		}
		return nil
	}
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		if err := ctx.Err(); err != nil {
			return d, err
		}
		endA, endB := i, j
		for endA < len(a) && !keptA[endA] {
			endA++
		}
		for endB < len(b) && !keptB[endB] {
			endB++
		}
		if err := appendBlock(i, j, endA, endB); err != nil {
			return d, err
		}
		i, j = endA, endB
		if i < len(a) && j < len(b) {
			d.Lines = append(d.Lines, Pair{Kind: "equal", Source: full(i+1, a[i], false), Target: full(j+1, b[j], false)})
			i++
			j++
		}
	}
	encoded, _ := json.Marshal(d)
	if len(encoded) > maxOutputBytes {
		return limited(ctx, d, source, target)
	}
	return d, nil
}

func limited(ctx context.Context, d Diff, a, b Input) (Diff, error) {
	d.Status = "limited"
	d.Lines = []Pair{}
	// This fallback stays below the wire budget even with JSON escaping and
	// many empty lines. Full originals remain available through value reads.
	a.Text = trim(a.Text, 16<<10)
	b.Text = trim(b.Text, 16<<10)
	as, bs := lines(a), lines(b)
	for i := 0; i < min(max(len(as), len(bs)), 256); i++ {
		if err := ctx.Err(); err != nil {
			return d, err
		}
		p := Pair{Kind: "changed"}
		if i < len(as) {
			p.Source = full(i+1, as[i], true)
		}
		if i < len(bs) {
			p.Target = full(i+1, bs[i], true)
		}
		if p.Source == nil {
			p.Kind = "targetOnly"
		} else if p.Target == nil {
			p.Kind = "sourceOnly"
		}
		d.Lines = append(d.Lines, p)
	}
	return d, nil
}

// lcs adapts revdiff's token keep flags and backtrace to a flat uint32 table,
// with cancellation and one shared allocation/work budget for the whole diff.
func lcs(ctx context.Context, a, b []string, budget *int) ([]bool, []bool, bool, error) {
	m, n := len(a), len(b)
	ka, kb := make([]bool, m), make([]bool, n)
	if m == 0 || n == 0 {
		return ka, kb, true, nil
	}
	cells := (m + 1) * (n + 1)
	if cells > *budget {
		return ka, kb, false, nil
	}
	*budget -= cells
	dp := make([]uint32, cells)
	for i := 1; i <= m; i++ {
		if err := ctx.Err(); err != nil {
			return ka, kb, false, err
		}
		for j := 1; j <= n; j++ {
			index := i*(n+1) + j
			if a[i-1] == b[j-1] {
				dp[index] = dp[index-n-2] + 1
			} else {
				dp[index] = max(dp[index-n-1], dp[index-1])
			}
		}
	}
	for i, j := m, n; i > 0 && j > 0; {
		if a[i-1] == b[j-1] {
			ka[i-1] = true
			kb[j-1] = true
			i--
			j--
		} else if dp[(i-1)*(n+1)+j] >= dp[i*(n+1)+j-1] {
			i--
		} else {
			j--
		}
	}
	return ka, kb, true, nil
}

var tokenPattern = regexp.MustCompile(`[\pL\pN_]+|\s+|[^\pL\pN_\s]+`)

func intra(ctx context.Context, a, b string, budget *int) ([]Range, []Range, bool, error) {
	// Text length is bounded before tokenization; the token LCS consumes the
	// shared work budget. Whitespace participates fully so no change is hidden.
	at, bt := tokenPattern.FindAllStringIndex(a, -1), tokenPattern.FindAllStringIndex(b, -1)
	av, bv := make([]string, len(at)), make([]string, len(bt))
	for i, t := range at {
		av[i] = a[t[0]:t[1]]
	}
	for i, t := range bt {
		bv[i] = b[t[0]:t[1]]
	}
	ka, kb, ok, err := lcs(ctx, av, bv, budget)
	if !ok || err != nil {
		return nil, nil, ok, err
	}
	return changed(at, ka), changed(bt, kb), true, nil
}
func changed(tokens [][]int, keep []bool) []Range {
	r := []Range{}
	for i, t := range tokens {
		if keep[i] {
			continue
		}
		if len(r) > 0 && r[len(r)-1].End == t[0] {
			r[len(r)-1].End = t[1]
		} else {
			r = append(r, Range{t[0], t[1]})
		}
	}
	return r
}
