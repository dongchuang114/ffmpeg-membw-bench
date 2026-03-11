# ffmpeg-membw-bench

AMD EPYC 服务器 FFmpeg 内存带宽基准测试工具。
通过 BIOS 禁用 DIMM 模拟不同内存通道数（2/4/8/12/16/24ch），测量 FFmpeg 转码性能变化，
为 AMD EPYC 服务器核存比优化提供数据支撑。

---

## 目录

- [背景与目标](#背景与目标)
- [测试用例设计](#测试用例设计)
- [硬件要求](#硬件要求)
- [快速开始](#快速开始)
- [完整操作步骤](#完整操作步骤)
- [报告查看（SSH 隧道）](#报告查看ssh-隧道)
- [多通道扫描（调整 BIOS）](#多通道扫描调整-bios)
- [脚本参数参考](#脚本参数参考)
- [输出目录结构](#输出目录结构)
- [故障排除](#故障排除)

---

## 背景与目标

**问题**：内存价格上涨，客户想知道：减少内存通道数（通过 BIOS 禁用 DIMM）后，
FFmpeg 转码性能会下降多少？什么样的核存比配置最具性价比？

**目标**：
1. 量化不同内存通道数下的 FFmpeg 转码 FPS
2. 找到"性能损失可接受"的最低内存配置（FPS 拐点）
3. 为 AMD EPYC 服务器提供最优核存比建议，提升竞争力

---

## 测试用例设计

### 为什么用 4K 分辨率（不用 1080p）

AMD EPYC 9T24 共有 24 个 CCD，每个 CCD 有 32MB L3，总计 768MB L3 缓存。

1080p 每帧仅 3MB，24 个实例的 working set 约 360MB，完全放入 768MB L3，
削减内存通道后 FPS 不变 → 1080p 测试无效。

4K 每帧 12MB，ref=5 参考帧的 working set 约 60MB/实例，超过单 CCD 的 32MB L3，
必须从 DRAM 加载参考帧 → 内存带宽成为真实瓶颈 → 测试有效。

### 为什么用 24 个并行实例

```
24 CCD x 8核/CCD x 2线程(SMT) = 384 线程（系统满载）
24 实例 x -threads 16 = 384 线程（完全匹配，无过载）
```

每个 ffmpeg 实例通过 numactl 绑定到对应 NUMA node，
前 12 实例绑 node0（socket0，cores 0-95），后 12 实例绑 node1（socket1，cores 96-191）。
这样消除跨 NUMA 调度噪声，让内存带宽影响更清晰地体现在 FPS 上。

### 五个测试组

| 组 | 实例数 | 配置 | 测试目的 |
|----|--------|------|----------|
| **A** | 1 | x265 medium ref=5 | **CPU 上限基准**：无内存竞争时单 CCD 能跑多少 FPS（基准线） |
| **B** | 24 | x265 medium ref=5 | **主测试**：满核满载，真实生产场景，内存带宽是否成瓶颈 |
| **C** | 24 | x265 slow | **高压力测试**：更大运动估计范围，更高内存带宽需求 |
| **D** | 24 | x264 medium | **编码器对比**：x264 vs x265 对内存带宽的敏感度差异 |
| **E** | 24 | 纯解码 | **读带宽极限**：纯读场景，找到 DRAM 读带宽饱和点 |

**如何看结果**：
- A 组 FPS × 24 = 理论 CPU 峰值（无内存限制时）
- B 组 FPS 接近理论峰值 → 内存带宽充足，可以减配
- B 组 FPS 明显低于理论峰值 → 内存带宽已是瓶颈，减配会影响性能
- 多通道对比中 B 组 FPS 的拐点 = 建议最低内存通道数

### 当前测试结果（24ch 满配，参考值）

| 组 | 总 FPS | 单实例平均 FPS | 说明 |
|----|--------|----------------|------|
| A（单实例） | 13.00 | 13.00 | 单 CCD 上限 |
| B（x265 medium） | 288.00 | 12.00 | 理论峰值 312，实际 288，带宽效率 92% |
| C（x265 slow） | 138.58 | 5.77 | slow 预设更耗内存带宽 |
| D（x264 medium） | 1028.40 | 42.85 | x264 带宽敏感度低，FPS 高 3x |
| E（纯解码） | 8187.00 | 341.12 | 读密集型，带宽利用率最高 |

---

## 硬件要求

| 项目 | 要求 |
|------|------|
| CPU | AMD EPYC 多核处理器（本工具为 EPYC 9T24 2P 设计） |
| 内存 | DDR5，建议满配 24-channel（测试不同减配场景） |
| /dev/shm | 至少 4GB 可用（存放 4K 测试素材） |
| FFmpeg | 4.4+，需带 libx264 和 libx265 |
| 工具 | numactl，bc，python3，screen，jq |

检查工具是否就绪：

```bash
ffmpeg -version 2>&1 | head -1
numactl --hardware
which bc jq screen python3
df -h /dev/shm
```

---

## 快速开始

```bash
# 1. 进入项目目录
cd /work/ffmpeg-membw-bench

# 2. 生成 4K 测试素材（约 2 分钟，服务器重启后需重新生成）
bash 00_prepare_input.sh

# 3. 跑完整测试（screen 后台，约 8-10 分钟）
screen -S bench -dm bash -c "bash 03_run_membw_bench.sh --channels 24 --duration 60 > /tmp/bench.log 2>&1"
tail -f /tmp/bench.log

# 4. 生成报告（替换 TIMESTAMP 为实际值）
python3 05_generate_report.py --mode single --result-dir results/24ch_TIMESTAMP

# 5. 启动 HTTP 服务
screen -S http -dm bash -c "cd /work/ffmpeg-membw-bench && python3 -m http.server 8085"
```

然后在笔记本建 SSH 隧道查看报告（见下方章节）。

---

## 完整操作步骤

### Step 1：SSH 登录测试服务器

```bash
ssh user@10.83.32.80
```

### Step 2：生成 4K 测试素材（仅需一次，重启后需重新生成）

```bash
bash /work/ffmpeg-membw-bench/00_prepare_input.sh
```

成功后输出：

```
[2025-06-05 23:05:00] Input ready: /dev/shm/input_4k_10s.yuv  3.5GB
```

素材存在 `/dev/shm`（内存文件系统），避免磁盘 IO 干扰测试结果。

### Step 3：运行测试（推荐 screen 后台）

```bash
# 启动后台测试（SSH 断线不中断）
screen -S bench24 -dm bash -c "bash /work/ffmpeg-membw-bench/03_run_membw_bench.sh --channels 24 --duration 60 > /tmp/bench24.log 2>&1"

# 查看实时进度
tail -f /tmp/bench24.log

# 挂载到 screen 交互查看（Ctrl+A D 退出但不停止）
screen -r bench24
```

进度示例：

```
[23:54:18]  Group A: Single instance x265 medium
[23:56:40] [A] Result: FPS=13.00, frames=1800, elapsed=142s
[23:56:40]  Group B: 24 parallel x265 medium (ref=5)
[23:59:13] [B] Total FPS: 288.00, Avg per instance: 12.00
[23:59:13]  Group C: 24 parallel x265 slow
...
```

完整测试（5 组 x 60s）约需 **8-10 分钟**。

仅快速验证 A 组（2 分钟）：

```bash
bash /work/ffmpeg-membw-bench/03_run_membw_bench.sh --channels 24 --group A --duration 30
```

### Step 4：生成报告

```bash
# 查看结果目录
ls /work/ffmpeg-membw-bench/results/

# 生成单通道报告（替换 TIMESTAMP）
python3 /work/ffmpeg-membw-bench/05_generate_report.py \
    --mode single \
    --result-dir /work/ffmpeg-membw-bench/results/24ch_TIMESTAMP

# 多通道对比报告（所有通道跑完后）
python3 /work/ffmpeg-membw-bench/05_generate_report.py \
    --mode multi \
    --results-dir /work/ffmpeg-membw-bench/results/
```

### Step 5：启动 HTTP 服务（一次性，保持运行）

```bash
screen -S membw-http -dm bash -c "cd /work/ffmpeg-membw-bench && python3 -m http.server 8085"

# 验证
ss -tlnp | grep 8085
```

---

## 报告查看（SSH 隧道）

服务器无显示器，通过 SSH 端口转发在笔记本浏览器查看。

### 第一步：在笔记本新开终端，建立 SSH 隧道

```bash
ssh -N -L 8085:10.83.32.80:8085 user@10.83.32.80
```

- `-N`：只建隧道，不执行命令
- `-L 8085:10.83.32.80:8085`：本地 8085 → 服务器 8085
- 终端会挂起，这是正常的（Ctrl+C 断开隧道）

### 第二步：笔记本浏览器打开

| 报告类型 | 浏览器地址 |
|----------|------------|
| 单通道报告 | `http://localhost:8085/results/24ch_TIMESTAMP/report.html` |
| 多通道对比报告 | `http://localhost:8085/results/multi_channel_comparison.html` |
| 文件浏览器 | `http://localhost:8085/` |

> 提示：页面空白时按 `Ctrl+Shift+R` 强制刷新。

---

## 多通道扫描（调整 BIOS）

每次调整 BIOS 禁用 DIMM 并重启服务器后，跑对应通道测试。

推荐顺序：24ch → 16ch → 12ch → 8ch → 4ch → 2ch

```bash
# 调整 BIOS 并重启后，重新生成素材（/dev/shm 会被清空）
bash /work/ffmpeg-membw-bench/00_prepare_input.sh

# 跑对应通道（改 --channels 值）
screen -S bench16 -dm bash -c "bash /work/ffmpeg-membw-bench/03_run_membw_bench.sh --channels 16 --duration 60 > /tmp/bench16.log 2>&1"

# 生成该通道报告
ls /work/ffmpeg-membw-bench/results/
python3 /work/ffmpeg-membw-bench/05_generate_report.py --mode single --result-dir results/16ch_TIMESTAMP
```

所有通道跑完后生成对比报告：

```bash
python3 /work/ffmpeg-membw-bench/05_generate_report.py --mode multi --results-dir results/
```

BIOS 操作路径（EPYC 9T24 参考）：

```
进入 BIOS -> Advanced -> Memory Configuration -> DIMM Disable
选择对应 DIMM 插槽 -> 设为 Disabled -> 保存重启
```

重启后验证：

```bash
numactl -H    # 查看每个 NUMA node 内存大小是否减少
free -h       # 确认总内存符合预期
```

---

## 脚本参数参考

### 03_run_membw_bench.sh

```
用法: bash 03_run_membw_bench.sh [选项]

必填:
  --channels N        当前 BIOS 配置的内存通道数（用于目录命名和报告标注）

可选:
  --duration N        每组持续时间（秒），默认 60
  --group X           只跑指定组（A/B/C/D/E），默认全部
  --output-dir DIR    指定输出目录（默认 results/Nch_TIMESTAMP）

示例:
  bash 03_run_membw_bench.sh --channels 24 --duration 60           # 完整测试
  bash 03_run_membw_bench.sh --channels 24 --group A --duration 30 # 仅 A 组验证
  bash 03_run_membw_bench.sh --channels 8 --duration 60            # 8 通道测试
```

### 05_generate_report.py

```
用法: python3 05_generate_report.py [选项]

  --mode single       生成单通道报告（需指定 --result-dir）
  --mode multi        生成多通道对比报告（扫描 --results-dir）
  --result-dir DIR    单通道模式：指定测试结果目录
  --results-dir DIR   多通道模式：扫描目录，默认 results/

示例:
  python3 05_generate_report.py --mode single --result-dir results/24ch_20250606_000000
  python3 05_generate_report.py --mode multi --results-dir results/
```

---

## 输出目录结构

```
/work/ffmpeg-membw-bench/
├── 00_prepare_input.sh         # 生成测试素材
├── 03_run_membw_bench.sh       # 主测试脚本
├── 04_collect_metrics.sh       # 实时带宽采样（主脚本自动调用）
├── 05_generate_report.py       # 报告生成
├── run_all_channels.sh         # 多通道交互驱动脚本
│
└── results/
    ├── 24ch_20250606_000000/           # 24 通道测试结果
    │   ├── groupA_single/
    │   │   ├── instance_0.log
    │   │   └── result.json
    │   ├── groupB_parallel_x265_medium/
    │   │   ├── instance_0.log ~ instance_23.log
    │   │   ├── bandwidth.csv           # 实时带宽采样
    │   │   └── result.json
    │   ├── groupC_parallel_x265_slow/
    │   ├── groupD_parallel_x264_medium/
    │   ├── groupE_parallel_decode/
    │   ├── bench_results.json          # 全局汇总
    │   └── report.html                 # 单通道 HTML 报告
    ├── 16ch_20250607_100000/           # 16 通道（调整 BIOS 后）
    └── multi_channel_comparison.html   # 多通道对比报告
```

---

## 故障排除

### 测试素材不存在

```bash
ls -lh /dev/shm/input_4k_10s.yuv   # 检查是否存在
bash 00_prepare_input.sh            # 重新生成（重启后需重跑）
```

### B 组 FPS 显示为 0

检查实例日志：

```bash
tail -5 results/24ch_TIMESTAMP/groupB_parallel_x265_medium/instance_0.log
```

日志为空通常是 ffmpeg 启动失败（输入文件不存在或权限问题）。

### HTTP 服务无法访问

```bash
# 服务器：检查服务状态
ss -tlnp | grep 8085

# 重启服务
screen -S membw-http -dm bash -c "cd /work/ffmpeg-membw-bench && python3 -m http.server 8085"

# 笔记本：重建隧道
ssh -N -L 8085:10.83.32.80:8085 user@10.83.32.80
```

### screen 会话中断

```bash
screen -ls         # 查看所有会话
screen -r bench24  # 挂载到 bench24 会话
```
