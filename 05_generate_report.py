#!/usr/bin/env python3
"""
FFmpeg 内存带宽基准测试报告生成器
支持 per-channel 报告和多通道对比报告
用法:
  python3 05_generate_report.py --mode single --result-dir results/24ch_TIMESTAMP
  python3 05_generate_report.py --mode multi  --results-dir results/
"""
import argparse
import json
import os
import sys
import glob
import re
from datetime import datetime


def safe_float(val, default=0.0):
    try:
        return float(val)
    except (TypeError, ValueError):
        return default


def parse_args():
    p = argparse.ArgumentParser(description='Generate FFmpeg membw benchmark report')
    p.add_argument('--mode', choices=['single', 'multi'], default='multi',
                   help='single: one channel config; multi: compare multiple configs')
    p.add_argument('--result-dir', default=None,
                   help='Single mode: path to one channel result directory')
    p.add_argument('--results-dir', default='/work/ffmpeg-membw-bench/results',
                   help='Multi mode: root results directory')
    p.add_argument('--output', default=None,
                   help='Output HTML file path (default: auto-named)')
    p.add_argument('--stream-peak', type=float, default=None,
                   help='STREAM measured peak bandwidth (GB/s) for utilization calc')
    p.add_argument('--perf-baseline', default='',
                   help='ffmpeg-performance-test-script 结果目录，用于提取单路CPU基准')
    return p.parse_args()


def load_perf_baseline(baseline_dir):
    """从 ffmpeg-performance-test-script 结果目录读取单路FPS基准"""
    if not baseline_dir or not os.path.isdir(baseline_dir):
        return {}
    baseline = {}
    csv_path = os.path.join(baseline_dir, 'speed_comparison.csv')
    if os.path.exists(csv_path):
        import csv
        with open(csv_path, 'r') as f:
            reader = csv.DictReader(f)
            for row in reader:
                key = (str(row.get('codec', '')) + '-' +
                       str(row.get('preset', '')) + '-' +
                       str(row.get('resolution', '')))
                try:
                    baseline[key] = float(row.get('avg_speed_x', 0))
                except Exception:
                    pass
    return baseline


def load_result_json(result_dir):
    """Load all group result JSONs from a channel result directory."""
    results = {}
    meta_path = os.path.join(result_dir, 'meta.json')
    if os.path.exists(meta_path):
        with open(meta_path) as f:
            results['meta'] = json.load(f)
    # Group subdirectory name patterns for A-G
    GROUP_SUBS = {
        'A': ['groupA_single'],
        'B': ['groupB_parallel_x265_medium'],
        'C': ['groupC_parallel_x265_slow'],
        'D': ['groupD_parallel_x264'],
        'E': ['groupE_parallel_decode'],
        'F': ['groupF_parallel_1080p_ultrafast'],
        'G': ['groupG_parallel_x265_slow_ref8'],
    }
    for grp, subs in GROUP_SUBS.items():
        for sub in subs:
            rjson = os.path.join(result_dir, sub, 'result.json')
            if os.path.exists(rjson):
                with open(rjson) as f:
                    data = json.load(f)
                    results['group' + grp] = data
    return results


def collect_multi_results(results_dir):
    """Collect all channel result directories, return sorted list.
    For each channel count, only the LATEST directory (by timestamp in dirname) is used.
    """
    # 先收集每个 channel 的所有目录，按时间戳排序取最新
    ch_map = {}  # ch -> list of (dirname, full_path)
    for d in os.listdir(results_dir):
        m = re.match(r'^(\d+)ch_', d)
        if m:
            ch = int(m.group(1))
            full_path = os.path.join(results_dir, d)
            if os.path.isdir(full_path):
                ch_map.setdefault(ch, []).append((d, full_path))

    dirs = []
    for ch, entries in ch_map.items():
        # 按目录名倒序排列，取第一个（最新时间戳）
        entries.sort(key=lambda x: x[0], reverse=True)
        latest_name, latest_path = entries[0]
        if len(entries) > 1:
            skipped = [e[0] for e in entries[1:]]
            print(f'  {ch}ch: using {latest_name} (skipping older: {skipped})')
        else:
            print(f'  {ch}ch: using {latest_name}')
        data = load_result_json(latest_path)
        if data:
            dirs.append({'channels': ch, 'dir': latest_path, 'data': data})

    dirs.sort(key=lambda x: x['channels'])
    return dirs


# ─── CSS / JS constants ───────────────────────────────────────────────────────

