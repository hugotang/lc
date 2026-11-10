"""Read real Objective-C exporter output using Python's independent CSV parser."""
import csv
import math
import sys
from collections import defaultdict
from pathlib import Path


def read_report(path):
    with path.open(encoding="utf-8", newline="") as stream:
        rows = list(csv.DictReader(stream, strict=True))
    assert rows
    samples = defaultdict(list)
    for row in rows:
        assert None not in row and None not in row.values(), "ragged CSV row"
        assert row["schema_version"] == "3"
        assert row["sync_status"] == ("lc.tapSync.active" if row["sync_active"] == "1" else "lc.tapSync.expiredInput")
        assert row["build"] == 'Release (測試,"quoted")\nline 2'
        assert row["ios_version"] == "27.0" and row["logical_cpus"] == "6"
        for key, value in row.items():
            if key not in ("build", "ios_version", "record_type", "role", "sync_status") and value:
                assert math.isfinite(float(value)), (key, value)
        samples[int(row["sample"])].append(row)
    for group in samples.values():
        combined, *processes = group
        assert combined["record_type"] == "combined"
        assert combined["process_number"] == combined["window_number"] == ""
        assert len(processes) == int(combined["processes"])
        assert processes[0]["role"] == "host" and processes[0]["process_number"] == "0"
        assert all(p["record_type"] == "process" for p in processes)
        assert len({p["process_number"] for p in processes}) == len(processes)
        assert all(p["response_samples"] == p["response_p95_ms"] == "" for p in processes)
        for column, coverage in (("cpu_pct", "cpu_coverage"), ("footprint_mib", "memory_coverage")):
            available = [p[column] for p in processes if p[column] != ""]
            assert int(combined[coverage]) == len(available)
            if len(available) == len(processes):
                assert math.isclose(float(combined[column]), sum(map(float, available)), abs_tol=1e-5)
            else:
                assert combined[column] == "", "incomplete aggregate was presented as a number"
    return samples


path = Path(sys.argv[1])
samples = read_report(path)
segments = defaultdict(list)
for group in samples.values():
    segments[int(group[0]["segment"])].append(group)
assert set(segments) == set(range(1, 7))
for group in segments[1]:
    assert all(p["sync_mode"] == "0" and p["sync_active"] == "0" for p in group)
    assert group[0]["response_p95_ms"] == ""
for segment in range(2, 7):
    for group in segments[segment]:
        assert all(p["sync_mode"] == "2" and p["sync_active"] == "1" for p in group)
assert segments[1][0][0]["cpu_pct"] == ""  # Warming is never encoded as zero.
assert any(g[2]["cpu_pct"] == g[2]["footprint_mib"] == "" for g in segments[1])
assert all(g[2]["process_number"] == "1" for g in segments[1])
assert all(g[2]["process_number"] == "2" for g in segments[3])
assert all(g[2]["window_number"] == "2" and g[2]["role"] == "follower" for g in segments[4])
assert segments[6][0][0]["cpu_pct"] == ""
assert float(segments[6][-1][0]["cpu_pct"]) == 25
assert float(segments[6][-1][0]["segment_elapsed_s"]) == 1

bounded = read_report(Path(str(path) + ".bounded.csv"))
assert list(bounded) == list(range(6, 306))
assert len(bounded) == 300 and sum(map(len, bounded.values())) == 600
assert all(g[0]["segment"] == "1" for g in bounded.values())
print("Performance CSV tests passed (standard parsing, Unicode/quote/newline metadata, decimal values, complete sample groups, missing readings and segment identities).")
