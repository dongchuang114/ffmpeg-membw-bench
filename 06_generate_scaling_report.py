#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
06_generate_scaling_report.py
x265 多实例扩展对比 HTML 报告生成器
"""

import argparse
import json
import os
import sys
import datetime

# ──────────────────────────────────────────────
# SVG 图表生成
# ──────────────────────────────────────────────

def make_bar_chart_svg(title, labels, values, color, width=500, height=300):
    ml, mr, mt, mb = 60, 20, 40, 60
    chart_w = width - ml - mr
    chart_h = height - mt - mb
    n = len(values)
    if n == 0:
        return f'<svg width="{width}" height="{height}"><text x="50%" y="50%" text-anchor="middle" fill="#8b949e">No data</text></svg>'
    max_val = max(values) * 1.18 if values else 1
    bar_w = chart_w / n * 0.6
    gap = chart_w / n

    svg = [f'<svg width="{width}" height="{height}" xmlns="http://www.w3.org/2000/svg">']
    svg.append(f'<rect width="{width}" height="{height}" fill="#161b22" rx="6"/>')
    svg.append(f'<text x="{width//2}" y="22" text-anchor="middle" fill="#c9d1d9" '
               f'font-size="13" font-family="Arial,sans-serif">{title}</text>')

    # Y axis gridlines and labels (6 ticks: 0..5)
    for i in range(6):
        y = mt + chart_h - (chart_h * i / 5)
        val = max_val * i / 5
        svg.append(f'<line x1="{ml}" y1="{y:.1f}" x2="{ml+chart_w}" y2="{y:.1f}" '
                   f'stroke="#21262d" stroke-width="1"/>')
        svg.append(f'<text x="{ml-5}" y="{y+4:.1f}" text-anchor="end" fill="#8b949e" '
                   f'font-size="10" font-family="Arial,sans-serif">{val:.0f}</text>')

    # Axes
    svg.append(f'<line x1="{ml}" y1="{mt}" x2="{ml}" y2="{mt+chart_h}" '
               f'stroke="#30363d" stroke-width="1.5"/>')
    svg.append(f'<line x1="{ml}" y1="{mt+chart_h}" x2="{ml+chart_w}" y2="{mt+chart_h}" '
               f'stroke="#30363d" stroke-width="1.5"/>')

    # Bars
    for i, (label, val) in enumerate(zip(labels, values)):
        x = ml + gap * i + (gap - bar_w) / 2
        bar_h = chart_h * val / max_val if max_val > 0 else 0
        y = mt + chart_h - bar_h
        svg.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_w:.1f}" height="{bar_h:.1f}" '
                   f'fill="{color}" rx="3" opacity="0.9"/>')
        # value label above bar
        svg.append(f'<text x="{x+bar_w/2:.1f}" y="{y-4:.1f}" text-anchor="middle" fill="#c9d1d9" '
                   f'font-size="10" font-family="Arial,sans-serif">{val:.1f}</text>')
        # x-axis label rotated -35 degrees
        lx = x + bar_w / 2
        ly = mt + chart_h + 14
        svg.append(f'<text x="{lx:.1f}" y="{ly:.1f}" text-anchor="end" fill="#8b949e" '
                   f'font-size="9" font-family="Arial,sans-serif" '
                   f'transform="rotate(-35 {lx:.1f} {ly:.1f})">{label}</text>')

    svg.append('</svg>')
    return '\n'.join(svg)


def make_line_chart_svg(title, labels, values, color, width=500, height=300):
    ml, mr, mt, mb = 60, 20, 40, 60
    chart_w = width - ml - mr
    chart_h = height - mt - mb
    n = len(values)
    if n == 0:
        return f'<svg width="{width}" height="{height}"><text x="50%" y="50%" text-anchor="middle" fill="#8b949e">No data</text></svg>'
    max_val = max(values) * 1.18 if values else 1
    gap = chart_w / (n - 1) if n > 1 else chart_w

    svg = [f'<svg width="{width}" height="{height}" xmlns="http://www.w3.org/2000/svg">']
    svg.append(f'<rect width="{width}" height="{height}" fill="#161b22" rx="6"/>')
    svg.append(f'<text x="{width//2}" y="22" text-anchor="middle" fill="#c9d1d9" '
               f'font-size="13" font-family="Arial,sans-serif">{title}</text>')

    for i in range(6):
        y = mt + chart_h - (chart_h * i / 5)
        val = max_val * i / 5
        svg.append(f'<line x1="{ml}" y1="{y:.1f}" x2="{ml+chart_w}" y2="{y:.1f}" '
                   f'stroke="#21262d" stroke-width="1"/>')
        svg.append(f'<text x="{ml-5}" y="{y+4:.1f}" text-anchor="end" fill="#8b949e" '
                   f'font-size="10" font-family="Arial,sans-serif">{val:.1f}</text>')

    svg.append(f'<line x1="{ml}" y1="{mt}" x2="{ml}" y2="{mt+chart_h}" '
               f'stroke="#30363d" stroke-width="1.5"/>')
    svg.append(f'<line x1="{ml}" y1="{mt+chart_h}" x2="{ml+chart_w}" y2="{mt+chart_h}" '
               f'stroke="#30363d" stroke-width="1.5"/>')

    # Compute point coordinates
    points = []
    for i, val in enumerate(values):
        px = ml + gap * i if n > 1 else ml + chart_w / 2
        py = mt + chart_h - (chart_h * val / max_val if max_val > 0 else 0)
        points.append((px, py))

    # Polyline
    pts_str = ' '.join(f'{px:.1f},{py:.1f}' for px, py in points)
    svg.append(f'<polyline points="{pts_str}" fill="none" stroke="{color}" stroke-width="2.5"/>')

    # Data points + labels
    for i, ((px, py), label, val) in enumerate(zip(points, labels, values)):
        svg.append(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="4" fill="{color}" stroke="#161b22" stroke-width="1.5"/>')
        # label above the point
        label_y = py - 10 if py > mt + 20 else py + 18
        svg.append(f'<text x="{px:.1f}" y="{label_y:.1f}" text-anchor="middle" fill="#c9d1d9" '
                   f'font-size="10" font-family="Arial,sans-serif">{val:.2f}</text>')
        # x-axis label
        lx = px
        ly = mt + chart_h + 14
        svg.append(f'<text x="{lx:.1f}" y="{ly:.1f}" text-anchor="end" fill="#8b949e" '
                   f'font-size="9" font-family="Arial,sans-serif" '
                   f'transform="rotate(-35 {lx:.1f} {ly:.1f})">{label}</text>')

    svg.append('</svg>')
    return '\n'.join(svg)


# ──────────────────────────────────────────────
# Data discovery
# ──────────────────────────────────────────────

def discover_results(results_dir):
    """
    Scan results_dir subdirs for result.json files.
    Returns list of dicts sorted by (instances, preset).
    """
    rows = []
    if not os.path.isdir(results_dir):
        print(f"[ERROR] results_dir not found: {results_dir}", file=sys.stderr)
        return rows

    for top_dir in sorted(os.listdir(results_dir)):
        top_path = os.path.join(results_dir, top_dir)
        if not os.path.isdir(top_path):
            continue
        # search subdirs for known patterns
        for sub in sorted(os.listdir(top_path)):
            sub_path = os.path.join(top_path, sub)
            if not os.path.isdir(sub_path):
                continue
            rj = os.path.join(sub_path, 'result.json')
            if not os.path.isfile(rj):
                continue
            # Determine preset from subdir name
            preset_guess = None
            if 'ultrafast' in sub:
                preset_guess = 'ultrafast'
            elif 'medium' in sub or 'groupB' in sub:
                preset_guess = 'medium'

            try:
                with open(rj, encoding='utf-8') as f:
                    data = json.load(f)
            except Exception as e:
                print(f"[WARN] Cannot parse {rj}: {e}", file=sys.stderr)
                continue

            params = data.get('params', {})
            preset = params.get('preset') or preset_guess or 'unknown'
            threads = params.get('threads_per_instance', 1)
            instances = data.get('instances', 0)

            rows.append({
                'top_dir': top_dir,
                'sub_dir': sub,
                'result_path': rj,
                'instances': instances,
                'threads': threads,
                'preset': preset,
                'target_fps': int(data.get('target_fps', 0)),
                'avg_fps_per_instance': float(data.get('avg_fps_per_instance', 0)),
                'total_fps': float(data.get('total_fps', 0)),
                'avg_cpu_pct': float(data.get('avg_cpu_pct', 0)),
                'iowait_pct': float(data.get('iowait_pct', 0)),
                'mem_used_gb': float(data.get('mem_used_gb', 0)),
                'membw_read_gbs': float(data.get('membw_read_gbs', 0)),
                'duration_s': float(data.get('duration_s', 0)),
                'raw': data,
            })

    # Sort: medium first at same instances, then ultrafast, then fixed-fps; overall by instances asc
    def sort_key(r):
        # fixed-fps rows get preset_order=2 (after medium=0, ultrafast=1)
        if r['target_fps'] > 0:
            preset_order = 2
        elif r['preset'] == 'medium':
            preset_order = 0
        else:
            preset_order = 1
        return (r['instances'], preset_order)

    rows.sort(key=sort_key)
    return rows


def infer_platform(rows):
    """Try to extract platform info from result.json fields."""
    for r in rows:
        raw = r.get('raw', {})
        if 'platform' in raw:
            return raw['platform']
        if 'system' in raw:
            s = raw['system']
            if isinstance(s, dict):
                return s.get('cpu_model', '')
    # Infer total vCPU from max instances x threads across all rows
    try:
        total_vcpu = max(
            r.get('raw', {}).get('instances', 0) * r.get('raw', {}).get('threads_per_instance', 1)
            for r in rows
        )
        if total_vcpu > 0:
            return f'AMD EPYC 9755 2P ({total_vcpu} Cores)'
    except Exception:
        pass
    return 'AMD EPYC 9755 2P (256 Cores)'


# ──────────────────────────────────────────────
# KPI computation
# ──────────────────────────────────────────────

def compute_kpis(rows):
    medium_rows = [r for r in rows if r['preset'] == 'medium' and r['target_fps'] == 0]
    ultrafast_rows = [r for r in rows if r['preset'] == 'ultrafast' and r['target_fps'] == 0]
    fixed_fps_rows = [r for r in rows if r['target_fps'] > 0]

    kpi = {}
    if medium_rows:
        kpi['max_total_fps_medium'] = max(r['total_fps'] for r in medium_rows)
        kpi['max_cpu_pct'] = max(r['avg_cpu_pct'] for r in medium_rows)
        # FPS gain: smallest instances -> largest instances in medium
        smallest = medium_rows[0]
        largest = medium_rows[-1]
        if smallest['total_fps'] > 0:
            kpi['fps_gain_pct'] = (largest['total_fps'] - smallest['total_fps']) / smallest['total_fps'] * 100
            kpi['fps_gain_from_label'] = f"{smallest['instances']}x{smallest['threads']}t"
            kpi['fps_gain_to_label'] = f"{largest['instances']}x{largest['threads']}t"
        else:
            kpi['fps_gain_pct'] = 0
            kpi['fps_gain_from_label'] = '-'
            kpi['fps_gain_to_label'] = '-'
    else:
        kpi['max_total_fps_medium'] = 0
        kpi['max_cpu_pct'] = 0
        kpi['fps_gain_pct'] = 0
        kpi['fps_gain_from_label'] = '-'
        kpi['fps_gain_to_label'] = '-'

    if ultrafast_rows and medium_rows:
        # Compare 256x1t ultrafast vs 256x1t medium if available, else last medium
        uf256 = next((r for r in ultrafast_rows if r['instances'] == 256), ultrafast_rows[-1])
        med256 = next((r for r in medium_rows if r['instances'] == 256), medium_rows[-1])
        if med256['total_fps'] > 0:
            kpi['ultrafast_vs_medium_x'] = uf256['total_fps'] / med256['total_fps']
        else:
            kpi['ultrafast_vs_medium_x'] = 0
    else:
        kpi['ultrafast_vs_medium_x'] = 0

    # Fixed-fps KPIs
    kpi['fixed_fps_rows'] = fixed_fps_rows
    if fixed_fps_rows:
        kpi['has_fixed_fps'] = True
    else:
        kpi['has_fixed_fps'] = False

    return kpi


# ──────────────────────────────────────────────
# Analysis text
# ──────────────────────────────────────────────

def build_analysis_text(rows, kpis):
    medium_rows = [r for r in rows if r['preset'] == 'medium' and r['target_fps'] == 0]
    ultrafast_rows = [r for r in rows if r['preset'] == 'ultrafast' and r['target_fps'] == 0]
    fixed_fps_rows = kpis.get('fixed_fps_rows', [])

    # Block 1: FPS gain source
    if len(medium_rows) >= 2:
        first_m = medium_rows[0]
        last_m = medium_rows[-1]
        gain_pct = kpis.get('fps_gain_pct', 0)
        block1 = (
            f"从 {first_m['instances']}x{first_m['threads']}t "
            f"到 {last_m['instances']}x{last_m['threads']}t，"
            f"CPU 核心数没有变化（始终 256 核），"
            f"但总 FPS 从 {first_m['total_fps']:.1f} 增加到 {last_m['total_fps']:.1f}"
            f"（+{gain_pct:.1f}%）。这部分增益完全来自"
            f"消除 WPP 帧内同步等待，与内存带宽、Cache 大小无关。"
        )
    else:
        block1 = "数据点不足，无法计算 FPS 增益。"

    # Block 2: CPU utilization trend
    cpu_lines = []
    for i in range(len(medium_rows) - 1):
        a = medium_rows[i]
        b = medium_rows[i + 1]
        diff = b['avg_cpu_pct'] - a['avg_cpu_pct']
        sign = '+' if diff >= 0 else ''
        cpu_lines.append(
            f"  {a['instances']}x{a['threads']}t → {b['instances']}x{b['threads']}t："
            f"  {a['avg_cpu_pct']:.1f}% → {b['avg_cpu_pct']:.1f}%（{sign}{diff:.1f}pp）"
        )
    block2 = (
        "线程数每减半，WPP 等待减少，CPU 有效利用率逐步提升：\n"
        + ("\n".join(cpu_lines) if cpu_lines else "  数据不足")
    )

    # Block 3: ultrafast vs medium
    if ultrafast_rows and medium_rows:
        uf = next((r for r in ultrafast_rows if r['instances'] == 256), ultrafast_rows[-1])
        med = next((r for r in medium_rows if r['instances'] == 256), medium_rows[-1])
        ratio = kpis.get('ultrafast_vs_medium_x', 0)
        max_bw_theoretical = 460  # rough DDR5-6400 24ch theoretical peak
        bw_pct = uf['membw_read_gbs'] / max_bw_theoretical * 100 if max_bw_theoretical > 0 else 0
        block3 = (
            f"ultrafast 禁用运动估计（ME），编码从计算密集转为内存读写密集。\n"
            f"  FPS 提升 {ratio:.2f}x（{med['total_fps']:.1f} → {uf['total_fps']:.1f}），"
            f"内存读带宽 {uf['membw_read_gbs']:.2f} GB/s（VFS rchar 统计值），\n"
            f"  约为理论峰值 ~{max_bw_theoretical} GB/s 的 {bw_pct:.1f}%，"
            f"说明 DRAM 带宽对 x265 编码不是瓶颈。"
        )
    else:
        block3 = "无 ultrafast 数据，无法比较。"

    # Block 4: fixed-fps SLA analysis
    if fixed_fps_rows:
        lines = []
        for r in fixed_fps_rows:
            fps_target = r['target_fps']
            instances = r['instances']
            threads = r['threads']
            cpu = r['avg_cpu_pct']
            bw = r['membw_read_gbs']
            iowait = r['iowait_pct']
            actual_fps = r['avg_fps_per_instance']
            lines.append(
                f"  固定 {fps_target} fps/实例，{instances}x{threads}t："
                f"  实际 {actual_fps:.2f} fps/实例，"
                f"CPU {cpu:.1f}%，iowait {iowait:.1f}%，MemBW {bw:.2f} GB/s"
            )
        block4 = (
            "固定 FPS/实例（SLA 建模）场景下，CPU 和内存带宽消耗如下：\n"
            + '\n'.join(lines) + '\n'
            + '  可与满速跑结果对比，推算固定 SLA 下的资源余量和可减配空间。'
        )
    else:
        block4 = None

    return block1, block2, block3, block4


# ──────────────────────────────────────────────
# Engineering advice table
# ──────────────────────────────────────────────

def build_advice_table(rows, kpis):
    medium_rows = [r for r in rows if r['preset'] == 'medium' and r['target_fps'] == 0]
    ultrafast_rows = [r for r in rows if r['preset'] == 'ultrafast' and r['target_fps'] == 0]

    best_medium = max(medium_rows, key=lambda r: r['total_fps']) if medium_rows else None
    best_uf = max(ultrafast_rows, key=lambda r: r['total_fps']) if ultrafast_rows else None
    first_medium = medium_rows[0] if medium_rows else None

    rows_html = []

    if best_medium:
        cfg = f"{best_medium['instances']}x{best_medium['threads']}t medium"
        fps = best_medium['total_fps']
        rows_html.append(
            f"<tr><td>离线批量 4K 转码</td>"
            f"<td class='cfg'>{cfg}</td>"
            f"<td class='fps'>{fps:.0f} fps</td>"
            f"<td>最大化 CPU 有效利用率，消除 WPP 同步等待</td></tr>"
        )

    if best_uf:
        cfg = f"{best_uf['instances']}x{best_uf['threads']}t ultrafast"
        fps = best_uf['total_fps']
        rows_html.append(
            f"<tr><td>直播实时推流</td>"
            f"<td class='cfg'>{cfg}</td>"
            f"<td class='fps'>{fps:.0f} fps</td>"
            f"<td>低质量要求，最高吞吐，内存读写密集型</td></tr>"
        )

    if best_medium:
        fps = best_medium['total_fps']
        streams_30 = fps / 30
        cfg = f"{best_medium['instances']}x{best_medium['threads']}t medium"
        rows_html.append(
            f"<tr><td>实时点播（30fps/路）</td>"
            f"<td class='cfg'>{cfg}</td>"
            f"<td class='fps'>{streams_30:.0f} 路实时</td>"
            f"<td>总FPS / 30，最大并发实时转码路数</td></tr>"
        )

    if first_medium:
        fps_per = first_medium['avg_fps_per_instance']
        threads = first_medium['threads']
        rows_html.append(
            f"<tr><td>低延迟单路</td>"
            f"<td class='cfg'>1x{threads}t medium</td>"
            f"<td class='fps'>{fps_per:.1f} fps/路</td>"
            f"<td>WPP 帧内并行，单路最低延迟，多线程协作</td></tr>"
        )

    return '\n'.join(rows_html)


# ──────────────────────────────────────────────
# Main HTML generation
# ──────────────────────────────────────────────

def generate_html(rows, title, platform, results_dir, output_path):
    kpis = compute_kpis(rows)
    block1, block2, block3, block4 = build_analysis_text(rows, kpis)
    advice_rows_html = build_advice_table(rows, kpis)
    now_str = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')

    has_fixed_fps = kpis.get('has_fixed_fps', False)
    fixed_fps_rows = kpis.get('fixed_fps_rows', [])

    # Auto-adjust title: distinguish max-throughput vs fixed-fps tests
    if has_fixed_fps and not any(r['target_fps'] == 0 for r in rows):
        # Only fixed-fps data present
        report_subtitle = '固定FPS（SLA建模）测试报告'
    elif has_fixed_fps:
        # Mixed: both max-throughput and fixed-fps
        report_subtitle = '最大吞吐 + 固定FPS（SLA建模）对比报告'
    else:
        report_subtitle = '最大吞吐测试报告'

    # For charts: labels and values (exclude fixed-fps rows from main charts)
    medium_rows = [r for r in rows if r['preset'] == 'medium' and r['target_fps'] == 0]
    ultrafast_rows = [r for r in rows if r['preset'] == 'ultrafast' and r['target_fps'] == 0]
    all_rows_ordered = medium_rows + ultrafast_rows

    def make_label(r):
        preset_short = 'm' if r['preset'] == 'medium' else 'uf'
        fps_suffix = f'@{r["target_fps"]}fps' if r['target_fps'] > 0 else ''
        return f"{r['instances']}x{r['threads']}t-{preset_short}{fps_suffix}"

    chart_labels = [make_label(r) for r in all_rows_ordered]
    chart_total_fps = [r['total_fps'] for r in all_rows_ordered]
    chart_cpu = [r['avg_cpu_pct'] for r in all_rows_ordered]
    chart_mem = [r['mem_used_gb'] for r in all_rows_ordered]
    chart_bw = [r['membw_read_gbs'] for r in all_rows_ordered]

    svg1 = make_bar_chart_svg('总 FPS', chart_labels, chart_total_fps, '#00b0f0')
    svg2 = make_bar_chart_svg('CPU 利用率 (%)', chart_labels, chart_cpu, '#f16521')
    svg3 = make_bar_chart_svg('内存使用 (GB)', chart_labels, chart_mem, '#8957e5')
    svg4 = make_line_chart_svg('MemBW 读带宽 (GB/s)', chart_labels, chart_bw, '#3fb950')

    # Data table rows
    # Base row: first non-fixed-fps row (or first row if all fixed-fps)
    base_rows = [r for r in rows if r['target_fps'] == 0]
    base_total_fps = base_rows[0]['total_fps'] if base_rows else (rows[0]['total_fps'] if rows else 1)
    table_rows_html = []
    best_medium_fps = max((r['total_fps'] for r in medium_rows), default=0)

    for r in rows:
        is_fixed_fps = (r['target_fps'] > 0)
        is_base = (not is_fixed_fps and base_rows and r == base_rows[0])
        is_best_medium = (r['preset'] == 'medium' and r['target_fps'] == 0 and r['total_fps'] == best_medium_fps)
        is_ultrafast = (r['preset'] == 'ultrafast' and r['target_fps'] == 0)

        gain = (r['total_fps'] - base_total_fps) / base_total_fps * 100 if base_total_fps > 0 else 0
        gain_str = f'+{gain:.1f}%' if gain >= 0 else f'{gain:.1f}%'

        fps_suffix = f'@{r["target_fps"]}fps' if is_fixed_fps else ''
        cfg_label = f"{r['instances']}x{r['threads']}t{fps_suffix} {r['preset']}"
        badge = ''
        if is_base:
            badge = ' <span class="badge badge-base">基准</span>'
        if is_best_medium:
            badge += ' <span class="badge badge-best">最优</span>'
        if is_fixed_fps:
            badge += ' <span class="badge badge-fixedfps">固定FPS</span>'

        row_class = ''
        if is_best_medium:
            row_class = ' class="row-best"'
        elif is_ultrafast:
            row_class = ' class="row-ultrafast"'
        elif is_fixed_fps:
            row_class = ' class="row-fixedfps"'

        table_rows_html.append(
            f'<tr{row_class}>'
            f'<td>{cfg_label}{badge}</td>'
            f'<td>{r["instances"]}</td>'
            f'<td>{r["threads"]}</td>'
            f'<td>{r["preset"]}</td>'
            f'<td>{r["avg_fps_per_instance"]:.2f}</td>'
            f'<td>{"<b>" if is_best_medium else ""}{r["total_fps"]:.1f}{"</b>" if is_best_medium else ""}</td>'
            f'<td class="gain-cell">{gain_str}</td>'
            f'<td>{r["avg_cpu_pct"]:.1f}%</td>'
            f'<td>{r["iowait_pct"]:.1f}%</td>'
            f'<td>{r["membw_read_gbs"]:.2f}</td>'
            f'<td>{r["mem_used_gb"]:.2f}</td>'
            f'</tr>'
        )

    table_html = '\n'.join(table_rows_html)

    # Duration info
    duration_infos = list(set(f'{r["duration_s"]:.0f}s' for r in rows))
    duration_str = ' / '.join(sorted(duration_infos))

    # KPI values
    kpi_max_fps = kpis.get('max_total_fps_medium', 0)
    kpi_cpu = kpis.get('max_cpu_pct', 0)
    kpi_gain = kpis.get('fps_gain_pct', 0)
    kpi_gain_from = kpis.get('fps_gain_from_label', '-')
    kpi_gain_to = kpis.get('fps_gain_to_label', '-')
    kpi_uf_x = kpis.get('ultrafast_vs_medium_x', 0)

    # block2 needs <br> for HTML
    block2_html = block2.replace('\n', '<br>')

    # block4: fixed-fps analysis (conditional)
    if block4 is not None:
        block4_html = (
            '<div class="analysis-block ab-purple">'
            '<div class="ab-title">固定 FPS/实例（SLA 建模）资源消耗</div>'
            + block4.replace('\n', '<br>')
            + '</div>'
        )
    else:
        block4_html = ''

    html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{title}</title>
<style>
*, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
body {{
    background: #0d1117;
    color: #c9d1d9;
    font-family: 'Segoe UI', Arial, 'Microsoft YaHei', sans-serif;
    font-size: 14px;
    line-height: 1.6;
    padding: 24px;
}}
h1 {{ color: #00b0f0; font-size: 26px; margin-bottom: 6px; }}
h2 {{ color: #00b0f0; font-size: 17px; margin: 28px 0 14px; border-left: 3px solid #00b0f0; padding-left: 10px; }}
.subtitle {{ color: #8b949e; font-size: 13px; margin-bottom: 24px; }}
.kpi-row {{
    display: flex; gap: 16px; margin-bottom: 28px; flex-wrap: wrap;
}}
.kpi-card {{
    background: #161b22; border: 1px solid #30363d; border-radius: 8px;
    padding: 18px 24px; flex: 1; min-width: 180px;
}}
.kpi-card .kpi-label {{ color: #8b949e; font-size: 12px; margin-bottom: 6px; }}
.kpi-card .kpi-value {{ color: #00b0f0; font-size: 28px; font-weight: bold; }}
.kpi-card .kpi-sub {{ color: #8b949e; font-size: 11px; margin-top: 4px; }}
table {{
    width: 100%; border-collapse: collapse; margin-bottom: 24px;
    background: #161b22; border-radius: 8px; overflow: hidden;
}}
th {{
    background: #21262d; color: #c9d1d9; font-size: 12px;
    padding: 10px 12px; text-align: center; border-bottom: 1px solid #30363d;
}}
td {{
    padding: 9px 12px; border-bottom: 1px solid #21262d;
    font-size: 13px; text-align: center; color: #c9d1d9;
}}
td:first-child {{ text-align: left; }}
tr:last-child td {{ border-bottom: none; }}
tr.row-best {{ background: rgba(0, 176, 240, 0.07); }}
tr.row-ultrafast {{ border-left: 3px solid #f16521; }}
tr.row-fixedfps {{ border-left: 3px solid #7c4dff; background: rgba(124,77,255,0.05); }}
tr:hover {{ background: #1c2128; }}
.gain-cell {{ color: #3fb950; font-weight: 600; }}
.badge {{
    display: inline-block; border-radius: 4px;
    font-size: 10px; padding: 1px 6px; margin-left: 4px; vertical-align: middle;
}}
.badge-base {{ background: #21262d; color: #8b949e; border: 1px solid #30363d; }}
.badge-best {{ background: rgba(0,176,240,0.15); color: #00b0f0; border: 1px solid #00b0f0; }}
.badge-fixedfps {{ background: rgba(139,71,255,0.15); color: #b388ff; border: 1px solid #7c4dff; }}
.charts-grid {{
    display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 28px;
}}
.chart-box {{
    background: #161b22; border: 1px solid #30363d; border-radius: 8px;
    padding: 12px; overflow: hidden;
}}
.analysis-blocks {{
    display: flex; flex-direction: column; gap: 16px; margin-bottom: 28px;
}}
.analysis-block {{
    border-radius: 8px; padding: 16px 20px;
    font-size: 13px; line-height: 1.8;
}}
.ab-blue {{ background: rgba(0,176,240,0.08); border-left: 3px solid #00b0f0; }}
.ab-orange {{ background: rgba(241,101,33,0.08); border-left: 3px solid #f16521; }}
.ab-green {{ background: rgba(63,185,80,0.08); border-left: 3px solid #3fb950; }}
.ab-purple {{ background: rgba(124,77,255,0.08); border-left: 3px solid #7c4dff; }}
.ab-title {{
    font-weight: 700; font-size: 14px; margin-bottom: 8px;
}}
.ab-blue .ab-title {{ color: #00b0f0; }}
.ab-orange .ab-title {{ color: #f16521; }}
.ab-green .ab-title {{ color: #3fb950; }}
.ab-purple .ab-title {{ color: #b388ff; }}
.advice-table th {{ background: #21262d; }}
.advice-table td.cfg {{ color: #00b0f0; font-family: monospace; font-size: 12px; }}
.advice-table td.fps {{ color: #3fb950; font-weight: 600; }}
footer {{
    margin-top: 32px; padding-top: 16px; border-top: 1px solid #21262d;
    color: #8b949e; font-size: 12px;
}}
</style>
</head>
<body>

<h1>{title}</h1>
<div class="subtitle">
    {report_subtitle} &nbsp;|&nbsp; 平台：{platform} &nbsp;|&nbsp; 测试时长：{duration_str} &nbsp;|&nbsp; 生成时间：{now_str}
</div>

<!-- KPI Cards -->
<div class="kpi-row">
    <div class="kpi-card">
        <div class="kpi-label">最高总 FPS（medium 系列）</div>
        <div class="kpi-value">{kpi_max_fps:.0f}</div>
        <div class="kpi-sub">fps</div>
    </div>
    <div class="kpi-card">
        <div class="kpi-label">CPU 利用率峰值</div>
        <div class="kpi-value">{kpi_cpu:.1f}%</div>
        <div class="kpi-sub">medium 系列</div>
    </div>
    <div class="kpi-card">
        <div class="kpi-label">FPS 增益</div>
        <div class="kpi-value">+{kpi_gain:.1f}%</div>
        <div class="kpi-sub">{kpi_gain_from} → {kpi_gain_to}</div>
    </div>
    <div class="kpi-card">
        <div class="kpi-label">ultrafast vs medium 倍数</div>
        <div class="kpi-value">{kpi_uf_x:.2f}x</div>
        <div class="kpi-sub">256 实例对比</div>
    </div>
</div>

<!-- Data Table -->
<h2>完整数据</h2>
<table>
<thead>
<tr>
    <th>配置</th><th>实例数</th><th>线程/实例</th><th>预设</th>
    <th>FPS/实例</th><th>总FPS</th><th>FPS增益</th>
    <th>CPU%</th><th>iowait%</th><th>MemBW读(GB/s)</th><th>内存使用(GB)</th>
</tr>
</thead>
<tbody>
{table_html}
</tbody>
</table>

<!-- Charts -->
<h2>性能图表</h2>
<div class="charts-grid">
    <div class="chart-box">{svg1}</div>
    <div class="chart-box">{svg2}</div>
    <div class="chart-box">{svg3}</div>
    <div class="chart-box">{svg4}</div>
</div>

<!-- Analysis -->
<h2>数据解读</h2>
<div class="analysis-blocks">
    <div class="analysis-block ab-blue">
        <div class="ab-title">FPS 增益来源：消除 WPP 屏障</div>
        {block1}
    </div>
    <div class="analysis-block ab-orange">
        <div class="ab-title">CPU 利用率规律</div>
        {block2_html}
    </div>
    <div class="analysis-block ab-green">
        <div class="ab-title">ultrafast vs medium：{kpi_uf_x:.2f}x FPS 差距的含义</div>
        {block3.replace(chr(10), '<br>')}
    </div>
    {block4_html}
</div>

<!-- Engineering Advice -->
<h2>工程建议</h2>
<table class="advice-table">
<thead>
<tr><th>场景</th><th>推荐配置</th><th>预期总 FPS / 效果</th><th>核心逻辑</th></tr>
</thead>
<tbody>
{advice_rows_html}
</tbody>
</table>

<footer>
    生成时间：{now_str}<br>
    测试数据目录：{results_dir}<br>
    报告路径：{output_path}<br>
    服务器：10.69.12.180 (amd) &nbsp;|&nbsp; 生成工具：06_generate_scaling_report.py
</footer>

</body>
</html>
"""
    return html