DARK_CSS = """
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  background: #0d1117;
  color: #c9d1d9;
  font-family: 'Segoe UI', system-ui, sans-serif;
  font-size: 14px;
  line-height: 1.6;
}
h1, h2, h3 { color: #e6edf3; }
h1 { font-size: 1.8em; margin-bottom: 0.3em; }
h2 { font-size: 1.3em; margin: 1.5em 0 0.5em; border-bottom: 1px solid #30363d; padding-bottom: 0.3em; }
h3 { font-size: 1.1em; margin: 1em 0 0.4em; color: #79c0ff; }
a { color: #58a6ff; text-decoration: none; }
a:hover { text-decoration: underline; }
.container { max-width: 1200px; margin: 0 auto; padding: 20px; }
.header {
  background: linear-gradient(135deg, #161b22 0%, #0d1117 100%);
  border-bottom: 1px solid #30363d;
  padding: 24px 0;
  margin-bottom: 24px;
}
.header .container { display: flex; align-items: center; justify-content: space-between; }
.badge {
  background: #238636;
  color: #fff;
  padding: 2px 8px;
  border-radius: 12px;
  font-size: 0.8em;
  font-weight: 600;
}
.badge.blue { background: #1f6feb; }
.badge.orange { background: #d29922; }
.nav {
  background: #161b22;
  border-bottom: 1px solid #30363d;
  padding: 8px 0;
  position: sticky;
  top: 0;
  z-index: 100;
}
.nav ul { list-style: none; display: flex; gap: 4px; padding: 0 20px; }
.nav li a {
  display: block;
  padding: 6px 14px;
  border-radius: 6px;
  color: #8b949e;
  transition: all 0.2s;
}
.nav li a:hover, .nav li a.active {
  background: #21262d;
  color: #c9d1d9;
}
.section { padding: 20px 0; display: block; margin-bottom: 32px; }
.section.active { display: block; }
.card {
  background: #161b22;
  border: 1px solid #30363d;
  border-radius: 8px;
  padding: 16px;
  margin-bottom: 16px;
}
.card-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px; margin-bottom: 16px; }
.metric-card {
  background: #0d1117;
  border: 1px solid #30363d;
  border-radius: 8px;
  padding: 16px;
  text-align: center;
}
.metric-card .value { font-size: 2em; font-weight: 700; color: #58a6ff; }
.metric-card .label { color: #8b949e; font-size: 0.85em; margin-top: 4px; }
.metric-card .unit { font-size: 0.6em; color: #8b949e; }
table { width: 100%; border-collapse: collapse; }
th { background: #21262d; color: #8b949e; padding: 8px 12px; text-align: left; font-weight: 600; font-size: 0.85em; }
td { padding: 8px 12px; border-bottom: 1px solid #21262d; }
tr:hover td { background: #161b22; }
.chart-wrap { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 16px; margin-bottom: 20px; }
.chart-title { font-size: 1em; font-weight: 600; color: #e6edf3; margin-bottom: 12px; }
.chart-legend { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 8px; }
.legend-item { display: flex; align-items: center; gap: 6px; font-size: 0.85em; cursor: pointer; }
.legend-dot { width: 12px; height: 12px; border-radius: 50%; flex-shrink: 0; }
canvas { display: block; width: 100%; }
.highlight { color: #3fb950; font-weight: 600; }
.warn { color: #d29922; }
footer { margin-top: 40px; padding: 16px 0; border-top: 1px solid #30363d; color: #484f58; font-size: 0.85em; text-align: center; }
/* Scenario card styles */
.group-card { background:#161b22; border:1px solid #30363d; border-radius:8px; padding:16px; margin-bottom:12px; }
.group-header { display:flex; align-items:center; gap:12px; margin-bottom:10px; }
.group-badge { display:inline-block; width:32px; height:32px; border-radius:50%; background:#1f6feb; color:#fff; font-weight:700; font-size:1.1em; text-align:center; line-height:32px; flex-shrink:0; }
.scenario-name { font-size:1.05em; font-weight:600; color:#e6edf3; }
.scenario-chars { display:flex; flex-wrap:wrap; gap:6px; margin-bottom:10px; }
.char-tag { background:#21262d; color:#79c0ff; padding:2px 8px; border-radius:4px; font-size:0.8em; }
.pressure-row { display:flex; gap:8px; margin-bottom:10px; }
.pbadge { padding:3px 10px; border-radius:10px; font-size:0.8em; font-weight:600; color:#fff; }
.plevel-极低 { background:#1a6b3c; }
.plevel-低   { background:#2ea043; }
.plevel-中   { background:#9a6700; }
.plevel-中等 { background:#9a6700; }
.plevel-高   { background:#b45309; }
.plevel-极高 { background:#b91c1c; }
.expected-text { color:#8b949e; font-size:0.9em; margin-bottom:10px; }
.result-row { display:flex; gap:20px; font-size:0.95em; }
/* Scenario comparison table */
.scenario-table th, .scenario-table td { padding:8px 10px; font-size:0.85em; }
.drop-red { color:#ff7b72; font-weight:600; }
.drop-yellow { color:#ffa657; font-weight:600; }
.drop-green { color:#3fb950; font-weight:600; }
.recommend-ok { color:#3fb950; }
.recommend-warn { color:#ffa657; }
.recommend-no { color:#ff7b72; }
"""

NAV_JS = """
function show(id, el) {
  document.querySelectorAll('.section').forEach(function(s){ s.classList.remove('active'); });
  document.querySelectorAll('.nav a').forEach(function(a){ a.classList.remove('active'); });
  document.getElementById(id).classList.add('active');
  if (el) el.classList.add('active');
}
"""

