#!/bin/bash
# FFmpeg 内存带宽基准测试主脚本
# 用法: bash 03_run_membw_bench.sh [OPTIONS]
#   --channels N      当前 BIOS 启用的内存通道数（用于结果标记，默认 24）
#   --duration N      每组测试时长（秒，默认 60）
#   --group A|B|C|D|E|F|G|H|I|J|K|L|M|N|O  只跑指定测试组（默认全部）
#   --output-dir DIR  结果输出目录（默认 results/Nch_TIMESTAMP）
#   --instances N     并行实例数（默认 0=自动探测 CCD 数）
#   --threads N       每实例线程数（默认 0=自动探测 nproc/ccd_count）
#   --target-fps N    限速目标 FPS（默认 0=不限速）
#   --skip-group GROUP  跳过某个测试组（可多次指定）
#   -h, --help        显示帮助

set -e
ulimit -n 65536 2>/dev/null || true  # 防止 256 实例 fd 耗尽

# ── 默认参数 ──────────────────────────────────
CHANNELS=24
DURATION=60
TEST_GROUP="ALL"
INSTANCES=0          # 0 = 自动探测 CCD 数
INSTANCES_MANUAL=0
THREADS=0            # 0 = 自动探测（nproc / ccd_count）
THREADS_MANUAL=0
TARGET_FPS=0         # 0 = 不限速
INPUT=/dev/shm/input_4k_10s.yuv
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_GROUPS=()
OUTPUT_DIR=""

