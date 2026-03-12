#!/bin/bash
# FFmpeg 内存带宽基准测试主脚本
# 用法: bash 03_run_membw_bench.sh [OPTIONS]
#   --channels N      当前 BIOS 启用的内存通道数（用于结果标记，默认 24）
#   --duration N      每组测试时长（秒，默认 60）
#   --group A|B|C|D|E|F|G  只跑指定测试组（默认全部）
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
# 场景横幅打印函数
log_banner() {
    local group_id="$1"
    local scene_name="$2"
    local scene_desc="$3"
    local characteristics="$4"
    local cpu_level="$5"
    local cpu_desc="$6"
    local mem_level="$7"
    local mem_desc="$8"
    local expected="$9"
    log "╔══════════════════════════════════════════════════════════╗"
    log "║  Group ${group_id} │ ${scene_name}"
    log "╠══════════════════════════════════════════════════════════╣"
    log "║  客户场景  ${scene_desc}"
    log "║  场景特点  ${characteristics}"
    log "║  CPU压力   [${cpu_level}]  ${cpu_desc}"
    log "║  内存压力  [${mem_level}]  ${mem_desc}"
    log "║  预期结论  ${expected}"
    log "╚══════════════════════════════════════════════════════════╝"
}

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
    log_banner "A" "单实例基准（CPU上限参考）" \
        "无内存竞争时单CCD编码能力上限" \
        "4K | x265 medium | ref=5 | 单实例 | -threads 16" \
        "低" "单实例仅用4%系统资源，CPU近乎空闲" \
        "极低" "working set 75MB/实例，但无并发，L3足够容纳" \
        "用于计算理论峰值：A组FPS×24=满配CPU上限"
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
  "scenario": {
    "name": "单实例基准（CPU上限参考）",
    "characteristics": ["4K分辨率", "x265 medium预设", "ref=5 bframes=3", "单实例"],
    "cpu_pressure": {"level": "低", "desc": "单实例仅用4%系统资源，CPU近乎空闲"},
    "memory_pressure": {"level": "极低", "desc": "working set 75MB/实例，L3足够容纳"},
    "expected": "用于计算理论峰值：A组FPS×24=满配CPU上限"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libx265",
    "preset": "medium",
    "x265_params": "ref=5:bframes=3:pools=none",
    "threads_per_instance": 16,
    "instances": 1
  },
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
    log_banner "B" "视频云（大量并发转码）" \
        "视频平台大量4K内容同时转码，最核心业务场景" \
        "4K | x265 medium | ref=5 | 24路并发 | numactl绑定" \
        "极高" "24实例×16线程=384线程，系统满载~100%" \
        "高" "24×75MB=1.8GB working set >> 768MB L3，强制访问DRAM" \
        "核心对比组：FPS拐点即为建议最低内存通道数"
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
  "scenario": {
    "name": "视频云（大量并发转码）",
    "characteristics": ["4K分辨率", "x265 medium预设", "ref=5 bframes=3", "24路并发"],
    "cpu_pressure": {"level": "极高", "desc": "384线程系统满载~100%"},
    "memory_pressure": {"level": "高", "desc": "1.8GB working set >> 768MB L3，强制DRAM"},
    "expected": "核心对比组，FPS拐点即为建议最低通道数"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libx265",
    "preset": "medium",
    "x265_params": "ref=5:bframes=3:pools=none",
    "threads_per_instance": 16,
    "instances": ${INSTANCES}
  },
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
    log_banner "C" "视频归档（标准质量压制）" \
        "内容归档平台，慢速高质量编码，追求压缩率" \
        "4K | x265 slow | ref=5 | 24路并发 | numactl绑定" \
        "极高" "slow预设运动估计范围更大，计算量比medium高30%" \
        "高" "slow预设搜索buffer更大，DRAM随机读增加30-50%" \
        "比B组更早出现FPS拐点，带宽饱和点更高"
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
  "scenario": {
    "name": "视频归档（标准质量压制）",
    "characteristics": ["4K分辨率", "x265 slow预设", "ref=5 bframes=3", "24路并发"],
    "cpu_pressure": {"level": "极高", "desc": "slow预设计算量比medium高30%"},
    "memory_pressure": {"level": "高", "desc": "搜索buffer更大，DRAM随机读增加30-50%"},
    "expected": "比B组更早出现FPS拐点，带宽饱和点更高"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libx265",
    "preset": "slow",
    "x265_params": "ref=5:bframes=3:pools=none",
    "threads_per_instance": 16,
    "instances": ${INSTANCES}
  },
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
    log_banner "D" "编码器横向对比（x264场景）" \
        "x264 vs x265内存带宽敏感度对比，选型决策依据" \
        "4K | x264 medium | 24路并发 | numactl绑定" \
        "极高" "x264整数运算为主，SIMD更规律，CPU满载" \
        "中" "x264访存模式更规律，DRAM带宽需求比x265低约30%" \
        "x264更适合内存减配配置，降幅应小于B组"
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
  "scenario": {
    "name": "编码器横向对比（x264场景）",
    "characteristics": ["4K分辨率", "x264 medium预设", "24路并发"],
    "cpu_pressure": {"level": "极高", "desc": "x264整数运算为主，SIMD更规律，CPU满载"},
    "memory_pressure": {"level": "中", "desc": "访存模式更规律，DRAM带宽需求比x265低约30%"},
    "expected": "x264更适合内存减配配置，降幅应小于B组"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libx264",
    "preset": "medium",
    "x265_params": "",
    "threads_per_instance": 16,
    "instances": ${INSTANCES}
  },
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
    log_banner "E" "CDN回源（纯解码读密集）" \
        "CDN节点解码回源，纯读场景，找DRAM读带宽饱和点" \
        "4K H.265 | 纯解码→null | 24路并发 | numactl绑定" \
        "中" "解码比编码轻，CPU利用率约50-70%" \
        "极高" "纯顺序读，最接近STREAM理论峰值，最先达到带宽上限" \
        "E组拐点=DRAM读带宽物理上限，为B/C组减配提供参考"
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
  "scenario": {
    "name": "CDN回源（纯解码读密集）",
    "characteristics": ["4K H.265", "纯解码→null", "24路并发"],
    "cpu_pressure": {"level": "中", "desc": "解码比编码轻，CPU利用率约50-70%"},
    "memory_pressure": {"level": "极高", "desc": "纯顺序读，最接近STREAM理论峰值，最先达到带宽上限"},
    "expected": "E组拐点=DRAM读带宽物理上限，为B/C组减配提供参考"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libx265",
    "preset": "ultrafast",
    "x265_params": "decode_only",
    "threads_per_instance": 16,
    "instances": ${INSTANCES}
  },
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_E},
  "avg_fps_per_instance": ${AVG_FPS_E},
  "total_fps": ${TOTAL_FPS_E}
}
EOF
    log "[E] Done."
