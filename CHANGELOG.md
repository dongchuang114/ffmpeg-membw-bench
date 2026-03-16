# Changelog

All notable changes to ffmpeg-membw-bench are documented here.

---

## [v1.1.0] - 2025-03-16

### New Features

#### 1. Instance count auto-detected from CCD count (`--instances` still available)

**Background**: The original code hardcoded `INSTANCES=24`, only suitable for EPYC 9T24
(24 CCD). Different CPU models have different CCD counts, making manual maintenance
error-prone.

**Implementation**:
- On startup, reads `/sys/devices/system/cpu/cpu*/cache/index3/shared_cpu_list`
  and counts unique L3 cache sharing domains (each domain = 1 CCD)
- Falls back to `lscpu` L3 instance count, with final fallback default of 24
- `--instances N` still works; manual specification skips auto-detection
- NUMA binding changed from hardcoded node0/node1 half-split to round-robin
  (`i % numa_count`), supporting any number of NUMA nodes

**`meta.json` new fields**: `ccd_count`, `instances_auto`, `numa_nodes`, `numa_count`

#### 2. Threads per instance auto-calculated from vCPUs per CCD (`--threads` available)

**Background**: The original code hardcoded `-threads 16`, only suitable for EPYC 9T24
(16 vCPU/CCD). Different CPU models or SMT states require different values.

**Implementation**:
- Calculates `threads = nproc / ccd_count` (vCPUs within one CCD)
- `--threads N` overrides the auto-calculated value
- `meta.json` adds `threads_per_instance` and `threads_auto` fields

**Auto-calculation examples**:

| CPU Model               | Total vCPU | CCD | Auto threads |
|-------------------------|-----------|-----|-------------|
| EPYC 9T24 2P (SMT on)  | 384       | 24  | 16          |
| EPYC 9T24 1P (SMT on)  | 192       | 12  | 16          |
| EPYC 9T24 2P (SMT off) | 192       | 24  | 8           |
| EPYC 9374F 1P (SMT on) | 64        | 8   | 8           |

#### 3. Target FPS mode (`--target-fps N`)

**Background**: Previously only max throughput could be measured. There was no way to
answer: "At a fixed business target of N fps, how much CPU and memory bandwidth is
consumed?"

**Implementation**:
- New `--target-fps N` parameter; uses `-r N -re` to rate-limit ffmpeg input for
  encode groups (limits throughput to N fps, reducing CPU/memory load proportionally)
- Decode group (Group E) handled separately without `-vf fps` to preserve test semantics
- `TARGET_FPS=0` (default) behaves identically to the original version

#### 4. Real-time CPU utilization and memory usage sampling

**Background**: Original `04_collect_metrics.sh` only sampled process-level IO reads,
and `avg_cpu_pct` was always written as 0.

**Implementation (`04_collect_metrics.sh` extended)**:
- CPU utilization: `/proc/stat` diff method, sampled every 5s; iowait counted as busy
  (waiting for DRAM response is CPU resource consumption, not idle time)
- Memory usage: `MemTotal - MemAvailable` (actual usage excluding reclaimable page cache)
- New `iowait_pct` column for separate display of IO wait ratio
- All test groups (A-G) now launch monitor; previously only Group B had sampling

**`result.json` new fields per group**:
`target_fps`, `avg_cpu_pct`, `iowait_pct`, `mem_used_gb`, `membw_read_gbs`

### Code Quality Improvements (based on 2-round code review)

| Issue                                            | Fix                                                         |
|--------------------------------------------------|-------------------------------------------------------------|
| glob expansion + `set -e` boundary              | Use array to receive glob result, add explicit non-empty check |
| `detect_numa_nodes` embedded shell var in python3 | Rewritten as pure bash regex, removed python3 dependency   |
| iowait incorrectly counted as idle              | Fixed: iowait counted as busy, consistent with `top`/`htop` |
| `summarize_metrics` writing global variables    | Use associative array (`declare -A METRICS`), prevents cross-group pollution |
| `calc_csv_avg` filtering `>0` drops valid zeros | CPU/MEM columns not filtered; only bandwidth column filters diff-zero rows |
| `INSTANCES=0` no protection on detection fail   | Added `>0` check after detection; ERROR log + fallback to 24 |
| Group A sync execution prevents monitor start   | Changed to background `&` + `wait PID`, consistent with parallel groups |
| `05_generate_report.py` float() no null guard   | Added `safe_float()` helper to avoid ValueError             |

### File Change Summary

| File                   | Change Type | Key Changes                                                              |
|------------------------|-------------|--------------------------------------------------------------------------|
| `03_run_membw_bench.sh` | Enhancement | CCD detect, threads auto-calc, NUMA round-robin, `--target-fps`, per-group monitor |
| `04_collect_metrics.sh` | Enhancement | CPU%, mem_used_gb, iowait_pct sampling; 3 new CSV columns               |
| `05_generate_report.py` | Enhancement | Display new fields; `safe_float`; meta adds CCD/NUMA/threads info       |
| `README.md`             | Incremental | New params, CCD/threads detect principle, target-fps usage examples      |
| `CHANGELOG.md`          | New         | This file                                                                |

---

## [v1.0.0] - 2025-06-04

### Initial Release

- Test groups A-G (single instance / 24 parallel instances, multiple codec presets)
- numactl NUMA binding (hardcoded node0/node1 half-split)
- ffmpeg `-threads 16` hardcoded
- `04_collect_metrics.sh` process-level IO sampling (CPU% always 0)
- `05_generate_report.py` single-channel / multi-channel HTML reports
- `run_all_channels.sh` multi-channel interactive driver
- 24ch full-config baseline data (A-G all groups)