# ── 解析参数 ──────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --channels)    CHANNELS="$2";    shift 2 ;;
        --duration)    DURATION="$2";    shift 2 ;;
        --group)       TEST_GROUP="$2";  shift 2 ;;
        --instances)   INSTANCES="$2"; INSTANCES_MANUAL=1; shift 2 ;;
        --threads)     THREADS="$2";   THREADS_MANUAL=1;   shift 2 ;;
        --target-fps)  TARGET_FPS="$2";                    shift 2 ;;
        --output-dir)  OUTPUT_DIR="$2";  shift 2 ;;
        --skip-group)  SKIP_GROUPS+=("$2"); shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -15 | sed 's/^# //'
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── CCD 自动探测 ───────────────────────────────
detect_ccd_count() {
    local n=0 files
    files=( /sys/devices/system/cpu/cpu*/cache/index3/shared_cpu_list )
    if [ "${#files[@]}" -gt 0 ] && [ -f "${files[0]}" ]; then
        n=$(cut -d, -f1 "${files[@]}" 2>/dev/null | sort -nu | wc -l)
        n=${n//[^0-9]/}
    fi
    if [ "${n:-0}" -eq 0 ]; then
        n=$(lscpu 2>/dev/null | grep -i 'L3 cache' | grep -oP '\d+(?= instance)' || echo 0)
        n=${n:-0}
    fi
    echo "${n:-24}"
}

# ── NUMA 节点探测 ──────────────────────────────
detect_numa_nodes() {
    local raw nodes=()
    raw=$(numactl --hardware 2>/dev/null \
          | grep '^available:' \
          | grep -oP '(?<=\()[\d ,\-]+(?=\))' \
          | grep -oP '\d+-\d+|\d+' \
          | tr '\n' ' ')
    for token in $raw; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
            for ((i=a; i<=b; i++)); do nodes+=("$i"); done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            nodes+=("$token")
        fi
    done
    [ "${#nodes[@]}" -eq 0 ] && nodes=(0)
    echo "${nodes[@]}"
}

assign_numa_node() {
    local idx="$1"
    echo "${NUMA_NODES[$((idx % NUMA_COUNT))]}"
}

# ── 执行探测 ──────────────────────────────────
CCD_COUNT=$(detect_ccd_count)
if [ "${CCD_COUNT:-0}" -le 0 ]; then
    echo "WARNING: CCD detection failed, fallback to 24" >&2
    CCD_COUNT=24
fi

TOTAL_VCPUS=$(nproc)

if [ "$INSTANCES_MANUAL" -eq 0 ]; then
    INSTANCES=$CCD_COUNT
fi

if [ "$THREADS_MANUAL" -eq 0 ]; then
    THREADS=$((TOTAL_VCPUS / CCD_COUNT))
    [ "$THREADS" -le 0 ] && THREADS=16
fi

NUMA_NODES_STR=$(detect_numa_nodes)
read -ra NUMA_NODES <<< "$NUMA_NODES_STR"
NUMA_COUNT=${#NUMA_NODES[@]}

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
log " CCD count (auto-detected): ${CCD_COUNT}"
log " Instances: ${INSTANCES}$( [ "$INSTANCES_MANUAL" -eq 1 ] && echo ' (manual)' || echo ' (auto=CCD count)' )"
log " Threads per instance: ${THREADS}$( [ "$THREADS_MANUAL" -eq 1 ] && echo ' (manual)' || echo " (auto=${TOTAL_VCPUS}/${CCD_COUNT})" )"
log " Target FPS: $( [ "$TARGET_FPS" -gt 0 ] && echo "${TARGET_FPS}" || echo 'unlimited' )"
log " NUMA nodes: ${NUMA_NODES[*]} (count=${NUMA_COUNT})"
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
  "instances_auto": $( [ "$INSTANCES_MANUAL" -eq 0 ] && echo true || echo false ),
  "ccd_count": ${CCD_COUNT},
  "threads_per_instance": ${THREADS},
  "threads_auto": $( [ "$THREADS_MANUAL" -eq 0 ] && echo true || echo false ),
  "total_vcpus": ${TOTAL_VCPUS},
  "numa_nodes": [$(IFS=,; echo "${NUMA_NODES[*]}")],
  "numa_count": ${NUMA_COUNT},
  "target_fps": ${TARGET_FPS},
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

# 构建 ffmpeg 限速参数
# mode: encode（编码组，用 -vf fps 丢帧）或 decode（解码组，用 -re）
build_fps_args() {
    local target="${1:-0}" src_fps="${2:-30}" mode="${3:-encode}"
    if [ "${target}" -gt 0 ] 2>/dev/null; then
        if [ "$mode" = "decode" ]; then
            echo "-r ${target} -re"
        else
            # 编码：全速读取（输入侧只设帧率，输出侧 -vf fps 由 build_vf_args 单独控制）
            echo "-r ${src_fps}"
        fi
    else
        echo "-r ${src_fps}"
    fi
}

# 构建 ffmpeg 输出端 fps 过滤器（必须放在 -i 之后）
# 仅 encode 模式、target>0 时生效
build_vf_args() {
    local target="${1:-0}" mode="${2:-encode}"
    if [ "${target}" -gt 0 ] 2>/dev/null && [ "$mode" = "encode" ]; then
        echo "-vf fps=${target}"
    fi
}


# 构建 ffmpeg 输出端 fps 过滤器（必须放在 -i 之后）
# 仅 encode 模式 target>0 时生效；decode 模式 -re 已限速
build_vf_args() {
    local target="${1:-0}" mode="${2:-encode}"
    if [ "${target}" -gt 0 ] 2>/dev/null && [ "$mode" = "encode" ]; then
        echo "-vf fps=${target}"
    fi
}

# 从 bandwidth.csv 计算均值（关联数组存储，前缀区分组）
declare -A METRICS

summarize_metrics() {
    local csv="$1" grp="$2"
    if [ ! -f "$csv" ] || [ "$(wc -l < "$csv")" -lt 3 ]; then
        METRICS["${grp}_cpu"]=0
        METRICS["${grp}_iowait"]=0
        METRICS["${grp}_mem"]=0
        METRICS["${grp}_bw"]=0
        return
    fi
    # col: 4=read_MB_s, 6=cpu_pct, 7=iowait_pct, 8=mem_gb
    METRICS["${grp}_cpu"]=$(awk -F',' 'NR>2 {sum+=$6;n++} END{printf "%.1f",n?sum/n:0}' "$csv")
    METRICS["${grp}_iowait"]=$(awk -F',' 'NR>2 {sum+=$7;n++} END{printf "%.1f",n?sum/n:0}' "$csv")
    METRICS["${grp}_mem"]=$(awk -F',' 'NR>2 {sum+=$8;n++} END{printf "%.2f",n?sum/n:0}' "$csv")
    local bw_mbs
    bw_mbs=$(awk -F',' 'NR>2 && $4+0>0 {sum+=$4;n++} END{printf "%.2f",n?sum/n:0}' "$csv")
    METRICS["${grp}_bw"]=$(echo "scale=2; ${bw_mbs:-0} / 1024" | bc)
}

# ────────────────────────────────────────────────────────────────
# 测试组 A：单实例基准（1 进程，最大 threads，测单核 IPC 上限）
# ────────────────────────────────────────────────────────────────
if should_run A && ! should_skip A; then
    log_banner "A" "单实例基准（CPU上限参考）" \
        "无内存竞争时单CCD编码能力上限" \
        "4K | x265 medium | ref=5 | 单实例 | -threads ${THREADS}" \
        "低" "单实例仅用4%系统资源，CPU近乎空闲" \
        "极低" "working set 75MB/实例，但无并发，L3足够容纳" \
        "用于计算理论峰值：A组FPS×${INSTANCES}=满配CPU上限"
    log "============================================"
    log " Group A: Single instance x265 medium"
    log "============================================"
    ADIR="${OUTPUT_DIR}/groupA_single"
    mkdir -p "$ADIR"

    log "[A] Starting single-instance x265 medium test (${DURATION}s)..."
    FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "encode")
    VF_ARGS=$(build_vf_args "$TARGET_FPS" "encode")
    START_A=$(date +%s)
    numactl --cpunodebind=0 --membind=0 \
        ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
            ${FPS_ARGS} \
            -stream_loop -1 -i "$INPUT" \
            ${VF_ARGS} \
            -t "$DURATION" \
            -c:v libx265 -preset medium \
            -x265-params "ref=5:bframes=3:pools=none" \
            -threads ${THREADS} \
            -f null - \
            >> "${ADIR}/instance_0.log" 2>&1 &
    A_PID=$!
    bash ${PROJ}/04_collect_metrics.sh \
        --output "${ADIR}/bandwidth.csv" \
        --interval 5 --pids "$A_PID" &
    MONITOR_PID=$!
    wait "$A_PID"
    END_A=$(date +%s)
    kill "$MONITOR_PID" 2>/dev/null; wait "$MONITOR_PID" 2>/dev/null || true
    ELAPSED_A=$((END_A - START_A))
    summarize_metrics "${ADIR}/bandwidth.csv" "A"

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
    "expected": "用于计算理论峰值：A组FPS×${INSTANCES}=满配CPU上限"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libx265",
    "preset": "medium",
    "x265_params": "ref=5:bframes=3:pools=none",
    "threads_per_instance": ${THREADS},
    "instances": 1
  },
  "channels": ${CHANNELS},
  "instances": 1,
  "duration_s": ${ELAPSED_A},
  "avg_fps_per_instance": ${FPS_A},
  "total_fps": ${FPS_A},
  "total_frames": ${FRAMES_A:-0},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[A_cpu]},
  "iowait_pct": ${METRICS[A_iowait]},
  "mem_used_gb": ${METRICS[A_mem]},
  "membw_read_gbs": ${METRICS[A_bw]}
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
        "4K | x265 medium | ref=5 | ${INSTANCES}路并发 | numactl绑定" \
        "极高" "${INSTANCES}实例×${THREADS}线程，系统满载~100%" \
        "高" "${INSTANCES}×75MB working set >> 768MB L3，强制访问DRAM" \
        "核心对比组：FPS拐点即为建议最低内存通道数"
    log "============================================"
    log " Group B: ${INSTANCES} parallel x265 medium (ref=5)"
    log "============================================"
    BDIR="${OUTPUT_DIR}/groupB_parallel_x265_medium"
    mkdir -p "$BDIR"

    log "[B] Launching ${INSTANCES} ffmpeg instances (${DURATION}s)..."
    FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "encode")
    VF_ARGS=$(build_vf_args "$TARGET_FPS" "encode")
    PIDS=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        NODE=$(assign_numa_node "$i")
        numactl --cpunodebind=${NODE} --membind=${NODE} \
            ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                ${FPS_ARGS} \
                -stream_loop -1 -i "$INPUT" \
                ${VF_ARGS} \
                -t "$DURATION" \
                -c:v libx265 -preset medium \
                -x265-params "ref=5:bframes=3:pools=none" \
                -threads ${THREADS} \
                -f null - \
                >> "${BDIR}/instance_${i}.log" 2>&1 &
        PIDS+=($!)
    done
    log "[B] All instances launched. PIDs: ${PIDS[*]}"
    log "[B] Waiting for completion..."

    START_B=$(date +%s)
    # 启动后台带宽监控
    bash ${PROJ}/04_collect_metrics.sh \
        --output "${BDIR}/bandwidth.csv" \
        --interval 5 \
        --pids "${PIDS[*]}" &
    MONITOR_PID=$!

    wait "${PIDS[@]}"
    END_B=$(date +%s)
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    ELAPSED_B=$((END_B - START_B))
    log "[B] All instances completed in ${ELAPSED_B}s"
    summarize_metrics "${BDIR}/bandwidth.csv" "B"

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
    "characteristics": ["4K分辨率", "x265 medium预设", "ref=5 bframes=3", "${INSTANCES}路并发"],
    "cpu_pressure": {"level": "极高", "desc": "${INSTANCES}×${THREADS}线程系统满载~100%"},
    "memory_pressure": {"level": "高", "desc": "${INSTANCES}×75MB working set >> 768MB L3，强制DRAM"},
    "expected": "核心对比组，FPS拐点即为建议最低通道数"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libx265",
    "preset": "medium",
    "x265_params": "ref=5:bframes=3:pools=none",
    "threads_per_instance": ${THREADS},
    "instances": ${INSTANCES}
  },
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_B},
  "avg_fps_per_instance": ${AVG_FPS_B},
  "total_fps": ${TOTAL_FPS_B},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[B_cpu]},
  "iowait_pct": ${METRICS[B_iowait]},
  "mem_used_gb": ${METRICS[B_mem]},
  "membw_read_gbs": ${METRICS[B_bw]},
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
        "4K | x265 slow | ref=5 | ${INSTANCES}路并发 | numactl绑定" \
        "极高" "slow预设运动估计范围更大，计算量比medium高30%" \
        "高" "slow预设搜索buffer更大，DRAM随机读增加30-50%" \
        "比B组更早出现FPS拐点，带宽饱和点更高"
    log "============================================"
    log " Group C: ${INSTANCES} parallel x265 slow"
    log "============================================"
    CDIR="${OUTPUT_DIR}/groupC_parallel_x265_slow"
    mkdir -p "$CDIR"

    log "[C] Launching ${INSTANCES} ffmpeg instances x265 slow (${DURATION}s)..."
    FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "encode")
    VF_ARGS=$(build_vf_args "$TARGET_FPS" "encode")
    PIDS=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        NODE=$(assign_numa_node "$i")
        numactl --cpunodebind=${NODE} --membind=${NODE} \
            ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                ${FPS_ARGS} \
                -stream_loop -1 -i "$INPUT" \
                ${VF_ARGS} \
                -t "$DURATION" \
                -c:v libx265 -preset slow \
                -x265-params "ref=5:bframes=3:pools=none" \
                -threads ${THREADS} \
                -f null - \
                >> "${CDIR}/instance_${i}.log" 2>&1 &
        PIDS+=($!)
    done
    log "[C] Waiting for completion..."
    START_C=$(date +%s)
    bash ${PROJ}/04_collect_metrics.sh \
        --output "${CDIR}/bandwidth.csv" \
        --interval 5 \
        --pids "${PIDS[*]}" &
    MONITOR_PID=$!
    wait "${PIDS[@]}"
    END_C=$(date +%s)
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    ELAPSED_C=$((END_C - START_C))
    summarize_metrics "${CDIR}/bandwidth.csv" "C"

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
    "characteristics": ["4K分辨率", "x265 slow预设", "ref=5 bframes=3", "${INSTANCES}路并发"],
    "cpu_pressure": {"level": "极高", "desc": "slow预设计算量比medium高30%"},
    "memory_pressure": {"level": "高", "desc": "搜索buffer更大，DRAM随机读增加30-50%"},
    "expected": "比B组更早出现FPS拐点，带宽饱和点更高"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libx265",
    "preset": "slow",
    "x265_params": "ref=5:bframes=3:pools=none",
    "threads_per_instance": ${THREADS},
    "instances": ${INSTANCES}
  },
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_C},
  "avg_fps_per_instance": ${AVG_FPS_C},
  "total_fps": ${TOTAL_FPS_C},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[C_cpu]},
  "iowait_pct": ${METRICS[C_iowait]},
  "mem_used_gb": ${METRICS[C_mem]},
  "membw_read_gbs": ${METRICS[C_bw]}
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
        "4K | x264 medium | ${INSTANCES}路并发 | numactl绑定" \
        "极高" "x264整数运算为主，SIMD更规律，CPU满载" \
        "中" "x264访存模式更规律，DRAM带宽需求比x265低约30%" \
        "x264更适合内存减配配置，降幅应小于B组"
    log "============================================"
    log " Group D: ${INSTANCES} parallel x264 medium"
    log "============================================"
    DDIR="${OUTPUT_DIR}/groupD_parallel_x264"
    mkdir -p "$DDIR"

    log "[D] Launching ${INSTANCES} ffmpeg instances x264 (${DURATION}s)..."
    FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "encode")
    VF_ARGS=$(build_vf_args "$TARGET_FPS" "encode")
    PIDS=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        NODE=$(assign_numa_node "$i")
        numactl --cpunodebind=${NODE} --membind=${NODE} \
            ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                ${FPS_ARGS} \
                -stream_loop -1 -i "$INPUT" \
                ${VF_ARGS} \
                -t "$DURATION" \
                -c:v libx264 -preset medium \
                -threads ${THREADS} \
                -f null - \
                >> "${DDIR}/instance_${i}.log" 2>&1 &
        PIDS+=($!)
    done
    log "[D] Waiting..."
    START_D=$(date +%s)
    bash ${PROJ}/04_collect_metrics.sh \
        --output "${DDIR}/bandwidth.csv" \
        --interval 5 \
        --pids "${PIDS[*]}" &
    MONITOR_PID=$!
    wait "${PIDS[@]}"
    END_D=$(date +%s)
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    ELAPSED_D=$((END_D - START_D))
    summarize_metrics "${DDIR}/bandwidth.csv" "D"

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
    "characteristics": ["4K分辨率", "x264 medium预设", "${INSTANCES}路并发"],
    "cpu_pressure": {"level": "极高", "desc": "x264整数运算为主，SIMD更规律，CPU满载"},
    "memory_pressure": {"level": "中", "desc": "访存模式更规律，DRAM带宽需求比x265低约30%"},
    "expected": "x264更适合内存减配配置，降幅应小于B组"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libx264",
    "preset": "medium",
    "x265_params": "",
    "threads_per_instance": ${THREADS},
    "instances": ${INSTANCES}
  },
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_D},
  "avg_fps_per_instance": ${AVG_FPS_D},
  "total_fps": ${TOTAL_FPS_D},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[D_cpu]},
  "iowait_pct": ${METRICS[D_iowait]},
  "mem_used_gb": ${METRICS[D_mem]},
  "membw_read_gbs": ${METRICS[D_bw]}
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
        "4K H.265 | 纯解码→null | ${INSTANCES}路并发 | numactl绑定" \
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
    FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "decode")
    PIDS=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        NODE=$(assign_numa_node "$i")
        numactl --cpunodebind=${NODE} --membind=${NODE} \
            ffmpeg ${FPS_ARGS} -stream_loop -1 -i "$REF_FILE" \
                ${VF_ARGS} \
                -t "$DURATION" \
                -f null - \
                >> "${EDIR}/instance_${i}.log" 2>&1 &
        PIDS+=($!)
    done
    log "[E] Waiting..."
    START_E=$(date +%s)
    bash ${PROJ}/04_collect_metrics.sh \
        --output "${EDIR}/bandwidth.csv" \
        --interval 5 \
        --pids "${PIDS[*]}" &
    MONITOR_PID=$!
    wait "${PIDS[@]}"
    END_E=$(date +%s)
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    ELAPSED_E=$((END_E - START_E))
    summarize_metrics "${EDIR}/bandwidth.csv" "E"

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
    "characteristics": ["4K H.265", "纯解码→null", "${INSTANCES}路并发"],
    "cpu_pressure": {"level": "中", "desc": "解码比编码轻，CPU利用率约50-70%"},
    "memory_pressure": {"level": "极高", "desc": "纯顺序读，最接近STREAM理论峰值，最先达到带宽上限"},
    "expected": "E组拐点=DRAM读带宽物理上限，为B/C组减配提供参考"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libx265",
    "preset": "ultrafast",
    "x265_params": "decode_only",
    "threads_per_instance": ${THREADS},
    "instances": ${INSTANCES}
  },
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_E},
  "avg_fps_per_instance": ${AVG_FPS_E},
  "total_fps": ${TOTAL_FPS_E},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[E_cpu]},
  "iowait_pct": ${METRICS[E_iowait]},
  "mem_used_gb": ${METRICS[E_mem]},
  "membw_read_gbs": ${METRICS[E_bw]}
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
        "1080p | x265 ultrafast | ref=1 bframes=0 | ${INSTANCES}路并发" \
        "中等" "ultrafast计算量低，约60% CPU利用率" \
        "极低" "9MB/实例 << L3 32MB，基本不访问DRAM" \
        "内存通道减配影响可忽略，可大幅减配"
    log "============================================"
    log " Group F: ${INSTANCES} parallel 1080p x265 ultrafast"
    log "============================================"
    FDIR="${OUTPUT_DIR}/groupF_parallel_1080p_ultrafast"
    mkdir -p "$FDIR"

    log "[F] Launching ${INSTANCES} ffmpeg instances 1080p ultrafast (${DURATION}s)..."
    FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "encode")
    VF_ARGS=$(build_vf_args "$TARGET_FPS" "encode")
    PIDS=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        NODE=$(assign_numa_node "$i")
        numactl --cpunodebind=${NODE} --membind=${NODE} \
            ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                ${FPS_ARGS} \
                -stream_loop -1 -i "$INPUT" \
                ${VF_ARGS} \
                -t "$DURATION" \
                -vf scale=1920:1080 \
                -c:v libx265 -preset ultrafast \
                -x265-params "ref=1:bframes=0:pools=none" \
                -threads ${THREADS} \
                -f null - \
                >> "${FDIR}/instance_${i}.log" 2>&1 &
        PIDS+=($!)
    done
    log "[F] Waiting for all instances..."
    START_F=$(date +%s)
    bash ${PROJ}/04_collect_metrics.sh \
        --output "${FDIR}/bandwidth.csv" \
        --interval 5 \
        --pids "${PIDS[*]}" &
    MONITOR_PID=$!
    wait "${PIDS[@]}"
    END_F=$(date +%s)
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    ELAPSED_F=$((END_F - START_F))
    summarize_metrics "${FDIR}/bandwidth.csv" "F"

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
    "characteristics": ["1080p分辨率", "ultrafast预设", "ref=1 bframes=0", "${INSTANCES}路并发"],
    "cpu_pressure": {"level": "中等", "desc": "ultrafast计算量低，约60% CPU利用率"},
    "memory_pressure": {"level": "极低", "desc": "working set 9MB/实例 << L3 32MB，基本不访问DRAM"},
    "expected": "内存通道数对此场景影响可忽略，可大幅减配"
  },
  "params": {
    "resolution": "1920x1080",
    "codec": "libx265",
    "preset": "ultrafast",
    "x265_params": "ref=1:bframes=0:pools=none",
    "threads_per_instance": ${THREADS},
    "instances": ${INSTANCES}
  },
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_F},
  "avg_fps_per_instance": ${AVG_FPS_F},
  "total_fps": ${TOTAL_FPS_F},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[F_cpu]},
  "iowait_pct": ${METRICS[F_iowait]},
  "mem_used_gb": ${METRICS[F_mem]},
  "membw_read_gbs": ${METRICS[F_bw]}
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
        "4K | x265 slow | ref=8 bframes=4 | ${INSTANCES}路并发" \
        "极高" "slow+ref=8计算量最大，~100% CPU" \
        "极高" "~100MB/实例 >> L3 32MB，DRAM压力超过C组" \
        "内存带宽瓶颈最严重，减配影响最大，不建议减配"
    log "============================================"
    log " Group G: ${INSTANCES} parallel 4K x265 slow ref=8"
    log "============================================"
    GDIR="${OUTPUT_DIR}/groupG_parallel_x265_slow_ref8"
    mkdir -p "$GDIR"

    log "[G] Launching ${INSTANCES} ffmpeg instances x265 slow ref=8 (${DURATION}s)..."
    FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "encode")
    VF_ARGS=$(build_vf_args "$TARGET_FPS" "encode")
    PIDS=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        NODE=$(assign_numa_node "$i")
        numactl --cpunodebind=${NODE} --membind=${NODE} \
            ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                ${FPS_ARGS} \
                -stream_loop -1 -i "$INPUT" \
                ${VF_ARGS} \
                -t "$DURATION" \
                -c:v libx265 -preset slow \
                -x265-params "ref=8:bframes=4:pools=none:allow-non-conformance=1" \
                -threads ${THREADS} \
                -f null - \
                >> "${GDIR}/instance_${i}.log" 2>&1 &
        PIDS+=($!)
    done
    log "[G] Waiting for all instances..."
    START_G=$(date +%s)
    bash ${PROJ}/04_collect_metrics.sh \
        --output "${GDIR}/bandwidth.csv" \
        --interval 5 \
        --pids "${PIDS[*]}" &
    MONITOR_PID=$!
    wait "${PIDS[@]}"
    END_G=$(date +%s)
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    ELAPSED_G=$((END_G - START_G))
    summarize_metrics "${GDIR}/bandwidth.csv" "G"

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
    "characteristics": ["4K分辨率", "slow预设", "ref=8 bframes=4", "${INSTANCES}路并发"],
    "cpu_pressure": {"level": "极高", "desc": "slow+ref=8计算量最大，CPU~100%"},
    "memory_pressure": {"level": "极高", "desc": "working set ~100MB/实例 >> L3 32MB，DRAM压力超过C组"},
    "expected": "内存带宽瓶颈最严重，减配影响最大，不建议减配"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libx265",
    "preset": "slow",
    "x265_params": "ref=8:bframes=4:pools=none",
    "threads_per_instance": ${THREADS},
    "instances": ${INSTANCES}
  },
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_G},
  "avg_fps_per_instance": ${AVG_FPS_G},
  "total_fps": ${TOTAL_FPS_G},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[G_cpu]},
  "iowait_pct": ${METRICS[G_iowait]},
  "mem_used_gb": ${METRICS[G_mem]},
  "membw_read_gbs": ${METRICS[G_bw]}
}
EOF
    log "[G] Done. Result: ${GDIR}/result.json"
