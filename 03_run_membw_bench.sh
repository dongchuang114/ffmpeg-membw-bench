#!/bin/bash
# FFmpeg 内存带宽基准测试主脚本
# 用法: bash 03_run_membw_bench.sh [OPTIONS]
#   --channels N      当前 BIOS 启用的内存通道数（用于结果标记，默认 24）
#   --duration N      每组测试时长（秒，默认 60）
#   --group A|B|C|D|E  只跑指定测试组（默认全部）
#   --output-dir DIR  结果输出目录（默认 results/Nch_TIMESTAMP）
#   --instances N     并行实例数（默认 24）
#   --skip-group GROUP  跳过某个测试组（可多次指定）
#   -h, --help        显示帮助

set -e

# ── 默认参数 ──────────────────────────────────
CHANNELS=24
DURATION=60
TEST_GROUP="ALL"
INSTANCES=24
INPUT=/dev/shm/input_4k_10s.yuv
PROJ=/work/ffmpeg-membw-bench
SKIP_GROUPS=()
OUTPUT_DIR=""

# ── 解析参数 ──────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --channels)    CHANNELS="$2";    shift 2 ;;
        --duration)    DURATION="$2";    shift 2 ;;
        --group)       TEST_GROUP="$2";  shift 2 ;;
        --instances)   INSTANCES="$2";   shift 2 ;;
        --output-dir)  OUTPUT_DIR="$2";  shift 2 ;;
        --skip-group)  SKIP_GROUPS+=("$2"); shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -15 | sed 's/^# //'
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="${PROJ}/results/${CHANNELS}ch_${TIMESTAMP}"
fi
mkdir -p "$OUTPUT_DIR"
LOGFILE="${OUTPUT_DIR}/bench.log"

should_skip() {
    local grp="$1"
    for sg in "${SKIP_GROUPS[@]}"; do
        [ "$sg" = "$grp" ] && return 0
    done
    return 1
}
should_run() {
    local grp="$1"
    [ "$TEST_GROUP" = "ALL" ] || [ "$TEST_GROUP" = "$grp" ]
}

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }

# ── 系统信息 ───────────────────────────────────
log "============================================"
log " FFmpeg Memory Bandwidth Benchmark"
log " Memory channels (BIOS config): ${CHANNELS}"
log " Test duration per group: ${DURATION}s"
log " Parallel instances: ${INSTANCES}"
log " Output dir: ${OUTPUT_DIR}"
log "============================================"
log "System info:"
lscpu | grep -E "Model name|Socket|Core|Thread|NUMA" | tee -a "$LOGFILE"
free -h | tee -a "$LOGFILE"
uname -r | tee -a "$LOGFILE"
log "numactl:"
numactl --hardware 2>&1 | head -8 | tee -a "$LOGFILE"
log "FFmpeg version:"
ffmpeg -version 2>&1 | head -2 | tee -a "$LOGFILE"

# ── 检查输入文件 ────────────────────────────────
if [ ! -f "$INPUT" ]; then
    log "ERROR: Input file not found: $INPUT"
    log "Please run 00_prepare_input.sh first."
    exit 1
fi
log "Input file: $(ls -lh $INPUT)"

# ── Meta JSON ──────────────────────────────────
META_JSON="${OUTPUT_DIR}/meta.json"
cat > "$META_JSON" <<METAEOF
{
  "channels": ${CHANNELS},
  "duration_s": ${DURATION},
  "instances": ${INSTANCES},
  "timestamp": "${TIMESTAMP}",
  "input": "${INPUT}",
  "output_dir": "${OUTPUT_DIR}",
  "hostname": "$(hostname)",
  "kernel": "$(uname -r)",
  "cpu_model": "$(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
}
METAEOF
log "Meta saved: $META_JSON"

# ────────────────────────────────────────────────────────────────
# 辅助函数：解析 ffmpeg log 获取 FPS
# ────────────────────────────────────────────────────────────────
parse_fps() {
    local logfile="$1"
    # ffmpeg 输出: frame= NNN fps= NNN ...
    grep -oP 'fps=\s*\K[0-9.]+' "$logfile" | tail -5 | \
        awk 'BEGIN{s=0;n=0} {s+=$1;n++} END{if(n>0) printf "%.2f", s/n; else print "0"}'
}