fi

# ────────────────────────────────────────────────────────────────
# 测试组 F：24 并行实例，1080p x265 ultrafast（直播低延迟场景）
# 客户场景：直播平台实时推流，延迟第一，质量次之
# CPU压力：中等（ultrafast计算量低，约60% CPU利用率）
# 内存压力：极低（1080p working set 9MB/实例 << 单CCD 32MB L3）
# 预期：内存通道减配对此场景影响可忽略，可大幅减配
# ────────────────────────────────────────────────────────────────
if should_run F && ! should_skip F; then
    log_banner "F" "直播平台（低延迟推流）" \
        "实时直播推流，延迟第一，质量次之" \
        "1080p | x265 ultrafast | ref=1 bframes=0 | 24路并发" \
        "中等" "ultrafast计算量低，约60% CPU利用率" \
        "极低" "9MB/实例 << L3 32MB，基本不访问DRAM" \
        "内存通道减配影响可忽略，可大幅减配"
    log "============================================"
    log " Group F: ${INSTANCES} parallel 1080p x265 ultrafast"
    log "============================================"
    FDIR="${OUTPUT_DIR}/groupF_parallel_1080p_ultrafast"
    mkdir -p "$FDIR"

    log "[F] Launching ${INSTANCES} ffmpeg instances 1080p ultrafast (${DURATION}s)..."
    PIDS=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        NODE=$([ "$i" -lt $((INSTANCES / 2)) ] && echo 0 || echo 1)
        numactl --cpunodebind=${NODE} --membind=${NODE} \
            ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p -r 30 \
                -stream_loop -1 -i "$INPUT" \
                -t "$DURATION" \
                -vf scale=1920:1080 \
                -c:v libx265 -preset ultrafast \
                -x265-params "ref=1:bframes=0:pools=none" \
                -threads 16 \
                -f null - \
                >> "${FDIR}/instance_${i}.log" 2>&1 &
        PIDS+=($!)
    done
    log "[F] Waiting for all instances..."
    START_F=$(date +%s)
    wait "${PIDS[@]}"
    END_F=$(date +%s)
    ELAPSED_F=$((END_F - START_F))

    TOTAL_FPS_F=0
    for i in $(seq 0 $((INSTANCES - 1))); do
        FPS_I=$(parse_fps "${FDIR}/instance_${i}.log")
        TOTAL_FPS_F=$(echo "$TOTAL_FPS_F + ${FPS_I:-0}" | bc)
    done
    AVG_FPS_F=$(echo "scale=2; $TOTAL_FPS_F / $INSTANCES" | bc)
    log "[F] Total FPS: ${TOTAL_FPS_F}, Avg per instance: ${AVG_FPS_F}"

    cat > "${FDIR}/result.json" <<EOF
{
  "group": "F",
  "scenario": {
    "name": "直播平台（低延迟推流）",
    "characteristics": ["1080p分辨率", "ultrafast预设", "ref=1 bframes=0", "24路并发"],
    "cpu_pressure": {"level": "中等", "desc": "ultrafast计算量低，约60% CPU利用率"},
    "memory_pressure": {"level": "极低", "desc": "working set 9MB/实例 << L3 32MB，基本不访问DRAM"},
    "expected": "内存通道数对此场景影响可忽略，可大幅减配"
  },
  "params": {
    "resolution": "1920x1080",
    "codec": "libx265",
    "preset": "ultrafast",
    "x265_params": "ref=1:bframes=0:pools=none",
    "threads_per_instance": 16,
    "instances": ${INSTANCES}
  },
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_F},
  "avg_fps_per_instance": ${AVG_FPS_F},
  "total_fps": ${TOTAL_FPS_F}
}
EOF
    log "[F] Done. Result: ${FDIR}/result.json"