fi

# ────────────────────────────────────────────────────────────────
# 测试组 H：INSTANCES 并行实例，4K x265 ultrafast（内存带宽压测）
#
# 背景：x265 ultrafast 预设禁用了大部分编码分析步骤，
#       使编码器从"计算密集"转为"内存读写密集"，
#       是 FFmpeg 框架内最接近内存带宽压测的工作负载。
#
# 与 x265 medium 对比（256实例 × 1线程实测）：
#   medium  → 总 FPS 819，  CPU 98.3%，内存带宽 ~8% 峰值
#   ultrafast → 总 FPS 2042，CPU ~98%，内存带宽 ~12% 峰值
#
# x265 ultrafast 关闭了哪些分析步骤（相比 medium）：
#   - 运动估计（ME）：medium 做全搜索（hexbs/star），ultrafast 只做菱形（dia）且搜索范围极小
#   - 参考帧数：medium ref=5，ultrafast ref=1（只看上一帧）
#   - B帧预测：medium bframes=3，ultrafast bframes=0
#   - 帧内模式数：medium 35种，ultrafast 4种
#   - 去方块滤镜（deblocking）：ultrafast 关闭
#   - SAO（Sample Adaptive Offset）：ultrafast 关闭
#   - RD（Rate-Distortion）优化：ultrafast 0级，medium 3级
# 上述步骤的关闭使每帧 CPU 算术量下降约 5-8 倍，
# 帧率大幅提升，内存读写占总耗时的比例相应提高，
# 更容易触及 DRAM 带宽瓶颈。
#
# 客户场景：极低延迟直播推流、内存带宽减配评估
# CPU压力：高（~98%，但主要是简单算术）
# 内存压力：高（内存带宽利用率约为 medium 的 1.5x）
# ────────────────────────────────────────────────────────────────
if should_run H && ! should_skip H; then
    log_banner "H" "内存带宽压测（4K x265 ultrafast）" \
        "极低延迟推流 / 内存带宽减配评估基准" \
        "4K | x265 ultrafast | ref=1 bframes=0 | ${INSTANCES}路并发 | numactl绑定" \
        "高" "ultrafast计算量仅为medium的1/5~1/8，但实例数多，CPU仍高负载" \
        "高" "禁用ME后内存带宽占比提升，是FFmpeg内最接近内存带宽受限的编码负载" \
        "对比B组：相同实例数下FPS约2.5x，内存带宽利用率约1.5x"
    log "============================================"
    log " Group H: ${INSTANCES} parallel 4K x265 ultrafast (membw stress)"
    log "============================================"
    HDIR="${OUTPUT_DIR}/groupH_parallel_x265_ultrafast"
    mkdir -p "$HDIR"

    log "[H] Launching ${INSTANCES} ffmpeg instances x265 ultrafast (${DURATION}s)..."
    FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "encode")
    VF_ARGS=$(build_vf_args "$TARGET_FPS" "encode")
    PIDS=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        NODE=$(assign_numa_node "$i")
        numactl --cpunodebind=${NODE} --membind=${NODE} \
            ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                ${FPS_ARGS} \
                -stream_loop -1 -i "$INPUT" \
                ${VF_ARGS} \
                -t "$DURATION" \
                -c:v libx265 -preset ultrafast \
                -x265-params "ref=1:bframes=0:pools=none" \
                -threads ${THREADS} \
                -f null - \
                >> "${HDIR}/instance_${i}.log" 2>&1 &
        PIDS+=($!)
    done
    log "[H] All instances launched. PIDs: ${PIDS[*]}"
    log "[H] Waiting for completion..."

    START_H=$(date +%s)
    bash ${PROJ}/04_collect_metrics.sh \
        --output "${HDIR}/bandwidth.csv" \
        --interval 5 \
        --pids "${PIDS[*]}" &
    MONITOR_PID=$!

    wait "${PIDS[@]}"
    END_H=$(date +%s)
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    ELAPSED_H=$((END_H - START_H))
    log "[H] All instances completed in ${ELAPSED_H}s"
    summarize_metrics "${HDIR}/bandwidth.csv" "H"

    TOTAL_FPS_H=0
    FPS_LIST_H=()
    for i in $(seq 0 $((INSTANCES - 1))); do
        FPS_I=$(parse_fps "${HDIR}/instance_${i}.log")
        FPS_LIST_H+=("$FPS_I")
        TOTAL_FPS_H=$(echo "$TOTAL_FPS_H + ${FPS_I:-0}" | bc)
    done
    AVG_FPS_H=$(echo "scale=2; $TOTAL_FPS_H / $INSTANCES" | bc)
    log "[H] Total FPS: ${TOTAL_FPS_H}, Avg per instance: ${AVG_FPS_H}"

    FPS_JSON_H=$(printf '%s\n' "${FPS_LIST_H[@]}" | jq -R . | jq -s .)
    cat > "${HDIR}/result.json" <<EOF
{
  "group": "H",
  "scenario": {
    "name": "内存带宽压测（4K x265 ultrafast）",
    "characteristics": ["4K分辨率", "x265 ultrafast预设", "ref=1 bframes=0", "${INSTANCES}路并发"],
    "cpu_pressure": {"level": "高", "desc": "ultrafast计算量约为medium的1/5~1/8，但多实例下CPU仍高负载"},
    "memory_pressure": {"level": "高", "desc": "禁用ME后内存带宽占比提升，是FFmpeg内最接近内存带宽受限的编码负载"},
    "expected": "对比B组：FPS约2.5x，内存带宽利用率约1.5x"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libx265",
    "preset": "ultrafast",
    "x265_params": "ref=1:bframes=0:pools=none",
    "threads_per_instance": ${THREADS},
    "instances": ${INSTANCES}
  },
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_H},
  "avg_fps_per_instance": ${AVG_FPS_H},
  "total_fps": ${TOTAL_FPS_H},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[H_cpu]},
  "iowait_pct": ${METRICS[H_iowait]},
  "mem_used_gb": ${METRICS[H_mem]},
  "membw_read_gbs": ${METRICS[H_bw]},
  "fps_per_instance": ${FPS_JSON_H}
}
EOF
    log "[H] Done. Result: ${HDIR}/result.json"