parse_frames() {
    local logfile="$1"
    grep -oP 'frame=\s*\K[0-9]+' "$logfile" | tail -1
}

# ────────────────────────────────────────────────────────────────
# 测试组 A：单实例基准（1 进程，最大 threads，测单核 IPC 上限）
# ────────────────────────────────────────────────────────────────
if should_run A && ! should_skip A; then
    log "============================================"
    log " Group A: Single instance x265 medium"
    log "============================================"
    ADIR="${OUTPUT_DIR}/groupA_single"
    mkdir -p "$ADIR"

    log "[A] Starting single-instance x265 medium test (${DURATION}s)..."
    START_A=$(date +%s)
    numactl --cpunodebind=0 --membind=0 \
        ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p -r 30 \
            -stream_loop -1 -i "$INPUT" \
            -t "$DURATION" \
            -c:v libx265 -preset medium \
            -x265-params "ref=5:bframes=3:pools=none" \
            -threads 16 \
            -f null - \
            2>&1 | tee "${ADIR}/instance_0.log"
    END_A=$(date +%s)
    ELAPSED_A=$((END_A - START_A))

    FPS_A=$(parse_fps "${ADIR}/instance_0.log")
    FRAMES_A=$(parse_frames "${ADIR}/instance_0.log")
    log "[A] Result: FPS=${FPS_A}, frames=${FRAMES_A}, elapsed=${ELAPSED_A}s"

    cat > "${ADIR}/result.json" <<EOF
{
  "group": "A",
  "desc": "single_instance_x265_medium",
  "channels": ${CHANNELS},
  "instances": 1,
  "duration_s": ${ELAPSED_A},
  "avg_fps_per_instance": ${FPS_A},
  "total_fps": ${FPS_A},
  "total_frames": ${FRAMES_A:-0}
}
EOF
    log "[A] Done. Result: ${ADIR}/result.json"
fi

# ────────────────────────────────────────────────────────────────
# 测试组 B：24 并行实例，x265 medium ref=5（主测试）
# ────────────────────────────────────────────────────────────────
if should_run B && ! should_skip B; then
    log "============================================"
    log " Group B: ${INSTANCES} parallel x265 medium (ref=5)"
    log "============================================"
    BDIR="${OUTPUT_DIR}/groupB_parallel_x265_medium"
    mkdir -p "$BDIR"

    log "[B] Launching ${INSTANCES} ffmpeg instances (${DURATION}s)..."
    PIDS=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        if [ "$i" -lt $((INSTANCES / 2)) ]; then
            NODE=0
        else
            NODE=1
        fi
        numactl --cpunodebind=${NODE} --membind=${NODE} \
            ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p -r 30 \
                -stream_loop -1 -i "$INPUT" \
                -t "$DURATION" \
                -c:v libx265 -preset medium \
                -x265-params "ref=5:bframes=3:pools=none" \
                -threads 16 \
                -f null - \
                >> "${BDIR}/instance_${i}.log" 2>&1 &
        PIDS+=($!)
    done
    log "[B] All instances launched. PIDs: ${PIDS[*]}"
    log "[B] Waiting for completion..."

    START_B=$(date +%s)
    # 启动后台带宽监控
    bash /work/ffmpeg-membw-bench/04_collect_metrics.sh \
        --output "${BDIR}/bandwidth.csv" \
        --interval 5 \
        --pids "${PIDS[*]}" &
    MONITOR_PID=$!

    wait "${PIDS[@]}"
    END_B=$(date +%s)
    kill "$MONITOR_PID" 2>/dev/null || true
    ELAPSED_B=$((END_B - START_B))
    log "[B] All instances completed in ${ELAPSED_B}s"

    # 汇总 FPS
    TOTAL_FPS_B=0
    FPS_LIST_B=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        FPS_I=$(parse_fps "${BDIR}/instance_${i}.log")
        FPS_LIST_B+=("$FPS_I")
        TOTAL_FPS_B=$(echo "$TOTAL_FPS_B + ${FPS_I:-0}" | bc)
    done
    AVG_FPS_B=$(echo "scale=2; $TOTAL_FPS_B / $INSTANCES" | bc)
    log "[B] Total FPS: ${TOTAL_FPS_B}, Avg per instance: ${AVG_FPS_B}"

    FPS_JSON_B=$(printf '%s\n' "${FPS_LIST_B[@]}" | jq -R . | jq -s .)
    cat > "${BDIR}/result.json" <<EOF
{
  "group": "B",
  "desc": "${INSTANCES}_parallel_x265_medium_ref5",
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_B},
  "avg_fps_per_instance": ${AVG_FPS_B},
  "total_fps": ${TOTAL_FPS_B},
  "fps_per_instance": ${FPS_JSON_B}
}
EOF
    log "[B] Done. Result: ${BDIR}/result.json"
