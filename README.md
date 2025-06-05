# FFmpeg Memory Bandwidth Benchmark — 操作手册

## 项目简介

本项目测试不同 CPU 平台在不同内存通道数配置下的 FFmpeg 转码吞吐量，
用于量化内存带宽对编码性能的影响，为核存比优化提供数据依据。

---

## 环境准备（每次重启后必须执行）

进入项目目录后，运行输入文件准备脚本：

    bash 00_prepare_input.sh

该脚本会生成 4K 测试素材到 /dev/shm/（内存盘，重启后消失）。

---

## 参数说明

    bash 03_run_membw_bench.sh [选项]

| 参数             | 说明                                                              | 默认值            |
|------------------|-------------------------------------------------------------------|-------------------|
| --group X        | 只跑指定测试组（A/B/C/D/E/F/G 或 ALL）                           | ALL               |
| --channels N     | 当前内存通道数（仅用于目录命名，不控制硬件）                      | 24                |
| --instances N    | 并发 FFmpeg 实例数                                                | 自动 = CCD 数     |
| --threads N      | 每实例线程数                                                      | 自动 = nproc/CCD  |
| --duration N     | 每路编码的视频时长（秒），不是运行时间                            | 60                |
| --output-dir PATH| 自定义输出目录（指定后覆盖 --channels 自动命名）                  | 自动按通道数命名  |

注意：--duration 60 表示每路编码 60 秒的视频内容，单线程下实际运行时间远超 60 秒。

---

## 测试组说明（A～G）

| 组 | 场景               | 分辨率 | 编码器         | 实例数  | 典型用途                       |
|----|--------------------|--------|----------------|---------|--------------------------------|
| A  | 单实例基准         | 4K     | x265 medium    | 1       | CPU 单路上限，理论峰值基准     |
| B  | 视频云并发转码     | 4K     | x265 medium    | CCD 数  | 核心对比组，最典型云转码场景   |
| C  | 视频归档（标准）   | 4K     | x265 slow      | CCD 数  | 慢预设，更耗内存带宽           |
| D  | 编码器对比         | 4K     | x264 medium    | CCD 数  | x264 带宽敏感度低，作为参照   |
| E  | CDN 回源（纯解码） | 4K     | decode only    | CCD 数  | 纯读密集，最高带宽利用率       |
| F  | 直播低延迟推流     | 1080p  | x265 ultrafast | CCD 数  | 低质量要求，最高吞吐           |
| G  | 视频归档（高质量） | 4K     | x265 slow ref=8| CCD 数  | 更高质量，带宽压力最大         |

---

## 场景一：同通道数，跑 A～G 全组，生成综合报告

适合第一次跑完整基线数据。

    # 1. 后台运行（24ch 为例）
    screen -S bench24 -dm bash -c "bash 03_run_membw_bench.sh --channels 24 --duration 60 > /tmp/bench24.log 2>&1"

    # 2. 查看进度
    tail -f /tmp/bench24.log

    # 3. 跑完后生成单通道综合报告（TIMESTAMP 替换为实际目录名，用 ls results/ 查看）
    python3 05_generate_report.py --mode single --result-dir results/24ch_TIMESTAMP

---

## 场景二：单独跑某个组（以 Group B 为例）

### 2.1 在不同通道数下分别跑 Group B

每次换 BIOS 通道配置并重启后，依次执行：

    # 24ch
    bash 03_run_membw_bench.sh --group B --channels 24 --duration 60

    # 换 BIOS 后 → 12ch
    bash 03_run_membw_bench.sh --group B --channels 12 --duration 60

    # 换 BIOS 后 → 8ch
    bash 03_run_membw_bench.sh --group B --channels 8 --duration 60

结果自动保存到对应目录：

    results/
    ├── 24ch_20250606_100000/groupB_parallel_x265_medium/result.json
    ├── 12ch_20250606_120000/groupB_parallel_x265_medium/result.json
    └── 8ch_20250606_140000/groupB_parallel_x265_medium/result.json

### 2.2 查看某个通道下 Group B 的独立报告

    python3 05_generate_report.py --mode single --result-dir results/24ch_TIMESTAMP
    # 报告输出到同目录下的 report.html

### 2.3 生成 Group B 跨通道对比报告

所有通道数跑完后，一条命令生成对比：

    python3 05_generate_report.py --mode multi --results-dir results/
    # 报告输出到 results/multi_channel_comparison.html

自动扫描 results/ 下所有 {N}ch_TIMESTAMP 目录，同通道多次测试只取最新一次。

---

## 远程查看报告（从笔记本浏览器访问）

**第一步：在测试服务器启动 HTTP 服务**（只需启动一次）

    screen -S http -dm bash -c "cd /work/ffmpeg-membw-bench && python3 -m http.server 8085"

**第二步：在笔记本建立 SSH 隧道**

    ssh -N -L 8085:10.83.32.80:8085 user@10.83.32.80

**第三步：浏览器打开**

| 报告类型         | 地址                                                        |
|------------------|-------------------------------------------------------------|
| 单通道综合报告   | http://localhost:8085/results/24ch_TIMESTAMP/report.html    |
| 跨通道对比报告   | http://localhost:8085/results/multi_channel_comparison.html |