fi


# ────────────────────────────────────────────────────────────────
# 测试组 I：INSTANCES 并行实例，4K SVT-AV1 preset=10（AV1 编码基准）
#
# 背景：SVT-AV1（Scalable Video Technology for AV1）是 Intel/Netflix 联合开发的
#       高性能 AV1 编码器，支持多核并行。preset 范围 0（最慢/最优质）到 12（最快）。
#       preset 10 是速度/质量平衡点，单实例 4K 约 19-20 fps（1线程，EPYC 9755）。
#
# 与 x265 medium 对比（单实例 × 1线程）：
#   x265 medium   → 3.2 fps  （高压缩率，H.265格式，广泛兼容）
#   SVT-AV1 p10   → 19.5 fps （AV1格式，下一代编解码，压缩率更高约20-30%）
#   SVT-AV1 p8    → 9.1 fps  （对等质量基准，与 x265 medium 相近质量）
#
# 注意：本组通过 ffmpeg stdout pipe 向 SvtAv1EncApp 传递 raw YUV，
#       因为系统 ffmpeg 4.4 编译时未启用 --enable-libsvtav1。
#       这不影响编码性能测量（pipe 开销 <2%）。
#
# AV1 优势：
#   - 相同质量下码率比 H.265 低 20-30%，比 H.264 低 40-50%
#   - 完全开源免版权费
#   - Netflix/YouTube/Chrome 生产环境大规模使用
#
# 客户场景：流媒体平台 AV1 转码（YouTube/Netflix 同类工作负载）
# CPU压力：高（preset 10 单实例约 60-70% 单核利用率，多实例下全核满载）
# 内存压力：中（AV1 参考帧结构复杂，内存占用高于 x265）
# ────────────────────────────────────────────────────────────────
if should_run I && ! should_skip I; then
    SVT_PRESET="${SVT_PRESET:-10}"
    log_banner "I" "AV1 编码基准（4K SVT-AV1 preset=${SVT_PRESET}）" \
        "流媒体平台 AV1 转码（YouTube/Netflix 同类工作负载）" \
        "4K | SVT-AV1 preset=${SVT_PRESET} | lp=1 | ${INSTANCES}路并发 | numactl绑定" \
        "高" "多实例下 CPU 全核满载，AV1 计算量介于 x265 medium 和 ultrafast 之间" \
        "中" "AV1 参考帧结构复杂，内存占用高于 x265；带宽利用率约 10-15%" \
        "对比B组：SVT-AV1 p8 FPS 约 2.8x，p10 约 6x，p12 约 9x；AV1 压缩率高 20-30%"
    log "============================================"
    log " Group I: ${INSTANCES} parallel 4K SVT-AV1 preset=${SVT_PRESET}"
    log "============================================"
    IDIR="${OUTPUT_DIR}/groupI_parallel_svtav1_p${SVT_PRESET}"
    mkdir -p "$IDIR"

    # 自动检测编码路径：优先 ffmpeg libsvtav1（输出兼容 parse_fps），
    # 否则 fallback 到 ffmpeg pipe → SvtAv1EncApp（需要已安装 svt-av1 包）
    if ffmpeg -encoders 2>/dev/null | grep -q libsvtav1; then
        SVT_MODE="libsvtav1"
    elif command -v SvtAv1EncApp &>/dev/null; then
        SVT_MODE="pipe"
    else
        log "[I] ERROR: Neither ffmpeg libsvtav1 nor SvtAv1EncApp found."
        log "[I]   Option A: Use a ffmpeg built with --enable-libsvtav1"
        log "[I]   Option B: apt-get install svt-av1"
        log "[I] Skipping Group I."
        SVT_MODE="none"
    fi

    if [ "$SVT_MODE" != "none" ]; then
        log "[I] SVT encoder mode: ${SVT_MODE}"
        log "[I] Launching ${INSTANCES} instances (${DURATION}s, preset=${SVT_PRESET})..."
        FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "encode")
        VF_ARGS=$(build_vf_args "$TARGET_FPS" "encode")
        PIDS=()
        for i in $(seq 0 $((INSTANCES - 1))); do
            NODE=$(assign_numa_node "$i")
            if [ "$SVT_MODE" = "libsvtav1" ]; then
                numactl --cpunodebind=${NODE} --membind=${NODE} \
                    ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                        ${FPS_ARGS} \
                        -stream_loop -1 -i "${INPUT}" \
                        ${VF_ARGS} \
                        -t "${DURATION}" \
                        -c:v libsvtav1 -preset ${SVT_PRESET} \
                        -svtav1-params "lp=1" \
                        -f null - \
                        >> "${IDIR}/instance_${i}.log" 2>&1 &
            else
                # pipe 模式：ffmpeg raw → SvtAv1EncApp stdin
                numactl --cpunodebind=${NODE} --membind=${NODE} \
                    bash -c "ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                        ${FPS_ARGS} -stream_loop -1 -i \"${INPUT}\" \
                        ${VF_ARGS} \
                        -t \"${DURATION}\" -f rawvideo -pix_fmt yuv420p - 2>/dev/null | \
                    SvtAv1EncApp -i stdin -w 3840 -h 2160 \
                        --fps-num 30 --fps-denom 1 \
                        --preset ${SVT_PRESET} --lp 1 \
                        -n $((DURATION * 30)) -b /dev/null 2>&1" \
                        >> "${IDIR}/instance_${i}.log" 2>&1 &
            fi
            PIDS+=($!)
        done
        log "[I] All instances launched. PIDs: ${PIDS[*]}"
        log "[I] Waiting for completion..."

        START_I=$(date +%s)
        bash ${PROJ}/04_collect_metrics.sh \
            --output "${IDIR}/bandwidth.csv" \
            --interval 5 \
            --pids "${PIDS[*]}" &
        MONITOR_PID=$!

        wait "${PIDS[@]}"
        END_I=$(date +%s)
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        ELAPSED_I=$((END_I - START_I))
        log "[I] All instances completed in ${ELAPSED_I}s"
        summarize_metrics "${IDIR}/bandwidth.csv" "I"

        TOTAL_FPS_I=0
        FPS_LIST_I=()
        for i in $(seq 0 $((INSTANCES - 1))); do
            if [ "$SVT_MODE" = "libsvtav1" ]; then
                FPS_I=$(parse_fps "${IDIR}/instance_${i}.log")
            else
                # SvtAv1EncApp 输出格式：'Average Speed:   19.458 fps'
                FPS_I=$(grep -oP 'Average Speed:\s+\K[0-9.]+' "${IDIR}/instance_${i}.log" 2>/dev/null | tail -1)
            fi
            FPS_LIST_I+=("${FPS_I:-0}")
            TOTAL_FPS_I=$(echo "$TOTAL_FPS_I + ${FPS_I:-0}" | bc)
        done
        AVG_FPS_I=$(echo "scale=2; $TOTAL_FPS_I / $INSTANCES" | bc)
        log "[I] Total FPS: ${TOTAL_FPS_I}, Avg per instance: ${AVG_FPS_I}"

        FPS_JSON_I=$(printf '%s\n' "${FPS_LIST_I[@]}" | jq -R . | jq -s .)
        cat > "${IDIR}/result.json" <<EOF
{
  "group": "I",
  "scenario": {
    "name": "AV1 编码基准（4K SVT-AV1 preset=${SVT_PRESET}）",
    "characteristics": ["4K分辨率", "SVT-AV1 preset=${SVT_PRESET}", "lp=1", "${INSTANCES}路并发"],
    "cpu_pressure": {"level": "高", "desc": "多实例下 CPU 全核满载"},
    "memory_pressure": {"level": "中", "desc": "AV1 参考帧结构复杂，内存占用高于 x265"},
    "expected": "对比B组（x265 medium）：FPS 约 6x（preset 10），压缩率高 20-30%"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libsvtav1",
    "preset": ${SVT_PRESET},
    "lp": 1,
    "encode_method": "${SVT_MODE:+ffmpeg_libsvtav1_direct}${SVT_MODE:-ffmpeg_pipe_SvtAv1EncApp}",
    "threads_per_instance": ${THREADS},
    "instances": ${INSTANCES}
  },
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_I},
  "avg_fps_per_instance": ${AVG_FPS_I},
  "total_fps": ${TOTAL_FPS_I},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[I_cpu]},
  "iowait_pct": ${METRICS[I_iowait]},
  "mem_used_gb": ${METRICS[I_mem]},
  "membw_read_gbs": ${METRICS[I_bw]},
  "fps_per_instance": ${FPS_JSON_I}
}
EOF
        log "[I] Done. Result: ${IDIR}/result.json"
    fi