CHART_JS = r"""
var COLORS = ['#58a6ff','#3fb950','#d29922','#f78166','#bc8cff','#79c0ff','#56d364','#e3b341'];

function drawBarChart(canvasId, legendId, labels, datasets, yLabel) {
  var canvas = document.getElementById(canvasId);
  if (!canvas) return;
  canvas.width  = canvas.parentElement.clientWidth - 32;
  canvas.height = 200;
  var ctx = canvas.getContext('2d');
  var W = canvas.width, H = canvas.height;
  var PAD = {top:30, right:20, bottom:60, left:70};
  var PW = W - PAD.left - PAD.right;
  var PH = H - PAD.top  - PAD.bottom;

  var maxVal = 0;
  datasets.forEach(function(ds){ ds.data.forEach(function(v){ if(v > maxVal) maxVal = v; }); });
  maxVal = maxVal * 1.15 || 1;

  ctx.clearRect(0, 0, W, H);
  ctx.fillStyle = '#161b22';
  ctx.fillRect(0, 0, W, H);

  var nGrid = 5;
  ctx.strokeStyle = '#21262d';
  ctx.lineWidth = 1;
  for (var gi = 0; gi <= nGrid; gi++) {
    var y = PAD.top + PH - (PH * gi / nGrid);
    ctx.beginPath(); ctx.moveTo(PAD.left, y); ctx.lineTo(PAD.left + PW, y); ctx.stroke();
    ctx.fillStyle = '#8b949e'; ctx.font = '11px sans-serif'; ctx.textAlign = 'right';
    ctx.fillText((maxVal * gi / nGrid).toFixed(1), PAD.left - 6, y + 4);
  }

  var nGroups = labels.length;
  var nDS = datasets.length;
  var groupW = PW / nGroups;
  var barW = Math.min(groupW / (nDS + 1), 40);

  for (var gi2 = 0; gi2 < nGroups; gi2++) {
    for (var di = 0; di < nDS; di++) {
      var val = datasets[di].data[gi2] || 0;
      var bH = PH * val / maxVal;
      var bX = PAD.left + gi2 * groupW + (di + 0.5) * barW + (groupW - nDS * barW) / 2;
      var bY = PAD.top + PH - bH;
      ctx.fillStyle = COLORS[di % COLORS.length];
      ctx.fillRect(bX, bY, barW - 2, bH);
    }
    ctx.fillStyle = '#8b949e'; ctx.font = '11px sans-serif'; ctx.textAlign = 'center';
    ctx.fillText(labels[gi2], PAD.left + gi2 * groupW + groupW / 2, H - PAD.bottom + 16);
  }

  ctx.strokeStyle = '#30363d'; ctx.lineWidth = 1;
  ctx.beginPath(); ctx.moveTo(PAD.left, PAD.top); ctx.lineTo(PAD.left, PAD.top + PH); ctx.stroke();
  ctx.beginPath(); ctx.moveTo(PAD.left, PAD.top + PH); ctx.lineTo(PAD.left + PW, PAD.top + PH); ctx.stroke();

  ctx.save(); ctx.translate(14, PAD.top + PH / 2); ctx.rotate(-Math.PI / 2);
  ctx.fillStyle = '#8b949e'; ctx.font = '11px sans-serif'; ctx.textAlign = 'center';
  ctx.fillText(yLabel || '', 0, 0); ctx.restore();

  ctx.fillStyle = '#8b949e'; ctx.font = '11px sans-serif'; ctx.textAlign = 'center';
  ctx.fillText('Memory Channels', PAD.left + PW / 2, H - 8);

  if (legendId) {
    var leg = document.getElementById(legendId);
    if (leg) {
      leg.innerHTML = '';
      datasets.forEach(function(ds, di2) {
        var item = document.createElement('div');
        item.className = 'legend-item';
        item.innerHTML = '<div class="legend-dot" style="background:' + COLORS[di2 % COLORS.length] + '"></div><span>' + ds.label + '</span>';
        leg.appendChild(item);
      });
    }
  }
}

function drawLineChart(canvasId, legendId, labels, datasets, yLabel) {
  var canvas = document.getElementById(canvasId);
  if (!canvas) return;
  canvas.width  = canvas.parentElement.clientWidth - 32;
  canvas.height = 180;
  var ctx = canvas.getContext('2d');
  var W = canvas.width, H = canvas.height;
  var PAD = {top:30, right:20, bottom:60, left:70};
  var PW = W - PAD.left - PAD.right;
  var PH = H - PAD.top  - PAD.bottom;

  var maxVal = 0, minVal = Infinity;
  datasets.forEach(function(ds){
    ds.data.forEach(function(v){ if(v > maxVal) maxVal = v; if(v < minVal) minVal = v; });
  });
  maxVal = maxVal * 1.1 || 1;
  minVal = Math.max(0, minVal * 0.9);

  ctx.clearRect(0, 0, W, H);
  ctx.fillStyle = '#161b22'; ctx.fillRect(0, 0, W, H);

  var nGrid = 5;
  ctx.strokeStyle = '#21262d'; ctx.lineWidth = 1;
  for (var gi = 0; gi <= nGrid; gi++) {
    var y = PAD.top + PH - (PH * gi / nGrid);
    ctx.beginPath(); ctx.moveTo(PAD.left, y); ctx.lineTo(PAD.left + PW, y); ctx.stroke();
    var tickVal = minVal + (maxVal - minVal) * gi / nGrid;
    ctx.fillStyle = '#8b949e'; ctx.font = '11px sans-serif'; ctx.textAlign = 'right';
    ctx.fillText(tickVal.toFixed(1), PAD.left - 6, y + 4);
  }

  var nPts = labels.length;
  function xPos(i) { return PAD.left + PW * i / Math.max(nPts - 1, 1); }
  function yPos(v) { return PAD.top + PH - PH * (v - minVal) / (maxVal - minVal || 1); }

  datasets.forEach(function(ds, di) {
    var color = COLORS[di % COLORS.length];
    ctx.strokeStyle = color; ctx.lineWidth = 2;
    if (ds.dashed) { ctx.setLineDash([8, 4]); } else { ctx.setLineDash([]); }
    ctx.beginPath();
    ds.data.forEach(function(v, i) {
      var x = xPos(i), y = yPos(v);
      if (i === 0) { ctx.moveTo(x, y); } else { ctx.lineTo(x, y); }
    });
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = color;
    ds.data.forEach(function(v, i) {
      ctx.beginPath(); ctx.arc(xPos(i), yPos(v), 4, 0, 2*Math.PI); ctx.fill();
    });
  });

  ctx.strokeStyle = '#30363d'; ctx.lineWidth = 1;
  ctx.beginPath(); ctx.moveTo(PAD.left, PAD.top); ctx.lineTo(PAD.left, PAD.top + PH); ctx.stroke();
  ctx.beginPath(); ctx.moveTo(PAD.left, PAD.top + PH); ctx.lineTo(PAD.left + PW, PAD.top + PH); ctx.stroke();

  ctx.fillStyle = '#8b949e'; ctx.font = '11px sans-serif'; ctx.textAlign = 'center';
  labels.forEach(function(lbl, i) {
    ctx.fillText(lbl, xPos(i), H - PAD.bottom + 16);
  });

  ctx.save(); ctx.translate(14, PAD.top + PH / 2); ctx.rotate(-Math.PI / 2);
  ctx.fillStyle = '#8b949e'; ctx.font = '11px sans-serif'; ctx.textAlign = 'center';
  ctx.fillText(yLabel || '', 0, 0); ctx.restore();

  ctx.fillStyle = '#8b949e'; ctx.font = '11px sans-serif'; ctx.textAlign = 'center';
  ctx.fillText('Memory Channels', PAD.left + PW / 2, H - 8);

  if (legendId) {
    var leg = document.getElementById(legendId);
    if (leg) {
      leg.innerHTML = '';
      datasets.forEach(function(ds, di2) {
        var item = document.createElement('div');
        item.className = 'legend-item';
        item.innerHTML = '<div class="legend-dot" style="background:' + COLORS[di2 % COLORS.length] + '"></div><span>' + ds.label + '</span>';
        leg.appendChild(item);
      });
    }
  }
}
"""


def _grp_card(show_flag, inst, fps, label, extra=''):
    """Helper to build optional group card HTML without backslash in f-string."""
    if not show_flag:
        return ''
    return (
        '<div class="card"><h3>Group ' + label + ': ' + str(inst) + 'x ' + extra + '</h3>'
        '<p class="highlight">Total FPS: ' + str(round(fps, 2)) + '</p></div>'
    )


def _pressure_level(level):
    """Return CSS class name for a pressure level string."""
    level = str(level).strip()
    return 'plevel-' + level