fi

# ────────────────────────────────────────────────────────────────
# 测试组 C：24 并行实例，x265 slow（更高内存压力）
# ────────────────────────────────────────────────────────────────
if should_run C && ! should_skip C; then
    log "============================================"
    log " Group C: ${INSTANCES} parallel x265 slow"
    log "============================================"
    CDIR="${OUTPUT_DIR}/groupC_parallel_x265_slow"
    mkdir -p "$CDIR"

    log "[C] Launching ${INSTANCES} ffmpeg instances x265 slow (${DURATION}s)..."
    PIDS=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        NODE=$([ "$i" -lt $((INSTANCES / 2)) ] && echo 0 || echo 1)
        numactl --cpunodebind=${NODE} --membind=${NODE} \
            ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p -r 30 \
                -stream_loop -1 -i "$INPUT" \
                -t "$DURATION" \
                -c:v libx265 -preset slow \
                -x265-params "ref=5:bframes=3:pools=none" \
                -threads 16 \
                -f null - \
                >> "${CDIR}/instance_${i}.log" 2>&1 &
        PIDS+=($!)
    done
    log "[C] Waiting for completion..."
    START_C=$(date +%s)
    wait "${PIDS[@]}"
    END_C=$(date +%s)
    ELAPSED_C=$((END_C - START_C))

    TOTAL_FPS_C=0
    for i in $(seq 0 $((INSTANCES - 1))); do
        FPS_I=$(parse_fps "${CDIR}/instance_${i}.log")
        TOTAL_FPS_C=$(echo "$TOTAL_FPS_C + ${FPS_I:-0}" | bc)
    done
    AVG_FPS_C=$(echo "scale=2; $TOTAL_FPS_C / $INSTANCES" | bc)
    log "[C] Total FPS: ${TOTAL_FPS_C}, Avg per instance: ${AVG_FPS_C}"

    cat > "${CDIR}/result.json" <<EOF
{
  "group": "C",
  "desc": "${INSTANCES}_parallel_x265_slow",
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_C},
  "avg_fps_per_instance": ${AVG_FPS_C},
  "total_fps": ${TOTAL_FPS_C}
}
EOF
    log "[C] Done."
fi