fi



# ────────────────────────────────────────────────────────────────
# 测试组 J：32 并行实例，4K SVT-AV1 preset=10（AV1 扩展基线）
#
# 目标：AV1 实例扩展曲线第 1 点（32 核）
# 固定 32 实例（不受 CCD 探测影响），对比 K/L/I 组形成完整扩展曲线。
# 预期：CPU ~12.5%，总 FPS ~245（7.65×32）
# ────────────────────────────────────────────────────────────────
if should_run J && ! should_skip J; then
    INST_J=32
    SVT_PRESET_J="${SVT_PRESET_J:-10}"
    log_banner "J" "AV1 扩展基线（32实例 × SVT-AV1 preset=${SVT_PRESET_J}）" \
        "AV1 实例扩展曲线第1点，与 K/L/I 组形成完整扩展曲线" \
        "4K | SVT-AV1 preset=${SVT_PRESET_J} | lp=1 | 32路并发 | numactl绑定" \
        "低" "32实例仅占用约12.5% CPU，扩展性测量基准点" \
        "低" "内存带宽与实例数线性正相关" \
        "对比 K(64)/L(128)/I(${INSTANCES}) 验证 AV1 线性扩展特性"
    log "============================================"
    log " Group J: ${INST_J} parallel 4K SVT-AV1 preset=${SVT_PRESET_J} (scaling baseline)"
    log "============================================"
    JDIR="${OUTPUT_DIR}/groupJ_svtav1_p${SVT_PRESET_J}_32x1t"
    mkdir -p "$JDIR"

    # 自动检测编码路径
    if ffmpeg -encoders 2>/dev/null | grep -q libsvtav1; then
        SVT_MODE_J="libsvtav1"
    elif command -v SvtAv1EncApp &>/dev/null; then
        SVT_MODE_J="pipe"
    else
        log "[J] ERROR: Neither ffmpeg libsvtav1 nor SvtAv1EncApp found. Skipping Group J."
        SVT_MODE_J="none"
    fi

    if [ "$SVT_MODE_J" != "none" ]; then
        log "[J] SVT encoder mode: ${SVT_MODE_J}"
        log "[J] Launching ${INST_J} instances (${DURATION}s, preset=${SVT_PRESET_J})..."
        FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "encode")
        VF_ARGS=$(build_vf_args "$TARGET_FPS" "encode")
        PIDS=()
        for i in $(seq 0 $((INST_J - 1))); do
            NODE=$(assign_numa_node "$i")
            if [ "$SVT_MODE_J" = "libsvtav1" ]; then
                numactl --cpunodebind=${NODE} --membind=${NODE} \
                    ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                        ${FPS_ARGS} \
                        -stream_loop -1 -i "${INPUT}" \
                        ${VF_ARGS} \
                        -t "${DURATION}" \
                        -c:v libsvtav1 -preset ${SVT_PRESET_J} \
                        -svtav1-params "lp=1" \
                        -f null - \
                        >> "${JDIR}/instance_${i}.log" 2>&1 &
            else
                numactl --cpunodebind=${NODE} --membind=${NODE} \
                    bash -c "ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                        ${FPS_ARGS} -stream_loop -1 -i \"${INPUT}\" \
                        ${VF_ARGS} \
                        -t \"${DURATION}\" -f rawvideo -pix_fmt yuv420p - 2>/dev/null | \
                    SvtAv1EncApp -i stdin -w 3840 -h 2160 \
                        --fps-num 30 --fps-denom 1 \
                        --preset ${SVT_PRESET_J} --lp 1 \
                        -n $((DURATION * 30)) -b /dev/null 2>&1" \
                        >> "${JDIR}/instance_${i}.log" 2>&1 &
            fi
            PIDS+=($!)
        done
        log "[J] All instances launched. PIDs: ${PIDS[*]}"
        log "[J] Waiting for completion..."

        START_J=$(date +%s)
        bash ${PROJ}/04_collect_metrics.sh \
            --output "${JDIR}/bandwidth.csv" \
            --interval 5 \
            --pids "${PIDS[*]}" &
        MONITOR_PID=$!

        wait "${PIDS[@]}" || log "[J] WARNING: One or more instances exited with error (possible OOM)"
        END_J=$(date +%s)
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        ELAPSED_J=$((END_J - START_J))
        log "[J] All instances completed in ${ELAPSED_J}s"
        summarize_metrics "${JDIR}/bandwidth.csv" "J"
        : "${METRICS[J_cpu]:=0}"; : "${METRICS[J_iowait]:=0}"
        : "${METRICS[J_mem]:=0}"; : "${METRICS[J_bw]:=0}"

        TOTAL_FPS_J=0
        FPS_LIST_J=()
        for i in $(seq 0 $((INST_J - 1))); do
            if [ "$SVT_MODE_J" = "libsvtav1" ]; then
                FPS_I=$(parse_fps "${JDIR}/instance_${i}.log")
            else
                FPS_I=$(grep -oP 'Average Speed:\s+\K[0-9.]+' "${JDIR}/instance_${i}.log" 2>/dev/null | tail -1)
            fi
            FPS_LIST_J+=("${FPS_I:-0}")
            TOTAL_FPS_J=$(echo "$TOTAL_FPS_J + ${FPS_I:-0}" | bc)
        done
        AVG_FPS_J=$(echo "scale=2; $TOTAL_FPS_J / $INST_J" | bc)
        log "[J] Total FPS: ${TOTAL_FPS_J}, Avg per instance: ${AVG_FPS_J}"

        FPS_JSON_J=$(printf '%s\n' "${FPS_LIST_J[@]}" | jq -R . | jq -s .)
        cat > "${JDIR}/result.json" <<EOF
{
  "group": "J",
  "scenario": {
    "name": "AV1 扩展基线（32实例 × SVT-AV1 preset=${SVT_PRESET_J}）",
    "characteristics": ["4K分辨率", "SVT-AV1 preset=${SVT_PRESET_J}", "lp=1", "32路并发"],
    "cpu_pressure": {"level": "低", "desc": "32实例仅占用约12.5% CPU，扩展性测量基准点"},
    "memory_pressure": {"level": "低", "desc": "内存带宽与实例数线性正相关"},
    "expected": "对比 K(64)/L(128)/I(${INSTANCES}) 验证 AV1 线性扩展特性"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libsvtav1",
    "preset": ${SVT_PRESET_J},
    "lp": 1,
    "encode_method": "${SVT_MODE_J}",
    "threads_per_instance": 1,
    "instances": ${INST_J}
  },
  "channels": ${CHANNELS},
  "instances": ${INST_J},
  "duration_s": ${ELAPSED_J},
  "avg_fps_per_instance": ${AVG_FPS_J},
  "total_fps": ${TOTAL_FPS_J},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[J_cpu]},
  "iowait_pct": ${METRICS[J_iowait]},
  "mem_used_gb": ${METRICS[J_mem]},
  "membw_read_gbs": ${METRICS[J_bw]},
  "fps_per_instance": ${FPS_JSON_J}
}
EOF
        log "[J] Done. Result: ${JDIR}/result.json"
    fi
fi

# ────────────────────────────────────────────────────────────────
# 测试组 K：64 并行实例，4K SVT-AV1 preset=10（AV1 扩展中段）
#
# 目标：AV1 实例扩展曲线第 2 点（64 核）
# 预期：CPU ~25%，总 FPS ~490
# ────────────────────────────────────────────────────────────────
if should_run K && ! should_skip K; then
    INST_K=64
    SVT_PRESET_K="${SVT_PRESET_K:-10}"
    log_banner "K" "AV1 扩展中段（64实例 × SVT-AV1 preset=${SVT_PRESET_K}）" \
        "AV1 实例扩展曲线第2点，验证线性扩展" \
        "4K | SVT-AV1 preset=${SVT_PRESET_K} | lp=1 | 64路并发 | numactl绑定" \
        "中低" "64实例约占25% CPU" \
        "低中" "内存带宽约为 J 组2倍" \
        "对比 J(32)/L(128)/I(${INSTANCES}) 验证 AV1 线性扩展"
    log "============================================"
    log " Group K: ${INST_K} parallel 4K SVT-AV1 preset=${SVT_PRESET_K}"
    log "============================================"
    KDIR="${OUTPUT_DIR}/groupK_svtav1_p${SVT_PRESET_K}_64x1t"
    mkdir -p "$KDIR"

    if ffmpeg -encoders 2>/dev/null | grep -q libsvtav1; then
        SVT_MODE_K="libsvtav1"
    elif command -v SvtAv1EncApp &>/dev/null; then
        SVT_MODE_K="pipe"
    else
        log "[K] ERROR: Neither ffmpeg libsvtav1 nor SvtAv1EncApp found. Skipping Group K."
        SVT_MODE_K="none"
    fi

    if [ "$SVT_MODE_K" != "none" ]; then
        log "[K] SVT encoder mode: ${SVT_MODE_K}"
        log "[K] Launching ${INST_K} instances (${DURATION}s, preset=${SVT_PRESET_K})..."
        FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "encode")
        VF_ARGS=$(build_vf_args "$TARGET_FPS" "encode")
        PIDS=()
        for i in $(seq 0 $((INST_K - 1))); do
            NODE=$(assign_numa_node "$i")
            if [ "$SVT_MODE_K" = "libsvtav1" ]; then
                numactl --cpunodebind=${NODE} --membind=${NODE} \
                    ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                        ${FPS_ARGS} \
                        -stream_loop -1 -i "${INPUT}" \
                        ${VF_ARGS} \
                        -t "${DURATION}" \
                        -c:v libsvtav1 -preset ${SVT_PRESET_K} \
                        -svtav1-params "lp=1" \
                        -f null - \
                        >> "${KDIR}/instance_${i}.log" 2>&1 &
            else
                numactl --cpunodebind=${NODE} --membind=${NODE} \
                    bash -c "ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                        ${FPS_ARGS} -stream_loop -1 -i \"${INPUT}\" \
                        ${VF_ARGS} \
                        -t \"${DURATION}\" -f rawvideo -pix_fmt yuv420p - 2>/dev/null | \
                    SvtAv1EncApp -i stdin -w 3840 -h 2160 \
                        --fps-num 30 --fps-denom 1 \
                        --preset ${SVT_PRESET_K} --lp 1 \
                        -n $((DURATION * 30)) -b /dev/null 2>&1" \
                        >> "${KDIR}/instance_${i}.log" 2>&1 &
            fi
            PIDS+=($!)
        done
        log "[K] All instances launched. PIDs: ${PIDS[*]}"
        log "[K] Waiting for completion..."

        START_K=$(date +%s)
        bash ${PROJ}/04_collect_metrics.sh \
            --output "${KDIR}/bandwidth.csv" \
            --interval 5 \
            --pids "${PIDS[*]}" &
        MONITOR_PID=$!

        wait "${PIDS[@]}" || log "[K] WARNING: One or more instances exited with error (possible OOM)"
        END_K=$(date +%s)
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        ELAPSED_K=$((END_K - START_K))
        log "[K] All instances completed in ${ELAPSED_K}s"
        summarize_metrics "${KDIR}/bandwidth.csv" "K"
        : "${METRICS[K_cpu]:=0}"; : "${METRICS[K_iowait]:=0}"
        : "${METRICS[K_mem]:=0}"; : "${METRICS[K_bw]:=0}"

        TOTAL_FPS_K=0
        FPS_LIST_K=()
        for i in $(seq 0 $((INST_K - 1))); do
            if [ "$SVT_MODE_K" = "libsvtav1" ]; then
                FPS_I=$(parse_fps "${KDIR}/instance_${i}.log")
            else
                FPS_I=$(grep -oP 'Average Speed:\s+\K[0-9.]+' "${KDIR}/instance_${i}.log" 2>/dev/null | tail -1)
            fi
            FPS_LIST_K+=("${FPS_I:-0}")
            TOTAL_FPS_K=$(echo "$TOTAL_FPS_K + ${FPS_I:-0}" | bc)
        done
        AVG_FPS_K=$(echo "scale=2; $TOTAL_FPS_K / $INST_K" | bc)
        log "[K] Total FPS: ${TOTAL_FPS_K}, Avg per instance: ${AVG_FPS_K}"

        FPS_JSON_K=$(printf '%s\n' "${FPS_LIST_K[@]}" | jq -R . | jq -s .)
        cat > "${KDIR}/result.json" <<EOF
{
  "group": "K",
  "scenario": {
    "name": "AV1 扩展中段（64实例 × SVT-AV1 preset=${SVT_PRESET_K}）",
    "characteristics": ["4K分辨率", "SVT-AV1 preset=${SVT_PRESET_K}", "lp=1", "64路并发"],
    "cpu_pressure": {"level": "中低", "desc": "64实例约占25% CPU"},
    "memory_pressure": {"level": "低中", "desc": "内存带宽约为 J 组2倍"},
    "expected": "对比 J(32)/L(128)/I(${INSTANCES}) 验证 AV1 线性扩展"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libsvtav1",
    "preset": ${SVT_PRESET_K},
    "lp": 1,
    "encode_method": "${SVT_MODE_K}",
    "threads_per_instance": 1,
    "instances": ${INST_K}
  },
  "channels": ${CHANNELS},
  "instances": ${INST_K},
  "duration_s": ${ELAPSED_K},
  "avg_fps_per_instance": ${AVG_FPS_K},
  "total_fps": ${TOTAL_FPS_K},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[K_cpu]},
  "iowait_pct": ${METRICS[K_iowait]},
  "mem_used_gb": ${METRICS[K_mem]},
  "membw_read_gbs": ${METRICS[K_bw]},
  "fps_per_instance": ${FPS_JSON_K}
}
EOF
        log "[K] Done. Result: ${KDIR}/result.json"
    fi