def _scenario_card(grp_letter, grp_data):
    """Build a rich scenario card from group result JSON."""
    if not grp_data:
        return ''
    scn = grp_data.get('scenario', {})
    params = grp_data.get('params', {})
    name = scn.get('name', 'Group ' + grp_letter)
    chars = scn.get('characteristics', [])
    cpu = scn.get('cpu_pressure', {})
    mem = scn.get('memory_pressure', {})
    expected = scn.get('expected', '')
    total_fps = round(float(grp_data.get('total_fps', 0)), 2)
    avg_fps = round(float(grp_data.get('avg_fps_per_instance', 0)), 2)
    instances = grp_data.get('instances', '-')

    avg_cpu   = round(safe_float(grp_data.get('avg_cpu_pct',    0)), 1)
    iowait    = round(safe_float(grp_data.get('iowait_pct',     0)), 1)
    mem_gb    = round(safe_float(grp_data.get('mem_used_gb',    0)), 2)
    bw_gbs    = round(safe_float(grp_data.get('membw_read_gbs', 0)), 2)
    target_fps = grp_data.get('target_fps', 0)

    cpu_level = cpu.get('level', '')
    cpu_desc = cpu.get('desc', '')
    mem_level = mem.get('level', '')
    mem_desc = mem.get('desc', '')

    chars_html = ''.join('<span class="char-tag">' + c + '</span>' for c in chars)
    cpu_cls = _pressure_level(cpu_level)
    mem_cls = _pressure_level(mem_level)

    extra_metrics = (
        '<div class="result-row" style="margin-top:6px;color:#8b949e;font-size:0.85em;">'
        '<span>CPU: <strong>' + str(avg_cpu) + '%</strong></span>'
        '<span>iowait: <strong>' + str(iowait) + '%</strong></span>'
        '<span>MEM: <strong>' + str(mem_gb) + ' GB</strong></span>'
        '<span>BW: <strong>' + str(bw_gbs) + ' GB/s</strong></span>'
        + ('<span>TargetFPS: <strong>' + str(target_fps) + '</strong></span>' if target_fps else '') +
        '</div>'
    )

    return (
        '<div class="group-card">'
        '<div class="group-header">'
        '<span class="group-badge">' + grp_letter + '</span>'
        '<span class="scenario-name">' + name + '</span>'
        '</div>'
        + ('<div class="scenario-chars">' + chars_html + '</div>' if chars_html else '') +
        '<div class="pressure-row">'
        '<span class="pbadge ' + cpu_cls + '">CPU: ' + cpu_level + '</span>'
        '<span class="pbadge ' + mem_cls + '">内存: ' + mem_level + '</span>'
        '</div>'
        + ('<div class="expected-text">预期：' + expected + '</div>' if expected else '') +
        '<div class="result-row">'
        '<span>总FPS: <strong class="highlight">' + str(total_fps) + '</strong></span>'
        '<span>均值: <strong>' + str(avg_fps) + '</strong> FPS/实例</span>'
        '<span>实例数: ' + str(instances) + '</span>'
        '</div>'
        + extra_metrics +
        '</div>'
    )


def build_single_report(result_dir, stream_peak=None):
    """Generate HTML report for a single channel configuration."""
    data = load_result_json(result_dir)
    dirname = os.path.basename(result_dir)
    m = re.match(r'^(\d+)ch_', dirname)
    channels = int(m.group(1)) if m else '?'
    meta = data.get('meta', {})
    cpu_model = meta.get('cpu_model', 'AMD EPYC 9T24')
    hostname  = meta.get('hostname', 'unknown')
    kernel    = meta.get('kernel', 'unknown')
    timestamp = meta.get('timestamp', datetime.now().strftime('%Y%m%d_%H%M%S'))
    instances = meta.get('instances', 24)

    grp_a = data.get('groupA', {})
    grp_b = data.get('groupB', {})
    grp_c = data.get('groupC', {})
    grp_d = data.get('groupD', {})
    grp_e = data.get('groupE', {})
    grp_f = data.get('groupF', {})
    grp_g = data.get('groupG', {})

    fps_a     = float(grp_a.get('total_fps', 0))
    fps_b     = float(grp_b.get('total_fps', 0))
    fps_b_avg = float(grp_b.get('avg_fps_per_instance', 0))
    fps_c     = float(grp_c.get('total_fps', 0))
    fps_d     = float(grp_d.get('total_fps', 0))
    fps_e     = float(grp_e.get('total_fps', 0))
    fps_f     = float(grp_f.get('total_fps', 0))
    fps_g     = float(grp_g.get('total_fps', 0))

    now_str = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    rows_html = ''
    for grp_name, g, desc in [
        ('A', grp_a, 'Single instance x265 medium'),
        ('B', grp_b, str(instances) + 'x parallel x265 medium (ref=5)'),
        ('C', grp_c, str(instances) + 'x parallel x265 slow'),
        ('D', grp_d, str(instances) + 'x parallel x264 medium'),
        ('E', grp_e, str(instances) + 'x parallel decode'),
        ('F', grp_f, str(instances) + 'x parallel 1080p x265 ultrafast'),
        ('G', grp_g, str(instances) + 'x parallel 4K x265 slow ref=8'),
    ]:
        if g:
            avg_cpu   = round(safe_float(g.get('avg_cpu_pct',    0)), 1)
            iowait    = round(safe_float(g.get('iowait_pct',     0)), 1)
            mem_gb    = round(safe_float(g.get('mem_used_gb',    0)), 2)
            bw_gbs    = round(safe_float(g.get('membw_read_gbs', 0)), 2)
            rows_html += (
                '<tr>'
                '<td><span class="badge blue">Group ' + grp_name + '</span></td>'
                '<td>' + desc + '</td>'
                '<td>' + str(g.get('instances', '-')) + '</td>'
                '<td class="highlight">' + str(round(float(g.get('total_fps', 0)), 1)) + '</td>'
                '<td>' + str(round(float(g.get('avg_fps_per_instance', 0)), 2)) + '</td>'
                '<td>' + str(g.get('duration_s', '-')) + 's</td>'
                '<td>' + str(avg_cpu) + '%</td>'
                '<td>' + str(iowait) + '%</td>'
                '<td>' + str(mem_gb) + '</td>'
                '<td>' + str(bw_gbs) + '</td>'
                '</tr>'
            )

    # Scenario-aware cards for all groups
    card_a = _scenario_card('A', grp_a)
    card_b = _scenario_card('B', grp_b)
    card_c = _scenario_card('C', grp_c)
    card_d = _scenario_card('D', grp_d)
    card_e = _scenario_card('E', grp_e)
    card_f = _scenario_card('F', grp_f)
    card_g = _scenario_card('G', grp_g)

    # Compute DRAM estimates (avoid backslash in f-string by precomputing)
    dram_per_inst = round(fps_b_avg * 11.86 * 2 / 1024, 1)
    dram_total    = round(fps_b * 11.86 * 2 / 1024, 1)

    # System info extra rows
    sysinfo_extra = (
        '<tr><th>CCD Count</th><td>' + str(meta.get('ccd_count', '?')) + '</td></tr>\n'
        '<tr><th>Threads/Instance</th><td>' + str(meta.get('threads_per_instance', '?')) +
        ' (' + ('auto' if meta.get('threads_auto') else 'manual') + ')</td></tr>\n'
        '<tr><th>Instances</th><td>' + str(meta.get('instances', '?')) +
        ' (' + ('auto=CCD' if meta.get('instances_auto') else 'manual') + ')</td></tr>\n'
        '<tr><th>Target FPS</th><td>' +
        ('unlimited' if not meta.get('target_fps') else str(meta.get('target_fps')) + ' fps') +
        '</td></tr>\n'
    )

    html = (
        '<!DOCTYPE html>\n'
        '<html lang="zh-CN">\n'
        '<head>\n'
        '<meta charset="UTF-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        '<title>FFmpeg Memory BW Bench - ' + str(channels) + 'ch</title>\n'
        '<style>' + DARK_CSS + '</style>\n'
        '</head>\n'
        '<body>\n'
        '<div class="header"><div class="container">\n'
        '  <div>\n'
        '    <h1>FFmpeg Memory Bandwidth Benchmark</h1>\n'
        '    <div style="color:#8b949e;margin-top:4px;">' + cpu_model + ' &bull; ' + str(channels) + ' Memory Channels &bull; ' + hostname + ' &bull; ' + now_str + '</div>\n'
        '  </div>\n'
        '  <div><span class="badge">' + str(channels) + 'ch DDR5</span></div>\n'
        '</div></div>\n'
        '<nav class="nav"><ul>\n'
        '  <li><a href="#" onclick="show(\'overview\',this);return false;">Overview</a></li>\n'
        '  <li><a href="#" onclick="show(\'details\',this);return false;">Group Details</a></li>\n'
        '  <li><a href="#" onclick="show(\'sysinfo\',this);return false;">System Info</a></li>\n'
        '</ul></nav>\n'
        '<div class="container">\n'
        '\n'
        '<section id="overview" class="section">\n'
        '<h2>Performance Overview - ' + str(channels) + ' Channels</h2>\n'
        '<div class="card-grid">\n'
        '  <div class="metric-card"><div class="value">' + str(round(fps_a, 1)) + '</div><div class="unit">FPS</div><div class="label">Single Instance (A)</div></div>\n'
        '  <div class="metric-card"><div class="value">' + str(round(fps_b, 1)) + '</div><div class="unit">FPS</div><div class="label">Total Throughput ' + str(instances) + 'x (B)</div></div>\n'
        '  <div class="metric-card"><div class="value">' + str(round(fps_b_avg, 2)) + '</div><div class="unit">FPS/inst</div><div class="label">Avg per Instance (B)</div></div>\n'
        '  <div class="metric-card"><div class="value">' + str(round(fps_d, 1)) + '</div><div class="unit">FPS</div><div class="label">x264 Total (D)</div></div>\n'
        '</div>\n'
        '<div class="card"><h3>Group Results Summary</h3>\n'
        '<table><thead><tr>'
        '<th>Group</th><th>Description</th><th>Instances</th>'
        '<th>Total FPS</th><th>Avg FPS/inst</th><th>Duration</th>'
        '<th>CPU%</th><th>iowait%</th><th>MEM GB</th><th>BW GB/s</th>'
        '</tr></thead><tbody>' + rows_html + '</tbody></table></div>\n'
        '</section>\n'
        '\n'
        '<section id="details" class="section">\n'
        '<h2>Group Details</h2>\n'
        + card_a + card_b + card_c + card_d + card_e + card_f + card_g +
        '</section>\n'
        '\n'
        '<section id="sysinfo" class="section">\n'
        '<h2>System Information</h2>\n'
        '<div class="card"><table>\n'
        '<tr><th>CPU Model</th><td>' + cpu_model + '</td></tr>\n'
        '<tr><th>Hostname</th><td>' + hostname + '</td></tr>\n'
        '<tr><th>Kernel</th><td>' + kernel + '</td></tr>\n'
        '<tr><th>Memory Channels</th><td>' + str(channels) + '</td></tr>\n'
        '<tr><th>Test Instances</th><td>' + str(instances) + '</td></tr>\n'
        + sysinfo_extra +
        '<tr><th>FFmpeg</th><td>4.4.2 (libx264 + libx265 + libaom)</td></tr>\n'
        '<tr><th>Report Generated</th><td>' + now_str + '</td></tr>\n'
        '</table></div>\n'
        '</section>\n'
        '\n'
        '</div>\n'
        '<footer><div class="container">FFmpeg Memory Bandwidth Benchmark &bull; AMD EPYC 9T24 &bull; Generated ' + now_str + '</div></footer>\n'
        '<script>\n' + NAV_JS + '\n' + CHART_JS + '\n'
        'window.onload = function() { document.querySelector(\'.nav a\').click(); };\n'
        '</script>\n'
        '</body>\n'
        '</html>\n'
    )
    return html



