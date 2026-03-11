#!/bin/bash
# 实时采样 FFmpeg 进程的 IO 读取量和 CPU 使用率
# 用法: bash 04_collect_metrics.sh --output FILE --interval N --pids "PID1 PID2 ..."
# 按 Ctrl-C 或发送 SIGTERM 停止

OUTPUT="/tmp/bandwidth_metrics.csv"
INTERVAL=5
TARGET_PIDS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --output)   OUTPUT="$2";       shift 2 ;;
        --interval) INTERVAL="$2";     shift 2 ;;
        --pids)     TARGET_PIDS="$2";  shift 2 ;;
        *) shift ;;
    esac
done

echo "timestamp_unix,timestamp_human,pid_count,total_read_MB_per_s,total_write_MB_per_s,avg_cpu_pct,total_rchar_MB" > "$OUTPUT"

PREV_RCHAR=0
PREV_TIME=0

cleanup() {
    echo "[collect_metrics] Stopped at $(date '+%F %T')"
    exit 0
}
trap cleanup SIGTERM SIGINT

while true; do
    NOW=$(date +%s)
    NOW_HR=$(date '+%F %T')

    # 收集所有 ffmpeg 进程（或指定 PID）
    if [ -n "$TARGET_PIDS" ]; then
        PIDS_LIST="$TARGET_PIDS"
    else
        PIDS_LIST=$(pgrep -x ffmpeg 2>/dev/null | tr '\n' ' ')
    fi

    TOTAL_RCHAR=0
    TOTAL_WCHAR=0
    PID_COUNT=0
    CPU_SUM=0

    for PID in $PIDS_LIST; do
        IO_FILE="/proc/${PID}/io"
        STAT_FILE="/proc/${PID}/stat"
        [ -f "$IO_FILE" ] || continue

        RCHAR=$(grep '^rchar:' "$IO_FILE" 2>/dev/null | awk '{print $2}' || echo 0)
        WCHAR=$(grep '^wchar:' "$IO_FILE" 2>/dev/null | awk '{print $2}' || echo 0)
        TOTAL_RCHAR=$((TOTAL_RCHAR + RCHAR))
        TOTAL_WCHAR=$((TOTAL_WCHAR + WCHAR))

        # CPU from /proc/PID/stat (simple, no normalization)
        # Field 14=utime, 15=stime in jiffies
        if [ -f "$STAT_FILE" ]; then
            UTIME=$(awk '{print $14}' "$STAT_FILE" 2>/dev/null || echo 0)
            STIME=$(awk '{print $15}' "$STAT_FILE" 2>/dev/null || echo 0)
            CPU_SUM=$((CPU_SUM + UTIME + STIME))
        fi
        PID_COUNT=$((PID_COUNT + 1))
    done

    # Calculate bandwidth (MB/s)
    if [ "$PREV_TIME" -gt 0 ] && [ "$NOW" -gt "$PREV_TIME" ]; then
        DELTA_TIME=$((NOW - PREV_TIME))
        DELTA_RCHAR=$((TOTAL_RCHAR - PREV_RCHAR))
        READ_MBs=$(echo "scale=2; $DELTA_RCHAR / 1048576 / $DELTA_TIME" | bc 2>/dev/null || echo 0)
    else
        READ_MBs=0
    fi

    TOTAL_RCHAR_MB=$((TOTAL_RCHAR / 1048576))

    echo "${NOW},${NOW_HR},${PID_COUNT},${READ_MBs},0,0,${TOTAL_RCHAR_MB}" >> "$OUTPUT"

    PREV_RCHAR=$TOTAL_RCHAR
    PREV_TIME=$NOW

    sleep "$INTERVAL"
done