fi

# ────────────────────────────────────────────────────────────────
# 测试组 L：128 并行实例，4K SVT-AV1 preset=10（AV1 扩展高段）
#
# 目标：AV1 实例扩展曲线第 3 点（128 核）
# 预期：CPU ~50%，总 FPS ~985
# 注意：128 实例内存需求约 256GB，运行前预检
# ────────────────────────────────────────────────────────────────
if should_run L && ! should_skip L; then
    INST_L=128
    SVT_PRESET_L="${SVT_PRESET_L:-10}"
    log_banner "L" "AV1 扩展高段（128实例 × SVT-AV1 preset=${SVT_PRESET_L}）" \
        "AV1 实例扩展曲线第3点，验证高并发线性扩展" \
        "4K | SVT-AV1 preset=${SVT_PRESET_L} | lp=1 | 128路并发 | numactl绑定" \
        "中" "128实例约占50% CPU" \
        "中高" "AV1 参考帧占用较高，128实例内存压力显著" \
        "对比 J(32)/K(64)/I(${INSTANCES}) 验证 AV1 线性扩展到高并发"

    # 内存预检
    AVAIL_MEM_GB=$(awk '/MemAvailable/{print int($2/1024/1024)}' /proc/meminfo)
    REQUIRED_MEM_GB=$(( INST_L * 2 ))
    if [ "$AVAIL_MEM_GB" -lt "$REQUIRED_MEM_GB" ]; then
        log "[L] WARNING: Available ${AVAIL_MEM_GB}GB < estimated ${REQUIRED_MEM_GB}GB, OOM risk HIGH"
    else
        log "[L] Memory check OK: ${AVAIL_MEM_GB}GB available (need ~${REQUIRED_MEM_GB}GB)"
    fi

    log "============================================"
    log " Group L: ${INST_L} parallel 4K SVT-AV1 preset=${SVT_PRESET_L}"
    log "============================================"
    LDIR="${OUTPUT_DIR}/groupL_svtav1_p${SVT_PRESET_L}_128x1t"
    mkdir -p "$LDIR"

    if ffmpeg -encoders 2>/dev/null | grep -q libsvtav1; then
        SVT_MODE_L="libsvtav1"
    elif command -v SvtAv1EncApp &>/dev/null; then
        SVT_MODE_L="pipe"
    else
        log "[L] ERROR: Neither ffmpeg libsvtav1 nor SvtAv1EncApp found. Skipping Group L."
        SVT_MODE_L="none"
    fi

    if [ "$SVT_MODE_L" != "none" ]; then
        log "[L] SVT encoder mode: ${SVT_MODE_L}"
        log "[L] Launching ${INST_L} instances (${DURATION}s, preset=${SVT_PRESET_L})..."
        FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "encode")
        VF_ARGS=$(build_vf_args "$TARGET_FPS" "encode")
        PIDS=()
        for i in $(seq 0 $((INST_L - 1))); do
            NODE=$(assign_numa_node "$i")
            if [ "$SVT_MODE_L" = "libsvtav1" ]; then
                numactl --cpunodebind=${NODE} --membind=${NODE} \
                    ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                        ${FPS_ARGS} \
                        -stream_loop -1 -i "${INPUT}" \
                        ${VF_ARGS} \
                        -t "${DURATION}" \
                        -c:v libsvtav1 -preset ${SVT_PRESET_L} \
                        -svtav1-params "lp=1" \
                        -f null - \
                        >> "${LDIR}/instance_${i}.log" 2>&1 &
            else
                numactl --cpunodebind=${NODE} --membind=${NODE} \
                    bash -c "ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                        ${FPS_ARGS} -stream_loop -1 -i \"${INPUT}\" \
                        ${VF_ARGS} \
                        -t \"${DURATION}\" -f rawvideo -pix_fmt yuv420p - 2>/dev/null | \
                    SvtAv1EncApp -i stdin -w 3840 -h 2160 \
                        --fps-num 30 --fps-denom 1 \
                        --preset ${SVT_PRESET_L} --lp 1 \
                        -n $((DURATION * 30)) -b /dev/null 2>&1" \
                        >> "${LDIR}/instance_${i}.log" 2>&1 &
            fi
            PIDS+=($!)
        done
        log "[L] All instances launched. PIDs: ${PIDS[*]}"
        log "[L] Waiting for completion..."

        START_L=$(date +%s)
        bash ${PROJ}/04_collect_metrics.sh \
            --output "${LDIR}/bandwidth.csv" \
            --interval 5 \
            --pids "${PIDS[*]}" &
        MONITOR_PID=$!

        wait "${PIDS[@]}" || log "[L] WARNING: One or more instances exited with error (possible OOM)"
        END_L=$(date +%s)
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        ELAPSED_L=$((END_L - START_L))
        log "[L] All instances completed in ${ELAPSED_L}s"
        summarize_metrics "${LDIR}/bandwidth.csv" "L"
        : "${METRICS[L_cpu]:=0}"; : "${METRICS[L_iowait]:=0}"
        : "${METRICS[L_mem]:=0}"; : "${METRICS[L_bw]:=0}"

        TOTAL_FPS_L=0
        FPS_LIST_L=()
        for i in $(seq 0 $((INST_L - 1))); do
            if [ "$SVT_MODE_L" = "libsvtav1" ]; then
                FPS_I=$(parse_fps "${LDIR}/instance_${i}.log")
            else
                FPS_I=$(grep -oP 'Average Speed:\s+\K[0-9.]+' "${LDIR}/instance_${i}.log" 2>/dev/null | tail -1)
            fi
            FPS_LIST_L+=("${FPS_I:-0}")
            TOTAL_FPS_L=$(echo "$TOTAL_FPS_L + ${FPS_I:-0}" | bc)
        done
        AVG_FPS_L=$(echo "scale=2; $TOTAL_FPS_L / $INST_L" | bc)
        log "[L] Total FPS: ${TOTAL_FPS_L}, Avg per instance: ${AVG_FPS_L}"

        FPS_JSON_L=$(printf '%s\n' "${FPS_LIST_L[@]}" | jq -R . | jq -s .)
        cat > "${LDIR}/result.json" <<EOF
{
  "group": "L",
  "scenario": {
    "name": "AV1 扩展高段（128实例 × SVT-AV1 preset=${SVT_PRESET_L}）",
    "characteristics": ["4K分辨率", "SVT-AV1 preset=${SVT_PRESET_L}", "lp=1", "128路并发"],
    "cpu_pressure": {"level": "中", "desc": "128实例约占50% CPU"},
    "memory_pressure": {"level": "中高", "desc": "AV1 参考帧占用较高，128实例内存压力显著"},
    "expected": "对比 J(32)/K(64)/I(${INSTANCES}) 验证 AV1 线性扩展到高并发"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libsvtav1",
    "preset": ${SVT_PRESET_L},
    "lp": 1,
    "encode_method": "${SVT_MODE_L}",
    "threads_per_instance": 1,
    "instances": ${INST_L}
  },
  "channels": ${CHANNELS},
  "instances": ${INST_L},
  "duration_s": ${ELAPSED_L},
  "avg_fps_per_instance": ${AVG_FPS_L},
  "total_fps": ${TOTAL_FPS_L},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[L_cpu]},
  "iowait_pct": ${METRICS[L_iowait]},
  "mem_used_gb": ${METRICS[L_mem]},
  "membw_read_gbs": ${METRICS[L_bw]},
  "fps_per_instance": ${FPS_JSON_L}
}
EOF
        log "[L] Done. Result: ${LDIR}/result.json"
    fi
