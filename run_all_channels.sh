#!/bin/bash
# 驱动脚本：依次提示用户调整 BIOS 通道数，然后运行基准测试
# 用法: bash run_all_channels.sh [--duration N] [--group G]
# 通道顺序: 24 → 16 → 12 → 8 → 4 → 2（从最大逐步减小）

PROJ=/work/ffmpeg-membw-bench
DURATION=60
GROUP="ALL"
INSTANCES=24
SKIP_GROUPS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --duration)    DURATION="$2";    shift 2 ;;
        --group)       GROUP="$2";       shift 2 ;;
        --instances)   INSTANCES="$2";   shift 2 ;;
        --skip-group)  SKIP_GROUPS="$SKIP_GROUPS --skip-group $2"; shift 2 ;;
        *) shift ;;
    esac
done

CHANNELS_LIST=(24 16 12 8 4 2)
LOGFILE="${PROJ}/results/run_all_$(date '+%Y%m%d_%H%M%S').log"
mkdir -p "${PROJ}/results"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }

log "=== FFmpeg Memory Bandwidth Multi-Channel Sweep ==="
log "Channel configs: ${CHANNELS_LIST[*]}"
log "Duration: ${DURATION}s, Group: ${GROUP}, Instances: ${INSTANCES}"
log ""

# 确认输入文件存在
if [ ! -f /dev/shm/input_4k_10s.yuv ]; then
    log "Input file not found. Running 00_prepare_input.sh first..."
    bash "${PROJ}/00_prepare_input.sh"
fi

for CH in "${CHANNELS_LIST[@]}"; do
    log "============================================"
    log " Next test: ${CH} memory channels"
    log "============================================"
    if [ "$CH" -ne "${CHANNELS_LIST[0]}" ]; then
        log ""
        log "ACTION REQUIRED: Please configure BIOS to enable ${CH} memory channels"
        log "Typical steps:"
        log "  1. Reboot into BIOS Setup"
        log "  2. Navigate to: Memory Configuration > Channel Configuration"
        log "  3. Disable DIMMs on channels beyond channel ${CH}"
        log "  4. Save and boot back to OS"
        log "  5. Verify with: dmidecode -t 17 | grep -c 'Size:.*GB'"
        log ""
        echo -n "Press ENTER when ready with ${CH}ch configuration (or 'skip' to skip): "
        read -r USER_INPUT
        if [ "$USER_INPUT" = "skip" ]; then
            log "Skipping ${CH}ch test."
            continue
        fi
    fi

    log "Starting ${CH}ch benchmark..."
    bash "${PROJ}/03_run_membw_bench.sh" \
        --channels "$CH" \
        --duration "$DURATION" \
        --group "$GROUP" \
        --instances "$INSTANCES" \
        $SKIP_GROUPS \
        2>&1 | tee -a "$LOGFILE"

    log "${CH}ch benchmark completed."
    log ""
done

log "=== All channel configurations tested ==="
log "Generating multi-channel comparison report..."
python3 "${PROJ}/05_generate_report.py" --mode multi --results-dir "${PROJ}/results" 2>&1 | tee -a "$LOGFILE"
log "Done."