def _pct_drop(high_fps, low_fps):
    """Compute percentage drop from high_fps to low_fps."""
    if not high_fps or high_fps == 0:
        return None
    return round((high_fps - low_fps) / high_fps * 100, 1)


def _drop_class(pct):
    if pct is None:
        return ''
    if pct >= 20:
        return 'drop-red'
    if pct >= 5:
        return 'drop-yellow'
    return 'drop-green'


def _build_scene_table(all_results, channels_list,
                        fps_a, fps_b, fps_c, fps_d, fps_e, fps_f, fps_g):
    """Build HTML table: groups B-G rows x channel columns."""
    if not all_results:
        return '<p style="color:#8b949e;">No data</p>'
    groups = [
        ('B', '视频云 4K x265 medium', fps_b),
        ('C', '视频归档 4K x265 slow', fps_c),
        ('D', 'x264 medium 对比', fps_d),
        ('E', 'CDN解码 读密集', fps_e),
        ('F', '直播 1080p ultrafast', fps_f),
        ('G', '高质量归档 4K slow ref=8', fps_g),
    ]
    ch_headers = ''.join('<th>' + str(c) + 'ch</th>' for c in channels_list)
    header = '<tr><th>组</th><th>场景</th>' + ch_headers + '<th>最大降幅</th></tr>'
    rows = ''
    for letter, name, series in groups:
        valid = [v for v in series if v > 0]
        if not valid:
            continue
        max_fps = max(valid)
        min_fps = min(valid)
        pct = _pct_drop(max_fps, min_fps)
        cls = _drop_class(pct)
        cells = ''
        for v in series:
            cells += '<td>' + (str(round(v, 1)) if v > 0 else '-') + '</td>'
        pct_str = (str(pct) + '%') if pct is not None else '-'
        rows += '<tr><td><strong>' + letter + '</strong></td><td>' + name + '</td>' + cells + '<td class="' + cls + '">' + pct_str + '</td></tr>'
    if not rows:
        return '<p style="color:#8b949e;">尚无多通道对比数据</p>'
    return '<table class="scenario-table"><thead>' + header + '</thead><tbody>' + rows + '</tbody></table>'