fi

# ────────────────────────────────────────────────────────────────
# 测试组 M：INSTANCES 并行实例，4K x265 fast（preset 梯度测试）
#
# 目标：填补 medium（~819 fps）→ ultrafast（~1960 fps）之间的 preset 空档
# 预期：CPU ~98%，总 FPS ~1100-1300
# ────────────────────────────────────────────────────────────────
if should_run M && ! should_skip M; then
    if [ "${INSTANCES}" -le 0 ]; then
        log "[M] INSTANCES=0, skipping."
    else
        log_banner "M" "preset 梯度（4K x265 fast ${INSTANCES}×1t）" \
            "填补 medium→ultrafast 之间的 preset 性能空档" \
            "4K | x265 fast | pools=none | ${INSTANCES}路并发 | numactl绑定" \
            "极高" "fast 计算量介于 medium 和 ultrafast 之间，CPU ~98%" \
            "高" "fast ref=2 减少参考帧，内存带宽需求低于 medium" \
            "对比 H(ultrafast)/B(medium)：fast FPS 约 1100-1300，填补性能梯度"
        log "============================================"
        log " Group M: ${INSTANCES} parallel 4K x265 fast (preset gradient)"
        log "============================================"
        MDIR="${OUTPUT_DIR}/groupM_x265_fast_${INSTANCES}x1t"
        mkdir -p "$MDIR"

        log "[M] Launching ${INSTANCES} ffmpeg instances x265 fast (${DURATION}s)..."
        FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "encode")
        VF_ARGS=$(build_vf_args "$TARGET_FPS" "encode")
        PIDS=()
        for i in $(seq 0 $((INSTANCES - 1))); do
            NODE=$(assign_numa_node "$i")
            numactl --cpunodebind=${NODE} --membind=${NODE} \
                ffmpeg -f rawvideo -video_size 3840x2160 -pix_fmt yuv420p \
                    ${FPS_ARGS} \
                    -stream_loop -1 -i "$INPUT" \
                    ${VF_ARGS} \
                    -t "$DURATION" \
                    -c:v libx265 -preset fast \
                    -x265-params "pools=none" \
                    -threads 1 \
                    -f null - \
                    >> "${MDIR}/instance_${i}.log" 2>&1 &
            PIDS+=($!)
        done
        log "[M] All instances launched. Waiting..."
        START_M=$(date +%s)
        bash ${PROJ}/04_collect_metrics.sh \
            --output "${MDIR}/bandwidth.csv" \
            --interval 5 \
            --pids "${PIDS[*]}" &
        MONITOR_PID=$!

        wait "${PIDS[@]}" || log "[M] WARNING: One or more instances exited with error (possible OOM)"
        END_M=$(date +%s)
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        ELAPSED_M=$((END_M - START_M))
        log "[M] All instances completed in ${ELAPSED_M}s"
        summarize_metrics "${MDIR}/bandwidth.csv" "M"
        : "${METRICS[M_cpu]:=0}"; : "${METRICS[M_iowait]:=0}"
        : "${METRICS[M_mem]:=0}"; : "${METRICS[M_bw]:=0}"

        TOTAL_FPS_M=0
        FPS_LIST_M=()
        for i in $(seq 0 $((INSTANCES - 1))); do
            FPS_I=$(parse_fps "${MDIR}/instance_${i}.log")
            FPS_LIST_M+=("${FPS_I:-0}")
            TOTAL_FPS_M=$(echo "$TOTAL_FPS_M + ${FPS_I:-0}" | bc)
        done
        AVG_FPS_M=$(echo "scale=2; $TOTAL_FPS_M / $INSTANCES" | bc)
        log "[M] Total FPS: ${TOTAL_FPS_M}, Avg per instance: ${AVG_FPS_M}"

        FPS_JSON_M=$(printf '%s\n' "${FPS_LIST_M[@]}" | jq -R . | jq -s .)
        cat > "${MDIR}/result.json" <<EOF
{
  "group": "M",
  "scenario": {
    "name": "preset 梯度（4K x265 fast ${INSTANCES}×1t）",
    "characteristics": ["4K分辨率", "x265 fast预设", "pools=none", "${INSTANCES}路并发"],
    "cpu_pressure": {"level": "极高", "desc": "fast 计算量介于 medium 和 ultrafast 之间，CPU ~98%"},
    "memory_pressure": {"level": "高", "desc": "fast ref=2 减少参考帧，内存带宽需求低于 medium"},
    "expected": "对比 H(ultrafast)/B(medium)：fast FPS 约 1100-1300，填补性能梯度"
  },
  "params": {
    "resolution": "3840x2160",
    "codec": "libx265",
    "preset": "fast",
    "x265_params": "pools=none",
    "encode_method": "libx265",
    "threads_per_instance": 1,
    "instances": ${INSTANCES}
  },
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_M},
  "avg_fps_per_instance": ${AVG_FPS_M},
  "total_fps": ${TOTAL_FPS_M},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[M_cpu]},
  "iowait_pct": ${METRICS[M_iowait]},
  "mem_used_gb": ${METRICS[M_mem]},
  "membw_read_gbs": ${METRICS[M_bw]},
  "fps_per_instance": ${FPS_JSON_M}
}
EOF
        log "[M] Done. Result: ${MDIR}/result.json"
    fi
fi

# ────────────────────────────────────────────────────────────────
# 测试组 N：INSTANCES 并行实例，1080p x265 medium（分辨率对比）
#
# 目标：从 4K→1080p，像素量降低4x，理论 FPS 提升约 4x
# 预期：CPU ~98%，总 FPS ~3200+
# ────────────────────────────────────────────────────────────────
if should_run N && ! should_skip N; then
    if [ "${INSTANCES}" -le 0 ]; then
        log "[N] INSTANCES=0, skipping."
    else
        log_banner "N" "分辨率对比（1080p x265 medium ${INSTANCES}×1t）" \
            "分辨率从4K降至1080p，像素量降低4x，对比内存带宽变化" \
            "1080p | x265 medium | pools=none | ${INSTANCES}路并发 | numactl绑定" \
            "极高" "medium 计算量 CPU ~98%，但 1080p 帧率约4x于 4K" \
            "低" "1080p working set ~5MB/实例，全部驻留 L3，几乎不访问 DRAM" \
            "对比 B组(4K medium)：FPS 约 4x，内存带宽反而下降，验证缓存命中提升"
        log "============================================"
        log " Group N: ${INSTANCES} parallel 1080p x265 medium (resolution comparison)"
        log "============================================"
        NDIR="${OUTPUT_DIR}/groupN_1080p_x265_medium_${INSTANCES}x1t"
        mkdir -p "$NDIR"

        # 生成或验证 1080p 输入文件
        INPUT_1080P="/dev/shm/input_1080p.yuv"
        EXPECTED_1080P_SIZE=$(( 1920 * 1080 * 3 / 2 * 10 * 30 ))
        ACTUAL_SIZE=$(stat -c%s "$INPUT_1080P" 2>/dev/null || echo 0)
        if [ "$ACTUAL_SIZE" -lt "$(( EXPECTED_1080P_SIZE * 9 / 10 ))" ]; then
            log "[N] Generating 1080p input (~$(( EXPECTED_1080P_SIZE / 1024 / 1024 ))MB)..."
            ffmpeg -f lavfi -i color=gray:s=1920x1080:r=30 \
                -t 10 -f rawvideo -pix_fmt yuv420p -y "$INPUT_1080P" 2>/dev/null
            log "[N] 1080p input ready: $(stat -c%s $INPUT_1080P) bytes"
        else
            log "[N] 1080p input exists: ${ACTUAL_SIZE} bytes"
        fi

        log "[N] Launching ${INSTANCES} ffmpeg instances 1080p x265 medium (${DURATION}s)..."
        FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "encode")
        VF_ARGS=$(build_vf_args "$TARGET_FPS" "encode")
        PIDS=()
        for i in $(seq 0 $((INSTANCES - 1))); do
            NODE=$(assign_numa_node "$i")
            numactl --cpunodebind=${NODE} --membind=${NODE} \
                ffmpeg -f rawvideo -video_size 1920x1080 -pix_fmt yuv420p \
                    ${FPS_ARGS} \
                    -stream_loop -1 -i "$INPUT_1080P" \
                    ${VF_ARGS} \
                    -t "$DURATION" \
                    -c:v libx265 -preset medium \
                    -x265-params "pools=none" \
                    -threads 1 \
                    -f null - \
                    >> "${NDIR}/instance_${i}.log" 2>&1 &
            PIDS+=($!)
        done
        log "[N] All instances launched. Waiting..."
        START_N=$(date +%s)
        bash ${PROJ}/04_collect_metrics.sh \
            --output "${NDIR}/bandwidth.csv" \
            --interval 5 \
            --pids "${PIDS[*]}" &
        MONITOR_PID=$!

        wait "${PIDS[@]}" || log "[N] WARNING: One or more instances exited with error (possible OOM)"
        END_N=$(date +%s)
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        ELAPSED_N=$((END_N - START_N))
        log "[N] All instances completed in ${ELAPSED_N}s"
        summarize_metrics "${NDIR}/bandwidth.csv" "N"
        : "${METRICS[N_cpu]:=0}"; : "${METRICS[N_iowait]:=0}"
        : "${METRICS[N_mem]:=0}"; : "${METRICS[N_bw]:=0}"

        TOTAL_FPS_N=0
        FPS_LIST_N=()
        for i in $(seq 0 $((INSTANCES - 1))); do
            FPS_I=$(parse_fps "${NDIR}/instance_${i}.log")
            FPS_LIST_N+=("${FPS_I:-0}")
            TOTAL_FPS_N=$(echo "$TOTAL_FPS_N + ${FPS_I:-0}" | bc)
        done
        AVG_FPS_N=$(echo "scale=2; $TOTAL_FPS_N / $INSTANCES" | bc)
        log "[N] Total FPS: ${TOTAL_FPS_N}, Avg per instance: ${AVG_FPS_N}"

        FPS_JSON_N=$(printf '%s\n' "${FPS_LIST_N[@]}" | jq -R . | jq -s .)
        cat > "${NDIR}/result.json" <<EOF
{
  "group": "N",
  "scenario": {
    "name": "分辨率对比（1080p x265 medium ${INSTANCES}×1t）",
    "characteristics": ["1080p分辨率", "x265 medium预设", "pools=none", "${INSTANCES}路并发"],
    "cpu_pressure": {"level": "极高", "desc": "medium 计算量 CPU ~98%，1080p 帧率约4x于 4K"},
    "memory_pressure": {"level": "低", "desc": "1080p working set ~5MB/实例，全部驻留 L3，几乎不访问 DRAM"},
    "expected": "对比 B组(4K medium)：FPS 约 4x，内存带宽反而下降，验证缓存命中提升"
  },
  "params": {
    "resolution": "1920x1080",
    "codec": "libx265",
    "preset": "medium",
    "x265_params": "pools=none",
    "encode_method": "libx265",
    "threads_per_instance": 1,
    "instances": ${INSTANCES}
  },
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_N},
  "avg_fps_per_instance": ${AVG_FPS_N},
  "total_fps": ${TOTAL_FPS_N},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[N_cpu]},
  "iowait_pct": ${METRICS[N_iowait]},
  "mem_used_gb": ${METRICS[N_mem]},
  "membw_read_gbs": ${METRICS[N_bw]},
  "fps_per_instance": ${FPS_JSON_N}
}
EOF
        log "[N] Done. Result: ${NDIR}/result.json"
    fi
