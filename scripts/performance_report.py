#!/usr/bin/env python3
"""Summarize real-input interaction latency; incomplete renders stay visible."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import math


def percentile(values, fraction):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * fraction) - 1)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', nargs='?', type=Path,
                        default=Path.home() / 'Library/Logs/LLMCostBar')
    parser.add_argument('--session', help='Only this session UUID')
    args = parser.parse_args()
    groups = defaultdict(list)
    incomplete = defaultdict(int)
    refreshes = defaultdict(list)
    sessions = {}
    bad = 0
    for path in args.directory.glob('performance*.jsonl'):
        for line in path.read_text().splitlines():
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                bad += 1
                continue
            if args.session and row.get('session') != args.session:
                continue
            build = row.get('build', 'unknown')
            sessions[row['session']] = build
            if row['event'] == 'interaction':
                key = (build, row['action'], row['input'], row['endpoint'])
                groups[key].append(row)
            elif row['event'] == 'interaction_incomplete':
                incomplete[(build, row['action'], row['reason'])] += 1
            elif row['event'] == 'refresh':
                refreshes[build].append(float(row['duration_ms']))
    print('Click/key event → first display refresh after drawing pass (render proxy, ms)')
    print(f'{"Build / action / input":65} {"N":>4} {"p50":>8} {"p95":>8} {"max":>8} {"queue p95":>10} {"draw p95":>11}')
    for key, rows in sorted(groups.items()):
        render = [float(r['render_proxy_ms']) for r in rows]
        queue = [float(r['queue_ms']) for r in rows]
        update = [float(r['draw_pass_ms']) for r in rows]
        print(f'{" / ".join(key[:3]):65} {len(rows):4} {percentile(render, .5):8.2f} {percentile(render, .95):8.2f} {max(render):8.2f} {percentile(queue, .95):10.2f} {percentile(update, .95):11.2f}')
        released = [float(r['release_to_render_ms']) for r in rows if 'release_to_render_ms' in r]
        if released:
            print(f'  After mouse release: n={len(released)}, p50={percentile(released, .5):.2f} ms, p95={percentile(released, .95):.2f} ms')
    if not groups:
        print('No completed interactions recorded yet. Open the popup and switch tabs.')
    for key, count in sorted(incomplete.items()):
        print(f'Incomplete: {" / ".join(key)} = {count} (excluded from latency percentiles)')
    for build, values in sorted(refreshes.items()):
        print(f'Refresh {build}: n={len(values)}, p50={percentile(values, .5):.2f} ms, p95={percentile(values, .95):.2f} ms')
    for session, build in sorted(sessions.items()):
        print(f'Session: {session} ({build})')
    if bad:
        print(f'Skipped {bad} partial/malformed lines.')


if __name__ == '__main__':
    main()
