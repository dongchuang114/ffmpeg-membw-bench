#!/bin/bash
# 生成 4K 10s 测试视频到 /dev/shm（避免磁盘 IO 瓶颈）
# 4K YUV420p 30fps 10s ≈ 3.5GB，需确保 /dev/shm 足够
set -e

INPUT=/dev/shm/input_4k_10s.yuv
LOGFILE=/work/ffmpeg-membw-bench/results/prepare_input.log

mkdir -p /work/ffmpeg-membw-bench/results
echo "[$(date '+%F %T')] Preparing 4K input file..." | tee -a "$LOGFILE"

if [ -f "$INPUT" ]; then
    SIZE=$(stat -c%s "$INPUT" 2>/dev/null || echo 0)
    EXPECTED=3732480000
    if [ "$SIZE" -ge "$EXPECTED" ]; then
        echo "[$(date '+%F %T')] Input already exists and size OK: $(ls -lh $INPUT)" | tee -a "$LOGFILE"
        exit 0
    else
        echo "[$(date '+%F %T')] Existing file size mismatch ($SIZE vs $EXPECTED), regenerating..." | tee -a "$LOGFILE"
        rm -f "$INPUT"
    fi
fi

# Check /dev/shm free space (need ~4GB)
AVAIL_KB=$(df /dev/shm | awk 'NR==2 {print $4}')
AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
if [ "$AVAIL_GB" -lt 4 ]; then
    echo "[$(date '+%F %T')] ERROR: /dev/shm only ${AVAIL_GB}GB available, need at least 4GB" | tee -a "$LOGFILE"
    exit 1
fi
echo "[$(date '+%F %T')] /dev/shm available: ${AVAIL_GB}GB" | tee -a "$LOGFILE"

echo "[$(date '+%F %T')] Generating 4K YUV420p 30fps 10s test video..." | tee -a "$LOGFILE"
time ffmpeg -f lavfi -i testsrc2=size=3840x2160:rate=30 \
    -t 10 \
    -pix_fmt yuv420p \
    -y "$INPUT" 2>&1 | tee -a "$LOGFILE"

echo "[$(date '+%F %T')] Input ready:" | tee -a "$LOGFILE"
ls -lh "$INPUT" | tee -a "$LOGFILE"
echo "[$(date '+%F %T')] /dev/shm usage after prepare:" | tee -a "$LOGFILE"
df -h /dev/shm | tee -a "$LOGFILE"