fi

# ────────────────────────────────────────────────────────────────
# 测试组 O：INSTANCES 并行实例，1080p SVT-AV1 p10（AV1 分辨率对比）
#
# 目标：AV1 在 1080p 的吞吐量，与 Group N x265 对比
# 预期：CPU ~95%，总 FPS ~7000+
# ────────────────────────────────────────────────────────────────
if should_run O && ! should_skip O; then
    if [ "${INSTANCES}" -le 0 ]; then
        log "[O] INSTANCES=0, skipping."
    else
        SVT_PRESET_O="${SVT_PRESET_O:-10}"
        log_banner "O" "AV1 分辨率对比（1080p SVT-AV1 p${SVT_PRESET_O} ${INSTANCES}×1t）" \
            "验证 AV1 在 1080p 的吞吐量，与 N 组 x265 对比" \
            "1080p | SVT-AV1 preset=${SVT_PRESET_O} | lp=1 | ${INSTANCES}路并发 | numactl绑定" \
            "极高" "1080p AV1 CPU ~95%，帧率远高于 4K" \
            "低" "1080p working set 更小，DRAM 带宽压力低" \
            "对比 N组(x265 medium 1080p)：AV1 FPS 约 2-3x，压缩率高 20-30%"
        log "============================================"
        log " Group O: ${INSTANCES} parallel 1080p SVT-AV1 preset=${SVT_PRESET_O}"
        log "============================================"
        ODIR="${OUTPUT_DIR}/groupO_1080p_svtav1_p${SVT_PRESET_O}_${INSTANCES}x1t"
        mkdir -p "$ODIR"

        # 独立生成或验证 1080p 输入文件（O 组可能单独运行，不依赖 N 组）
        INPUT_1080P="/dev/shm/input_1080p.yuv"
        EXPECTED_1080P_SIZE=$(( 1920 * 1080 * 3 / 2 * 10 * 30 ))
        ACTUAL_SIZE=$(stat -c%s "$INPUT_1080P" 2>/dev/null || echo 0)
        if [ "$ACTUAL_SIZE" -lt "$(( EXPECTED_1080P_SIZE * 9 / 10 ))" ]; then
            log "[O] Generating 1080p input (~$(( EXPECTED_1080P_SIZE / 1024 / 1024 ))MB)..."
            ffmpeg -f lavfi -i color=gray:s=1920x1080:r=30 \
                -t 10 -f rawvideo -pix_fmt yuv420p -y "$INPUT_1080P" 2>/dev/null
            log "[O] 1080p input ready: $(stat -c%s $INPUT_1080P) bytes"
        else
            log "[O] 1080p input exists: ${ACTUAL_SIZE} bytes"
        fi

        if ffmpeg -encoders 2>/dev/null | grep -q libsvtav1; then
            SVT_MODE_O="libsvtav1"
        elif command -v SvtAv1EncApp &>/dev/null; then
            SVT_MODE_O="pipe"
        else
            log "[O] ERROR: Neither ffmpeg libsvtav1 nor SvtAv1EncApp found. Skipping Group O."
            SVT_MODE_O="none"
        fi

        if [ "$SVT_MODE_O" != "none" ]; then
            log "[O] SVT encoder mode: ${SVT_MODE_O}"
            log "[O] Launching ${INSTANCES} instances 1080p (${DURATION}s, preset=${SVT_PRESET_O})..."
            FPS_ARGS=$(build_fps_args "$TARGET_FPS" 30 "encode")
            VF_ARGS=$(build_vf_args "$TARGET_FPS" "encode")
            PIDS=()
            for i in $(seq 0 $((INSTANCES - 1))); do
                NODE=$(assign_numa_node "$i")
                if [ "$SVT_MODE_O" = "libsvtav1" ]; then
                    numactl --cpunodebind=${NODE} --membind=${NODE} \
                        ffmpeg -f rawvideo -video_size 1920x1080 -pix_fmt yuv420p \
                            ${FPS_ARGS} \
                            -stream_loop -1 -i "${INPUT_1080P}" \
                            ${VF_ARGS} \
                            -t "${DURATION}" \
                            -c:v libsvtav1 -preset ${SVT_PRESET_O} \
                            -svtav1-params "lp=1" \
                            -f null - \
                            >> "${ODIR}/instance_${i}.log" 2>&1 &
                else
                    numactl --cpunodebind=${NODE} --membind=${NODE} \
                        bash -c "ffmpeg -f rawvideo -video_size 1920x1080 -pix_fmt yuv420p \
                            ${FPS_ARGS} -stream_loop -1 -i \"${INPUT_1080P}\" \
                            ${VF_ARGS} \
                            -t \"${DURATION}\" -f rawvideo -pix_fmt yuv420p - 2>/dev/null | \
                        SvtAv1EncApp -i stdin -w 1920 -h 1080 \
                            --fps-num 30 --fps-denom 1 \
                            --preset ${SVT_PRESET_O} --lp 1 \
                            -n $((DURATION * 30)) -b /dev/null 2>&1" \
                            >> "${ODIR}/instance_${i}.log" 2>&1 &
                fi
                PIDS+=($!)
            done
            log "[O] All instances launched. PIDs: ${PIDS[*]}"
            log "[O] Waiting for completion..."

            START_O=$(date +%s)
            bash ${PROJ}/04_collect_metrics.sh \
                --output "${ODIR}/bandwidth.csv" \
                --interval 5 \
                --pids "${PIDS[*]}" &
            MONITOR_PID=$!

            wait "${PIDS[@]}" || log "[O] WARNING: One or more instances exited with error (possible OOM)"
            END_O=$(date +%s)
            kill "$MONITOR_PID" 2>/dev/null || true
            wait "$MONITOR_PID" 2>/dev/null || true
            ELAPSED_O=$((END_O - START_O))
            log "[O] All instances completed in ${ELAPSED_O}s"
            summarize_metrics "${ODIR}/bandwidth.csv" "O"
            : "${METRICS[O_cpu]:=0}"; : "${METRICS[O_iowait]:=0}"
            : "${METRICS[O_mem]:=0}"; : "${METRICS[O_bw]:=0}"

            TOTAL_FPS_O=0
            FPS_LIST_O=()
            for i in $(seq 0 $((INSTANCES - 1))); do
                if [ "$SVT_MODE_O" = "libsvtav1" ]; then
                    FPS_I=$(parse_fps "${ODIR}/instance_${i}.log")
                else
                    FPS_I=$(grep -oP 'Average Speed:\s+\K[0-9.]+' "${ODIR}/instance_${i}.log" 2>/dev/null | tail -1)
                fi
                FPS_LIST_O+=("${FPS_I:-0}")
                TOTAL_FPS_O=$(echo "$TOTAL_FPS_O + ${FPS_I:-0}" | bc)
            done
            AVG_FPS_O=$(echo "scale=2; $TOTAL_FPS_O / $INSTANCES" | bc)
            log "[O] Total FPS: ${TOTAL_FPS_O}, Avg per instance: ${AVG_FPS_O}"

            FPS_JSON_O=$(printf '%s\n' "${FPS_LIST_O[@]}" | jq -R . | jq -s .)
            cat > "${ODIR}/result.json" <<EOF
{
  "group": "O",
  "scenario": {
    "name": "AV1 分辨率对比（1080p SVT-AV1 p${SVT_PRESET_O} ${INSTANCES}×1t）",
    "characteristics": ["1080p分辨率", "SVT-AV1 preset=${SVT_PRESET_O}", "lp=1", "${INSTANCES}路并发"],
    "cpu_pressure": {"level": "极高", "desc": "1080p AV1 CPU ~95%，帧率远高于 4K"},
    "memory_pressure": {"level": "低", "desc": "1080p working set 更小，DRAM 带宽压力低"},
    "expected": "对比 N组(x265 medium 1080p)：AV1 FPS 约 2-3x，压缩率高 20-30%"
  },
  "params": {
    "resolution": "1920x1080",
    "codec": "libsvtav1",
    "preset": ${SVT_PRESET_O},
    "lp": 1,
    "encode_method": "${SVT_MODE_O}",
    "threads_per_instance": 1,
    "instances": ${INSTANCES}
  },
  "channels": ${CHANNELS},
  "instances": ${INSTANCES},
  "duration_s": ${ELAPSED_O},
  "avg_fps_per_instance": ${AVG_FPS_O},
  "total_fps": ${TOTAL_FPS_O},
  "target_fps": ${TARGET_FPS},
  "avg_cpu_pct": ${METRICS[O_cpu]},
  "iowait_pct": ${METRICS[O_iowait]},
  "mem_used_gb": ${METRICS[O_mem]},
  "membw_read_gbs": ${METRICS[O_bw]},
  "fps_per_instance": ${FPS_JSON_O}
}
EOF
            log "[O] Done. Result: ${ODIR}/result.json"
        fi
    fi
fi

# ── 汇总 ────────────────────────────────────────
log "============================================"
log " Benchmark Complete"
log " Results in: ${OUTPUT_DIR}"
log "============================================"
ls -la "${OUTPUT_DIR}/"
log "All done at $(date)"