def _build_recommendation_table(all_results, channels_list,
                                  fps_b, fps_c, fps_d, fps_e, fps_f, fps_g):
    """Build recommendation table based on FPS drop thresholds."""
    GROUPS = [
        ('B', '视频云 4K x265 medium', fps_b, '核心参考'),
        ('C', '视频归档 4K x265 slow', fps_c, '高质量压制'),
        ('D', 'x264 medium', fps_d, '编码器对比'),
        ('E', 'CDN解码', fps_e, '读密集'),
        ('F', '直播 1080p ultrafast', fps_f, '低延迟推流'),
        ('G', '高质量归档 slow ref=8', fps_g, '极限质量'),
    ]
    if not all_results or not channels_list:
        return '<p style="color:#8b949e;">No data</p>'
    max_ch = max(channels_list)
    # Find FPS at max_ch for each group
    try:
        max_ch_idx = channels_list.index(max_ch)
    except ValueError:
        max_ch_idx = len(channels_list) - 1

    ch_headers = ''.join('<th>' + str(c) + 'ch</th>' for c in channels_list)
    header = ('<tr><th>组</th><th>场景</th><th>用途</th>' +
              ch_headers + '<th>结论</th></tr>')
    rows = ''
    conclusions = []
    for letter, name, series, purpose in GROUPS:
        base = series[max_ch_idx] if max_ch_idx < len(series) else 0
        if base == 0:
            continue
        cells = ''
        worst_drop = 0.0
        for v in series:
            pct = _pct_drop(base, v) if v > 0 else None
            cls = _drop_class(pct)
            pct_str = ('+' if pct is not None and pct < 0 else '') + (str(abs(pct)) + '%' if pct is not None else '-')
            cells += '<td class="' + cls + '">' + pct_str + '</td>'
            if pct is not None and pct > worst_drop:
                worst_drop = pct
        if worst_drop >= 20:
            conclusion = '<span class="recommend-no">不建议减配</span>'
            conclusions.append(letter + '组降幅 ' + str(worst_drop) + '%，不建议减配')
        elif worst_drop >= 5:
            conclusion = '<span class="recommend-warn">谨慎减配</span>'
            conclusions.append(letter + '组降幅 ' + str(worst_drop) + '%，谨慎减配')
        else:
            conclusion = '<span class="recommend-ok">可减配</span>'
        rows += '<tr><td><strong>' + letter + '</strong></td><td>' + name + '</td><td>' + purpose + '</td>' + cells + '<td>' + conclusion + '</td></tr>'
    if not rows:
        return '<p style="color:#8b949e;">尚无多通道对比数据</p>'
    conclusion_html = ''
    if conclusions:
        conclusion_html = ('<div class="card" style="margin-top:16px;">'
                           '<h3>结论</h3><ul style="padding-left:20px;line-height:2;">' +
                           ''.join('<li>' + c + '</li>' for c in conclusions) +
                           '</ul></div>')
    return ('<table class="scenario-table"><thead>' + header + '</thead><tbody>' +
            rows + '</tbody></table>' + conclusion_html)


def _build_drop_chart_js(fps_b, fps_c, fps_d, fps_e, fps_f, fps_g):
    """Build JS snippet for the FPS drop bar chart (Section 4)."""
    def max_drop(series):
        valid = [v for v in series if v > 0]
        if len(valid) < 2:
            return 0.0
        return round((max(valid) - min(valid)) / max(valid) * 100, 1)

    drops = [
        ('B', max_drop(fps_b)),
        ('C', max_drop(fps_c)),
        ('D', max_drop(fps_d)),
        ('E', max_drop(fps_e)),
        ('F', max_drop(fps_f)),
        ('G', max_drop(fps_g)),
    ]
    labels = str([d[0] for d in drops]).replace("'", '"')
    values = '[' + ','.join(str(d[1]) for d in drops) + ']'
    chart_label = 'FPS最大降幅'
    y_label = '降幅 %'
    return (
        "  drawBarChart('chart-drop', 'leg-drop', " + labels + ','
        + "[{label:'" + chart_label + "(%)', data:" + values + "}],'" + y_label + "');\n"
    )


