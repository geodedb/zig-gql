# Benchmark Results

This directory stores JSON benchmark results from `scale_bench.zig` for tracking performance over time.

## File Format

Each file is a JSON document with version, timestamp, system info, and per-tier metrics:

```json
{
  "version": 1,
  "timestamp": "2026-03-30T12:00:00Z",
  "git_commit": "abc1234",
  "system": { "os": "linux", "arch": "x86_64" },
  "tiers": [
    {
      "name": "1K",
      "query_count": 1700,
      "lex_ops_sec": 500000,
      "parse_simple_ns": 2500,
      "parse_rel_ns": 4500,
      "parse_complex_ns": 8000,
      "print_human_ns": 1200,
      "print_json_ns": 3500,
      "temporal_ns": 150,
      "keyword_ns": 45
    }
  ]
}
```

## Metrics

| Metric | Unit | Direction |
|--------|------|-----------|
| lex_ops_sec | queries/sec | Higher is better |
| parse_simple_ns | ns/query | Lower is better |
| parse_rel_ns | ns/query | Lower is better |
| parse_complex_ns | ns/query | Lower is better |
| print_human_ns | ns/print | Lower is better |
| print_json_ns | ns/print | Lower is better |
| temporal_ns | ns/parse | Lower is better |
| keyword_ns | ns/lookup | Lower is better |

## Naming Convention

- `baseline.json` -- the current accepted performance baseline
- `<short-sha>.json` -- results saved per commit via `make bench-save`

## Usage

```bash
make bench             # Run quick benchmarks
make scale-bench       # Run scale benchmark, print results
make bench-save        # Run and save to results/<sha>.json
make bench-baseline    # Run and save as baseline
make bench-compare     # Run and compare against baseline
```
