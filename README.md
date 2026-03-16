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
- [CCD 自动检测与实例数](#ccd-自动检测与实例数)
- [目标 FPS 模式（反向资源查询）](#目标-fps-模式反向资源查询)
- [结果 JSON 字段说明（v1.1）](#结果-json-字段说明v11)
- [输出目录结构](#输出目录结构)
- [故障排除](#故障排除)
- [版本历史](#版本历史)

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

### 为什么用 CCD 数量作为默认并行实例数

```
CCD 数量 x 8核/CCD x 2线程(SMT) = 系统最大线程数
实例数 = CCD 数量，每实例 -threads (8核x2SMT=16) → 线程数完全匹配，无过载
```

**v1.1 起**，脚本自动探测当前 CPU 的 CCD 数（通过 L3 cache 共享域），
以此作为默认并行实例数，无需手动维护。EPYC 9T24（24 CCD）默认 24 实例，
其他型号自动适配。

每个 ffmpeg 实例通过 numactl 按 round-robin 策略分配 NUMA 节点，
支持任意节点数（不再固定为 2 节点各半）。

每实例 `-threads` 数同样自动计算（`nproc ÷ CCD 数`），确保每实例恰好占满一个 CCD。
SMT 关闭时自动减半，无需手动调整。

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
# 1. 进入项目目录（根据实际路径调整）
cd /path/to/ffmpeg-membw-bench

# 2. 生成 4K 测试素材（约 2 分钟，服务器重启后需重新生成）
bash 00_prepare_input.sh

# 3. 跑完整测试（实例数和线程数自动按 CCD 探测，screen 后台，约 8-10 分钟）
screen -S bench -dm bash -c "bash $(pwd)/03_run_membw_bench.sh --channels 24 --duration 60 > /tmp/bench.log 2>&1"
tail -f /tmp/bench.log

# 4. 生成报告（替换 TIMESTAMP 为实际值）
python3 05_generate_report.py --mode single --result-dir results/24ch_TIMESTAMP

# 5. 启动 HTTP 服务
screen -S http -dm bash -c "cd $(pwd) && python3 -m http.server 8085"
```

然后在笔记本建 SSH 隧道查看报告（见下方章节）。

---

## 完整操作步骤

### Step 1：SSH 登录测试服务器

```bash
ssh <user>@<server-ip>
```

### Step 2：生成 4K 测试素材（仅需一次，重启后需重新生成）

```bash
cd /path/to/ffmpeg-membw-bench
bash 00_prepare_input.sh
```

成功后输出：

```
[2025-06-05 23:05:00] Input ready: /dev/shm/input_4k_10s.yuv  3.5GB
```

素材存在 `/dev/shm`（内存文件系统），避免磁盘 IO 干扰测试结果。

### Step 3：运行测试（推荐 screen 后台）

```bash
# 进入项目目录
cd /path/to/ffmpeg-membw-bench

# 启动后台测试（SSH 断线不中断）
# 实例数和线程数自动按 CCD 探测，无需手动指定
screen -S bench24 -dm bash -c "bash $(pwd)/03_run_membw_bench.sh --channels 24 --duration 60 > /tmp/bench24.log 2>&1"

# 查看实时进度
tail -f /tmp/bench24.log

# 挂载到 screen 交互查看（Ctrl+A D 退出但不停止）
screen -r bench24
```

进度示例：

```
[23:43:00] Auto-detected CCD count: 24, using INSTANCES=24
[23:43:00] Auto-detected threads per CCD: 16, using THREADS=16
[23:43:00] Detected NUMA nodes: 0 1 (count=2)
[23:54:18]  Group A: Single instance x265 medium
[23:56:40] [A] Result: FPS=13.00, frames=1800, elapsed=142s
[23:56:40]  Group B: 24 parallel x265 medium (ref=5)
[23:59:13] [B] Total FPS: 288.00, Avg per instance: 12.00
```

完整测试（A-G 全组 x 60s）约需 **8-10 分钟**。

仅快速验证 A 组（2 分钟）：

```bash
bash 03_run_membw_bench.sh --channels 24 --group A --duration 30
```

### Step 4：生成报告

```bash
# 查看结果目录
ls results/

# 生成单通道报告（替换 TIMESTAMP）
python3 05_generate_report.py \
    --mode single \
    --result-dir results/24ch_TIMESTAMP

# 多通道对比报告（所有通道跑完后）
python3 05_generate_report.py \
    --mode multi \
    --results-dir results/
```

### Step 5：启动 HTTP 服务（一次性，保持运行）

```bash
screen -S membw-http -dm bash -c "cd $(pwd) && python3 -m http.server 8085"

# 验证
ss -tlnp | grep 8085
```

---

## 报告查看（SSH 隧道）

服务器无显示器，通过 SSH 端口转发在笔记本浏览器查看。

### 第一步：在笔记本新开终端，建立 SSH 隧道

```bash
ssh -N -L 8085:<server-ip>:8085 <user>@<server-ip>
```

- `-N`：只建隧道，不执行命令
- `-L 8085:<server-ip>:8085`：本地 8085 → 服务器 8085
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
cd /path/to/ffmpeg-membw-bench

# 调整 BIOS 并重启后，重新生成素材（/dev/shm 会被清空）
bash 00_prepare_input.sh

# 跑对应通道（改 --channels 值，实例数和线程数仍自动探测）
screen -S bench16 -dm bash -c "bash $(pwd)/03_run_membw_bench.sh --channels 16 --duration 60 > /tmp/bench16.log 2>&1"

# 生成该通道报告
python3 05_generate_report.py --mode single --result-dir results/16ch_TIMESTAMP
```

所有通道跑完后生成对比报告：

```bash
python3 05_generate_report.py --mode multi --results-dir results/
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
  --group X           只跑指定组（A/B/C/D/E/F/G），默认全部
  --instances N       手动指定并行实例数（默认：自动探测 CCD 数量）
  --threads N         手动指定每实例 ffmpeg 线程数（默认：自动，= 总vCPU ÷ CCD数）
  --target-fps N      目标 FPS 限速（0=不限速，默认 0）
  --output-dir DIR    指定输出目录（默认 results/Nch_TIMESTAMP）
  --skip-group X      跳过某个测试组（可多次指定）

示例:
  # 完整测试（实例数和线程数自动按 CCD 探测）
  bash 03_run_membw_bench.sh --channels 24 --duration 60

  # 仅跑 A 组快速验证
  bash 03_run_membw_bench.sh --channels 24 --group A --duration 30

  # 手动指定实例数（覆盖 CCD 自动探测）
  bash 03_run_membw_bench.sh --channels 24 --instances 12

  # 手动指定线程数（如关闭 SMT 后每 CCD 只有 8 个物理核）
  bash 03_run_membw_bench.sh --channels 24 --threads 8

  # 目标 FPS 模式：测量 8fps 业务负载下的 CPU 和内存使用量
  bash 03_run_membw_bench.sh --channels 24 --target-fps 8 --group B

  # 8 通道减配测试
  bash 03_run_membw_bench.sh --channels 8 --duration 60
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

## CCD 自动检测与实例数

v1.1 起，默认实例数和每实例线程数均由系统 CCD 数量自动决定，无需手动维护。

**CCD 探测原理**：AMD EPYC 每个 CCD 独享一个 L3 cache slice。
通过统计 `/sys/devices/system/cpu/cpu*/cache/index3/shared_cpu_list`
的唯一 L3 共享域数量，得出全系统 CCD 数。

```bash
# 手动验证 CCD 探测结果
cut -d, -f1 /sys/devices/system/cpu/cpu*/cache/index3/shared_cpu_list \
  | sort -nu | wc -l
# EPYC 9T24 2P 预期输出：24
```

| CPU 型号 | CCD 数 | 默认实例数 | 默认 threads |
|----------|--------|-----------|-------------|
| EPYC 9T24 2P（SMT on） | 24 | 24 | 16 |
| EPYC 9T24 1P（SMT on） | 12 | 12 | 16 |
| EPYC 9374F 1P（SMT on） | 8 | 8 | 8 |
| EPYC 9T24 2P（SMT off） | 24 | 24 | 8 |

**线程数探测原理**：`threads = nproc ÷ ccd_count`（一个 CCD 内的全部 vCPU 数）。
这样每个 ffmpeg 实例恰好占满一个 CCD，不跨 CCD 竞争，SMT 利用率最优。

```bash
# 手动验证线程数计算
VCPUS=$(nproc)
CCDS=$(cut -d, -f1 /sys/devices/system/cpu/cpu*/cache/index3/shared_cpu_list | sort -nu | wc -l)
echo "threads_per_instance = $VCPUS / $CCDS = $((VCPUS / CCDS))"
# EPYC 9T24 2P SMT on 预期输出：threads_per_instance = 384 / 24 = 16
```

SMT 关闭时 `nproc` 减半，自动计算结果相应减半（如 192 ÷ 24 = 8），无需手动调整。

**NUMA 分配策略**：第 i 个实例分配到 `NUMA_NODES[i % numa_count]`，
替代原来硬编码的 node0/node1 各半，支持 1/2/4 等任意节点数。

若需覆盖自动探测值，使用：
- `--instances N`：手动指定并行实例数
- `--threads N`：手动指定每实例线程数

---

## 目标 FPS 模式（反向资源查询）

**使用场景**：已知业务目标 FPS（如客户要求每路 8fps），想知道在该负载下
CPU 利用率和内存带宽是多少，以确认减配方案是否可行。

```bash
# 示例：在 24ch 满配下，测量每路 8fps 的资源消耗
cd /path/to/ffmpeg-membw-bench
screen -S bench -dm bash -c "
  bash $(pwd)/03_run_membw_bench.sh \
    --channels 24 \
    --target-fps 8 \
    --group B \
    --duration 60 \
    > /tmp/bench_8fps.log 2>&1"
tail -f /tmp/bench_8fps.log
```

**实现原理**：通过 `-r N -re` 将 ffmpeg 输入帧率限制为 N fps，
使编码负载线性降低，CPU/内存读写量真实反映该 FPS 下的资源消耗。
解码组（Group E）不加 `-vf` 滤镜，保持测试语义。

**如何看结果**：
- `avg_cpu_pct`：该 FPS 下全系统 CPU 平均利用率（含 iowait）
- `iowait_pct`：CPU 等待 DRAM 响应的时间占比（内存带宽压力指示）
- `mem_used_gb`：测试期间平均内存占用（GB）
- `membw_read_gbs`：平均内存读带宽（GB/s）

```bash
# 查看 target-fps 模式结果
cat results/24ch_TIMESTAMP/groupB_parallel_x265_medium/result.json | python3 -m json.tool
```

示例输出（8fps 目标，24ch 满配）：
```json
{
  "target_fps": 8,
  "avg_fps_per_instance": 7.98,
  "avg_cpu_pct": 63.4,
  "iowait_pct": 8.2,
  "mem_used_gb": 38.1,
  "membw_read_gbs": 74.3
}
```

---

## 结果 JSON 字段说明（v1.1）

### meta.json 新增字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `ccd_count` | int | 自动探测的 CCD 数量 |
| `instances_auto` | bool | 实例数是否由 CCD 自动决定 |
| `threads_per_instance` | int | 每实例 ffmpeg `-threads` 值 |
| `threads_auto` | bool | 线程数是否由自动计算决定 |
| `numa_nodes` | int[] | 系统 NUMA 节点编号列表 |
| `numa_count` | int | NUMA 节点总数 |
| `target_fps` | int | 目标 FPS（0 = 不限速） |

### result.json 新增字段（各测试组）

| 字段 | 单位 | 说明 |
|------|------|------|
| `target_fps` | fps | 目标 FPS（继承自启动参数） |
| `avg_cpu_pct` | % | 测试期间全系统平均 CPU 利用率（含 iowait） |
| `iowait_pct` | % | CPU 等待 I/O（DRAM 响应）的时间占比 |
| `mem_used_gb` | GB | 测试期间平均内存使用量（MemTotal - MemAvailable） |
| `membw_read_gbs` | GB/s | 平均内存读带宽（由 /proc/PID/io rchar 计算） |

> 注：`membw_read_gbs` 基于进程 VFS 读取量，包含对 `/dev/shm`（tmpfs）的读取，
> 非硬件 PMC 直接测量值，用于相对对比，不代表绝对 DRAM 带宽。

---

## 输出目录结构

```
ffmpeg-membw-bench/
├── 00_prepare_input.sh         # 生成测试素材
├── 03_run_membw_bench.sh       # 主测试脚本
├── 04_collect_metrics.sh       # 实时 CPU/MEM/带宽采样（主脚本自动调用）
├── 05_generate_report.py       # 报告生成
├── run_all_channels.sh         # 多通道交互驱动脚本
├── CHANGELOG.md                # 版本变更记录
│
└── results/
    ├── 24ch_20250606_000000/           # 24 通道测试结果
    │   ├── groupA_single/
    │   │   ├── instance_0.log
    │   │   ├── bandwidth.csv           # CPU/MEM/带宽采样（v1.1 新增）
    │   │   └── result.json
    │   ├── groupB_parallel_x265_medium/
    │   │   ├── instance_0.log ~ instance_23.log
    │   │   ├── bandwidth.csv
    │   │   └── result.json
    │   ├── groupC_parallel_x265_slow/
    │   ├── groupD_parallel_x264_medium/
    │   ├── groupE_parallel_decode/
    │   ├── groupF_parallel_1080p_ultrafast/
    │   ├── groupG_parallel_x265_slow_ref8/
    │   ├── meta.json                   # 硬件/运行参数（含 ccd_count, threads_per_instance）
    │   └── report.html
    ├── 16ch_20250607_100000/
    └── multi_channel_comparison.html
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

# 重启服务（在项目目录下执行）
screen -S membw-http -dm bash -c "cd $(pwd) && python3 -m http.server 8085"

# 笔记本：重建隧道
ssh -N -L 8085:<server-ip>:8085 <user>@<server-ip>
```

### screen 会话中断

```bash
screen -ls         # 查看所有会话
screen -r bench24  # 挂载到 bench24 会话
```

### CCD 探测结果异常

```bash
# 手动验证
cut -d, -f1 /sys/devices/system/cpu/cpu*/cache/index3/shared_cpu_list | sort -nu | wc -l
lscpu | grep 'L3 cache'

# 若探测失败，手动指定
bash 03_run_membw_bench.sh --channels 24 --instances 24 --threads 16
```

---

## 版本历史

| 版本 | 日期 | 主要变更 |
|------|------|---------|
| v1.1.0 | 2025-03-16 | CCD/threads 自动探测、`--target-fps`、CPU/MEM 采样、NUMA round-robin |
| v1.0.0 | 2025-06-04 | 初始版本，A-G 测试组，24ch 基准数据 |