def build_multi_report(all_results, stream_peak=None):
    """Generate multi-channel comparison HTML report."""
    now_str = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

    channels_list = [r['channels'] for r in all_results]
    ch_labels     = [str(c) + 'ch' for c in channels_list]

    fps_a_series  = [float(r['data'].get('groupA', {}).get('total_fps', 0)) for r in all_results]
    fps_b_total   = [float(r['data'].get('groupB', {}).get('total_fps', 0)) for r in all_results]
    fps_b_avg_lst = [float(r['data'].get('groupB', {}).get('avg_fps_per_instance', 0)) for r in all_results]
    fps_c_total   = [float(r['data'].get('groupC', {}).get('total_fps', 0)) for r in all_results]
    fps_d_total   = [float(r['data'].get('groupD', {}).get('total_fps', 0)) for r in all_results]
    fps_e_total   = [float(r['data'].get('groupE', {}).get('total_fps', 0)) for r in all_results]
    fps_f_total   = [float(r['data'].get('groupF', {}).get('total_fps', 0)) for r in all_results]
    fps_g_total   = [float(r['data'].get('groupG', {}).get('total_fps', 0)) for r in all_results]

    # 4K YUV420 frame size in MB
    FRAME_MB = 3840 * 2160 * 1.5 / (1024 * 1024)
    dram_bw   = [fps * FRAME_MB / 1024 for fps in fps_b_total]
    efficiency = [fps / max(ch, 1) for fps, ch in zip(fps_b_total, channels_list)]

    best_fps = max(fps_b_total) if fps_b_total else 0
    best_idx = fps_b_total.index(best_fps) if fps_b_total else 0
    best_ch  = channels_list[best_idx] if channels_list else '?'

    # Build table rows
    table_rows = ''
    for r in all_results:
        ch  = r['channels']
        gA  = r['data'].get('groupA', {})
        gB  = r['data'].get('groupB', {})
        gD  = r['data'].get('groupD', {})
        f_a  = float(gA.get('total_fps', 0))
        f_b  = float(gB.get('total_fps', 0))
        f_avg = float(gB.get('avg_fps_per_instance', 0))
        f_d   = float(gD.get('total_fps', 0))
        bw    = f_b * FRAME_MB / 1024
        eff   = f_b / max(ch, 1)
        hi    = ' class="highlight"' if ch == best_ch else ''
        table_rows += (
            '<tr' + hi + '>'
            '<td>' + str(ch) + '</td>'
            '<td>' + str(round(f_a, 1)) + '</td>'
            '<td>' + str(round(f_b, 1)) + '</td>'
            '<td>' + str(round(f_avg, 2)) + '</td>'
            '<td>' + str(round(f_d, 1)) + '</td>'
            '<td>' + str(round(bw, 2)) + '</td>'
            '<td>' + str(round(eff, 2)) + '</td>'
            '</tr>'
        )

    # Scaling table rows
    scale_rows = ''
    for i in range(len(fps_b_total) - 1):
        delta = fps_b_total[i + 1] - fps_b_total[i]
        pct   = fps_b_total[i + 1] / max(fps_b_total[i], 0.001) * 100 - 100
        scale_rows += (
            '<tr><td>' + ch_labels[i] + '</td>'
            '<td>' + ch_labels[i + 1] + '</td>'
            '<td>' + ('+' if delta >= 0 else '') + str(round(delta, 1)) + '</td>'
            '<td>' + ('+' if pct >= 0 else '') + str(round(pct, 1)) + '%</td></tr>'
        )

    # JS arrays
    def js_arr(lst):
        return '[' + ','.join(str(round(v, 2)) for v in lst) + ']'

    js_labels     = str(ch_labels).replace("'", '"')
    inst_label    = str(all_results[0]['data'].get('groupB', {}).get('instances', 24)) if all_results else '24'
    stream_note   = ('Peak STREAM bandwidth: ' + str(stream_peak) + ' GB/s') if stream_peak else 'STREAM benchmark not yet run.'
    frame_mb_str  = str(round(FRAME_MB, 1))

    html = (
        '<!DOCTYPE html>\n'
        '<html lang="zh-CN">\n'
        '<head>\n'
        '<meta charset="UTF-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        '<title>FFmpeg Memory BW - Multi-Channel Comparison</title>\n'
        '<style>' + DARK_CSS + '</style>\n'
        '</head>\n'
        '<body>\n'
        '<div class="header"><div class="container">\n'
        '  <div>\n'
        '    <h1>FFmpeg Memory Bandwidth - Channel Comparison</h1>\n'
        '    <div style="color:#8b949e;margin-top:4px;">'
        'AMD EPYC 9T24 (Genoa/Zen4) &bull; ' + str(len(all_results)) + ' configurations tested &bull; ' + now_str +
        '</div>\n'
        '  </div>\n'
        '  <div><span class="badge orange">Multi-Channel</span></div>\n'
        '</div></div>\n'
        '<nav class="nav"><ul>\n'
        '  <li><a href="#" onclick="show(\'summary\',this);return false;">Summary</a></li>\n'
        '  <li><a href="#" onclick="show(\'throughput\',this);return false;">Throughput</a></li>\n'
        '  <li><a href="#" onclick="show(\'bandwidth\',this);return false;">DRAM BW</a></li>\n'
        '  <li><a href="#" onclick="show(\'efficiency\',this);return false;">Efficiency</a></li>\n'
        '  <li><a href="#" onclick="show(\'analysis\',this);return false;">Key Findings</a></li>\n'
        '  <li><a href="#" onclick="show(\'scene-analysis\',this);return false;">场景对比分析</a></li>\n'
        '  <li><a href="#" onclick="show(\'cpu-baseline\',this);return false;">CPU能力参考</a></li>\n'
        '  <li><a href="#" onclick="show(\'recommendation\',this);return false;">减配建议</a></li>\n'
        '</ul></nav>\n'
        '<div class="container">\n'
        '\n'
        '<section id="summary" class="section">\n'
        '<h2>Performance Summary</h2>\n'
        '<div class="card-grid">\n'
        '  <div class="metric-card"><div class="value">' + str(best_ch) + '</div><div class="unit">channels</div><div class="label">Best Configuration</div></div>\n'
        '  <div class="metric-card"><div class="value">' + str(round(best_fps, 1)) + '</div><div class="unit">FPS</div><div class="label">Peak Total Throughput</div></div>\n'
        '  <div class="metric-card"><div class="value">' + str(len(channels_list)) + '</div><div class="unit">configs</div><div class="label">Tested Configurations</div></div>\n'
        '  <div class="metric-card"><div class="value">' + str(round(max(dram_bw) if dram_bw else 0, 1)) + '</div><div class="unit">GB/s</div><div class="label">Peak Est. DRAM BW</div></div>\n'
        '</div>\n'
        '<div class="card"><h3>Complete Results Table</h3>\n'
        '<table><thead><tr>'
        '<th>Channels</th><th>Single FPS (A)</th><th>Total FPS ' + inst_label + 'x (B)</th>'
        '<th>Avg FPS/inst (B)</th><th>x264 Total (D)</th><th>Est. DRAM BW (GB/s)</th><th>FPS/Channel (B)</th>'
        '</tr></thead><tbody>' + table_rows + '</tbody></table></div>\n'
        '</section>\n'
        '\n'
        '<section id="throughput" class="section">\n'
        '<h2>Transcoding Throughput vs Memory Channels</h2>\n'
        '<div class="chart-wrap"><div class="chart-title">Total FPS - All Groups</div>'
        '<div class="chart-legend" id="leg-fps"></div><canvas id="chart-fps"></canvas></div>\n'
        '<div class="chart-wrap"><div class="chart-title">Average FPS per Instance (Group B x265 medium)</div>'
        '<div class="chart-legend" id="leg-fps-avg"></div><canvas id="chart-fps-avg"></canvas></div>\n'
        '</section>\n'
        '\n'
        '<section id="bandwidth" class="section">\n'
        '<h2>Estimated DRAM Bandwidth Utilization</h2>\n'
        '<div class="chart-wrap"><div class="chart-title">Estimated DRAM Read Bandwidth</div>'
        '<div class="chart-legend" id="leg-bw"></div><canvas id="chart-bw"></canvas></div>\n'
        '<div class="card"><h3>Bandwidth Estimation Method</h3>\n'
        '<p>Each 4K YUV420p frame = 3840 x 2160 x 1.5 bytes = ' + frame_mb_str + ' MB</p>\n'
        '<p>Estimated DRAM Read (GB/s) = Total_FPS x ' + frame_mb_str + ' MB / 1024</p>\n'
        '<p style="color:#8b949e;margin-top:8px;">' + stream_note + '</p>\n'
        '</div>\n'
        '</section>\n'
        '\n'
        '<section id="efficiency" class="section">\n'
        '<h2>Memory Channel Efficiency</h2>\n'
        '<div class="chart-wrap"><div class="chart-title">FPS per Memory Channel (Group B)</div>'
        '<div class="chart-legend" id="leg-eff"></div><canvas id="chart-eff"></canvas></div>\n'
        '</section>\n'
        '\n'
        '<section id="analysis" class="section">\n'
        '<h2>Key Findings</h2>\n'
        '<div class="card"><h3>Best Configuration</h3>\n'
        '<p>Highest throughput at <span class="highlight">' + str(best_ch) + ' channels</span> '
        'with <span class="highlight">' + str(round(best_fps, 1)) + ' total FPS</span>.</p>\n'
        '</div>\n'
        '<div class="card"><h3>Channel Scaling</h3>\n'
        '<table><thead><tr><th>From</th><th>To</th><th>FPS Delta</th><th>Scaling</th></tr></thead>'
        '<tbody>' + scale_rows + '</tbody></table></div>\n'
        '<div class="card"><h3>Methodology</h3>\n'
        '<ul style="padding-left:20px;line-height:2;">\n'
        '<li>Input: 4K (3840x2160) YUV420p 30fps from /dev/shm</li>\n'
        '<li>Encoder: libx265 preset medium, ref=5, bframes=3</li>\n'
        '<li>Parallelism: ' + inst_label + ' instances (1 per CCD), each ' + str(all_results[0]['data'].get('meta', {}).get('threads_per_instance', 16) if all_results else 16) + ' threads, numactl bound</li>\n'
        '<li>NUMA: instances distributed round-robin across NUMA nodes</li>\n'
        '</ul></div>\n'
        '</section>\n'
        '\n'
        '<section id="scene-analysis" class="section">\n'
        '<h2>场景对比分析</h2>\n'
        '<div class="card">\n'
        '<h3>各组 FPS 汇总（通道数 x 场景）</h3>\n'
        + _build_scene_table(all_results, channels_list, fps_a_series, fps_b_total, fps_c_total,
                              fps_d_total, fps_e_total, fps_f_total, fps_g_total) +
        '</div>\n'
        '<div class="chart-wrap"><div class="chart-title">各场景 FPS 最大降幅（最高通道-最低通道）</div>'
        '<div class="chart-legend" id="leg-drop"></div><canvas id="chart-drop"></canvas></div>\n'
        '</section>\n'
        '\n'
        '<section id="cpu-baseline" class="section">\n'
        '<h2>CPU能力参考（单路基准）</h2>\n'
        '<div class="card">\n'
        '<p>Group A 单实例基准（4K x265 medium，无内存竞争，numactl node0）：</p>\n'
        '<div style="display:flex;gap:32px;margin:12px 0;">\n'
        '<div class="metric-card" style="text-align:center;">'
        '<div class="value">' + str(round(fps_a_series[-1] if fps_a_series else 0, 1)) + '</div>'
        '<div class="unit">FPS</div><div class="label">A组单实例（最高通道数）</div></div>\n'
        '<div class="metric-card" style="text-align:center;">'
        '<div class="value">' + str(round((fps_a_series[-1] if fps_a_series else 0) * (all_results[-1]['data'].get('groupB',{}).get('instances',24) if all_results else 24), 1)) + '</div>'
        '<div class="unit">FPS</div><div class="label">理论CPU峰值（x实例数）</div></div>\n'
        '</div>\n'
        '<p style="color:#8b949e;">理论CPU峰值代表无内存瓶颈时的编码上限。'
        'B组实测总FPS与此值的差距即为内存带宽瓶颈导致的损失。</p>\n'
        '</div>\n'
        '</section>\n'
        '\n'
        '<section id="recommendation" class="section">\n'
        '<h2>内存减配建议</h2>\n'
        + _build_recommendation_table(all_results, channels_list,
                                       fps_b_total, fps_c_total, fps_d_total,
                                       fps_e_total, fps_f_total, fps_g_total) +
        '</section>\n'
        '\n'
        '</div>\n'
        '<footer><div class="container">FFmpeg Memory Bandwidth Benchmark &bull; AMD EPYC 9T24 96-Core x2 &bull; ' + now_str + '</div></footer>\n'
        '<script>\n' + NAV_JS + '\n' + CHART_JS + '\n'
        'window.onload = function() {\n'
        '  document.querySelector(\'.nav a\').click();\n'
        '  var labels = ' + js_labels + ';\n'
        '  drawLineChart(\'chart-fps\', \'leg-fps\', labels, [\n'
        '    {label:\'Group A (single x265)\', data:' + js_arr(fps_a_series) + '},\n'
        '    {label:\'Group B 4K x265 medium\', data:' + js_arr(fps_b_total) + '},\n'
        '    {label:\'Group C 4K x265 slow\', data:' + js_arr(fps_c_total) + ', dashed:true},\n'
        '    {label:\'Group D 4K x264 medium\', data:' + js_arr(fps_d_total) + ', dashed:true},\n'
        '    {label:\'Group E decode\', data:' + js_arr(fps_e_total) + ', dashed:true},\n'
        '    {label:\'Group F 1080p ultrafast\', data:' + js_arr(fps_f_total) + ', dashed:true},\n'
        '    {label:\'Group G 4K slow ref=8\', data:' + js_arr(fps_g_total) + ', dashed:true}\n'
        '  ], \'FPS\');\n'
        '  drawLineChart(\'chart-fps-avg\', \'leg-fps-avg\', labels, [\n'
        '    {label:\'Avg FPS/instance (B)\', data:' + js_arr(fps_b_avg_lst) + '}\n'
        '  ], \'FPS/instance\');\n'
        '  drawBarChart(\'chart-bw\', \'leg-bw\', labels, [\n'
        '    {label:\'Estimated DRAM Read (GB/s)\', data:' + js_arr(dram_bw) + '}\n'
        '  ], \'GB/s\');\n'
        '  drawBarChart(\'chart-eff\', \'leg-eff\', labels, [\n'
        '    {label:\'FPS per Channel (B)\', data:' + js_arr(efficiency) + '}\n'
        '  ], \'FPS/ch\');\n'
        + _build_drop_chart_js(fps_b_total, fps_c_total, fps_d_total,
                                fps_e_total, fps_f_total, fps_g_total) +
        '};\n'
        '</script>\n'
        '</body>\n'
        '</html>\n'
    )
    return html


def main():
    args = parse_args()

    if args.mode == 'single':
        if not args.result_dir:
            print('ERROR: --result-dir required for single mode', file=sys.stderr)
            sys.exit(1)
        html = build_single_report(args.result_dir, args.stream_peak)
        out = args.output or os.path.join(args.result_dir, 'report.html')
        with open(out, 'w', encoding='utf-8') as f:
            f.write(html)
        print('Report written: ' + out)

    elif args.mode == 'multi':
        results_dir = args.results_dir
        all_results = collect_multi_results(results_dir)
        if not all_results:
            print('No channel result directories found in ' + results_dir, file=sys.stderr)
            print('Expected format: results/Nch_TIMESTAMP/')
            sys.exit(1)
        print('Found ' + str(len(all_results)) + ' configurations: ' + str([r['channels'] for r in all_results]))
        perf_baseline = load_perf_baseline(getattr(args, 'perf_baseline', ''))
        html = build_multi_report(all_results, args.stream_peak)
        out = args.output or os.path.join(results_dir, 'multi_channel_comparison.html')
        with open(out, 'w', encoding='utf-8') as f:
            f.write(html)
        print('Comparison report written: ' + out)


if __name__ == '__main__':
    main()