# ────────────────────────────────────────────────────────────────
# 测试组 D：24 并行实例，x264 medium（对比测试）
# ────────────────────────────────────────────────────────────────
if should_run D && ! should_skip D; then
    log "============================================"
    log " Group D: ${INSTANCES} parallel x264 medium"
    log "============================================"
    DDIR="${OUTPUT_DIR}/groupD_parallel_x264"
    mkdir -p "$DDIR"

    log "[D] Launching ${INSTANCES} ffmpeg instances x264 (${DURATION}s)..."
    PIDS=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        NODE=$([ "$i" -lt $((INSTANCES / 2)) ] && echo 0 || echo 1)
        numactl --cpunodebind=${NODE} --membind=${NODE} \
            ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p -r 30 \
                -stream_loop -1 -i "$INPUT" \
                -t "$DURATION" \
                -c:v libx264 -preset medium \
                -threads 16 \
                -f null - \
                >> "${DDIR}/instance_${i}.log" 2>&1 &
        PIDS+=($!)
    done
    log "[D] Waiting..."
    START_D=$(date +%s)
    wait "${PIDS[@]}"
    END_D=$(date +%s)
    ELAPSED_D=$((END_D - START_D))

    TOTAL_FPS_D=0
    for i in $(seq 0 $((INSTANCES - 1))); do
        FPS_I=$(parse_fps "${DDIR}/instance_${i}.log")
        TOTAL_FPS_D=$(echo "$TOTAL_FPS_D + ${FPS_I:-0}" | bc)
    done
    AVG_FPS_D=$(echo "scale=2; $TOTAL_FPS_D / $INSTANCES" | bc)
    log "[D] Total FPS: ${TOTAL_FPS_D}, Avg per instance: ${AVG_FPS_D}"

    cat > "${DDIR}/result.json" <<EOF
{
  "group": "D",
  "desc": "${INSTANCES}_parallel_x264_medium",
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_D},
  "avg_fps_per_instance": ${AVG_FPS_D},
  "total_fps": ${TOTAL_FPS_D}
}
EOF
    log "[D] Done."
fi

# ────────────────────────────────────────────────────────────────
# 测试组 E：24 并行实例，纯解码（读密集测试）
# ────────────────────────────────────────────────────────────────
if should_run E && ! should_skip E; then
    log "============================================"
    log " Group E: ${INSTANCES} parallel decode (read-intensive)"
    log "============================================"
    EDIR="${OUTPUT_DIR}/groupE_parallel_decode"
    mkdir -p "$EDIR"

    # 先编码一个参考文件
    REF_FILE="/dev/shm/ref_4k_encode.mkv"
    if [ ! -f "$REF_FILE" ]; then
        log "[E] Encoding reference file for decode test..."
        ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p -r 30 \
            -i "$INPUT" \
            -t 10 \
            -c:v libx265 -preset ultrafast \
            -y "$REF_FILE" 2>&1 | tee "${EDIR}/encode_ref.log"
        log "[E] Reference file: $(ls -lh $REF_FILE)"
    fi

    log "[E] Launching ${INSTANCES} decode instances (${DURATION}s)..."
    PIDS=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        NODE=$([ "$i" -lt $((INSTANCES / 2)) ] && echo 0 || echo 1)
        numactl --cpunodebind=${NODE} --membind=${NODE} \
            ffmpeg -stream_loop -1 -i "$REF_FILE" \
                -t "$DURATION" \
                -f null - \
                >> "${EDIR}/instance_${i}.log" 2>&1 &
        PIDS+=($!)
    done
    log "[E] Waiting..."
    START_E=$(date +%s)
    wait "${PIDS[@]}"
    END_E=$(date +%s)
    ELAPSED_E=$((END_E - START_E))

    TOTAL_FPS_E=0
    for i in $(seq 0 $((INSTANCES - 1))); do
        FPS_I=$(parse_fps "${EDIR}/instance_${i}.log")
        TOTAL_FPS_E=$(echo "$TOTAL_FPS_E + ${FPS_I:-0}" | bc)
    done
    AVG_FPS_E=$(echo "scale=2; $TOTAL_FPS_E / $INSTANCES" | bc)
    log "[E] Total FPS: ${TOTAL_FPS_E}, Avg per instance: ${AVG_FPS_E}"

    cat > "${EDIR}/result.json" <<EOF
{
  "group": "E",
  "desc": "${INSTANCES}_parallel_decode",
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_E},
  "avg_fps_per_instance": ${AVG_FPS_E},
  "total_fps": ${TOTAL_FPS_E}
}
EOF
    log "[E] Done."
fi

# ── 汇总 ────────────────────────────────────────
log "============================================"
log " Benchmark Complete"
log " Results in: ${OUTPUT_DIR}"
log "============================================"
ls -la "${OUTPUT_DIR}/"
log "All done at $(date)"