fi

# ────────────────────────────────────────────────────────────────
# 测试组 G：24 并行实例，4K x265 slow ref=8（高质量归档场景）
# 客户场景：专业视频归档，最高质量压制，带宽需求最极限
# CPU压力：极高（slow预设+ref=8，计算量最大）
# 内存压力：极高（ref=8 working set ~100MB/实例 >> L3，DRAM压力超过C组）
# 预期：内存带宽瓶颈最严重，减配影响最大，不建议减配
# ────────────────────────────────────────────────────────────────
if should_run G && ! should_skip G; then
    log_banner "G" "视频归档（高质量压制）" \
        "专业视频归档，最高质量，带宽需求极限" \
        "4K | x265 slow | ref=8 bframes=4 | 24路并发" \
        "极高" "slow+ref=8计算量最大，~100% CPU" \
        "极高" "~100MB/实例 >> L3 32MB，DRAM压力超过C组" \
        "内存带宽瓶颈最严重，减配影响最大，不建议减配"
    log "============================================"
    log " Group G: ${INSTANCES} parallel 4K x265 slow ref=8"
    log "============================================"
    GDIR="${OUTPUT_DIR}/groupG_parallel_x265_slow_ref8"
    mkdir -p "$GDIR"

    log "[G] Launching ${INSTANCES} ffmpeg instances x265 slow ref=8 (${DURATION}s)..."
    PIDS=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        NODE=$([ "$i" -lt $((INSTANCES / 2)) ] && echo 0 || echo 1)
        numactl --cpunodebind=${NODE} --membind=${NODE} \
            ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p -r 30 \
                -stream_loop -1 -i "$INPUT" \
                -t "$DURATION" \
                -c:v libx265 -preset slow \
                -x265-params "ref=8:bframes=4:pools=none:allow-non-conformance=1" \
                -threads 16 \
                -f null - \
                >> "${GDIR}/instance_${i}.log" 2>&1 &
        PIDS+=($!)
    done
    log "[G] Waiting for all instances..."
    START_G=$(date +%s)
    wait "${PIDS[@]}"
    END_G=$(date +%s)
    ELAPSED_G=$((END_G - START_G))

    TOTAL_FPS_G=0
    for i in $(seq 0 $((INSTANCES - 1))); do
        FPS_I=$(parse_fps "${GDIR}/instance_${i}.log")
        TOTAL_FPS_G=$(echo "$TOTAL_FPS_G + ${FPS_I:-0}" | bc)
    done
    AVG_FPS_G=$(echo "scale=2; $TOTAL_FPS_G / $INSTANCES" | bc)
    log "[G] Total FPS: ${TOTAL_FPS_G}, Avg per instance: ${AVG_FPS_G}"

    cat > "${GDIR}/result.json" <<EOF
{
  "group": "G",
  "scenario": {
    "name": "视频归档（高质量压制）",
    "characteristics": ["4K分辨率", "slow预设", "ref=8 bframes=4", "24路并发"],
    "cpu_pressure": {"level": "极高", "desc": "slow+ref=8计算量最大，CPU~100%"},
    "memory_pressure": {"level": "极高", "desc": "working set ~100MB/实例 >> L3 32MB，DRAM压力超过C组"},
    "expected": "内存带宽瓶颈最严重，减配影响最大，不建议减配"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libx265",
    "preset": "slow",
    "x265_params": "ref=8:bframes=4:pools=none",
    "threads_per_instance": 16,
    "instances": ${INSTANCES}
  },
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_G},
  "avg_fps_per_instance": ${AVG_FPS_G},
  "total_fps": ${TOTAL_FPS_G}
}
EOF
    log "[G] Done. Result: ${GDIR}/result.json"
fi

# ── 汇总 ────────────────────────────────────────
log "============================================"
log " Benchmark Complete"
log " Results in: ${OUTPUT_DIR}"
log "============================================"
ls -la "${OUTPUT_DIR}/"
log "All done at $(date)"