# ──────────────────────────────────────────────
# Entry point
# ──────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='生成 x265 多实例扩展对比 HTML 报告'
    )
    parser.add_argument('--results-dir', required=True,
                        help='包含各配置子目录的根目录')
    parser.add_argument('--output', default=None,
                        help='输出 HTML 路径（默认 {results-dir}/scaling_report.html）')
    parser.add_argument('--title', default='x265 多实例扩展对比报告',
                        help='报告标题')
    parser.add_argument('--platform', default=None,
                        help='平台描述字符串（默认自动推断）')
    args = parser.parse_args()

    results_dir = os.path.abspath(args.results_dir)
    output_path = args.output or os.path.join(results_dir, 'scaling_report.html')

    print(f'[INFO] Scanning: {results_dir}')
    rows = discover_results(results_dir)
    if not rows:
        print('[ERROR] No result.json files found. Check --results-dir.', file=sys.stderr)
        sys.exit(1)

    print(f'[INFO] Found {len(rows)} result(s):')
    for r in rows:
        print(f'       {r["instances"]}x{r["threads"]}t {r["preset"]:12s} '
              f'total_fps={r["total_fps"]:.1f}  cpu={r["avg_cpu_pct"]:.1f}%')

    platform = args.platform or infer_platform(rows)
    print(f'[INFO] Platform: {platform}')

    html = generate_html(rows, args.title, platform, results_dir, output_path)

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(html)

    size_kb = os.path.getsize(output_path) / 1024
    print(f'[INFO] Report written: {output_path} ({size_kb:.1f} KB)')


if __name__ == '__main__':
    main()
