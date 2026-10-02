#!/usr/bin/env python3
"""Summarize opt-in couchTiming host logs; never treat missing clock data as zero.

Input may be `log show --style ndjson` or text. Jitter means absolute difference
between consecutive host gaps and their corresponding calibrated phone-send gaps.
Idle gaps (>150ms at the phone) and retries/reordered ordinals are excluded.
Posting time brackets driver/CGEvent submission, not WindowServer presentation.
"""
import argparse
import json
import math
import re
from collections import defaultdict
from pathlib import Path


def parse(lines):
    rows = []
    for line in lines:
        if line.lstrip().startswith('{'):
            try:
                line = json.loads(line).get('eventMessage', '')
            except (ValueError, AttributeError):
                continue
        if 'couchTiming stage=' not in line:
            continue
        row = dict(re.findall(r'(\w+)=([^\s]+)', line))
        for key in ['applied', 'first', 'send', 'uncertainty', 'arrival', 'main', 'at', 'end', 'accepted',
                    'sample', 'callback', 'offer', 'sourceArrival']:
            if key in row:
                try:
                    row[key] = float(row[key])
                except ValueError:
                    row[key] = math.nan
        rows.append(row)
    return rows


def valid(row, *keys):
    return all(isinstance(row.get(k), (int, float)) and math.isfinite(row[k]) and row[k] >= 0 for k in keys)


def percentiles(values):
    values = sorted(v for v in values if math.isfinite(v) and v >= 0)
    def rank(q):
        return round(values[max(0, math.ceil(len(values) * q) - 1)], 3) if values else None
    return {'n': len(values), 'p50Ms': rank(.5), 'p90Ms': rank(.9), 'maxMs': round(values[-1], 3) if values else None}


def summarize(rows):
    arrivals = defaultdict(list)
    posts = defaultdict(list)
    for r in rows:
        if r.get('stage') == 'arrival' and valid(r, 'applied', 'first', 'arrival', 'main'):
            arrivals[r.get('key', '')].append(r)
        elif r.get('stage') == 'post' and r.get('accepted') == 1 and valid(r, 'applied', 'at', 'end'):
            posts[r.get('key', '')].append(r)
    delays, dispatch, post_cost, arrival_jitter, post_jitter, uncertainty = [], [], [], [], [], []
    arrival_gaps, post_gaps, send_gaps, added, send_to_post = [], [], [], [], []
    lanes = defaultdict(int)
    touch_delays, pump_delays = [], []
    permission_cost = defaultdict(list)
    unmatched_posts = 0
    for r in rows:
        if r.get('stage') == 'touch' and valid(r, 'sample', 'callback') and r['callback'] >= r['sample']:
            touch_delays.append(r['callback'] - r['sample'])
        if r.get('stage') == 'pump' and valid(r, 'offer', 'at') and r['at'] >= r['offer']:
            pump_delays.append(r['at'] - r['offer'])
        if r.get('stage') == 'permission' and valid(r, 'at', 'end') and r['end'] >= r['at']:
            permission_cost[r.get('api', 'unknown')].append(r['end'] - r['at'])
    for key in arrivals.keys() | posts.keys():
        group = arrivals[key]
        group.sort(key=lambda r: r['arrival'])
        matched = []
        previous = None
        highest = -1
        for r in group:
            lanes[r.get('lane', 'unknown')] += 1
            dispatch.append(max(0, r['main'] - r['arrival']))
            if valid(r, 'send', 'uncertainty') and 0 <= r['arrival'] - r['send'] <= 30_000:
                delays.append(r['arrival'] - r['send'])
                uncertainty.append(r['uncertainty'])
            # A retry/old prefix does not represent new finger movement.
            if r['applied'] <= highest:
                continue
            highest = r['applied']
            if previous and valid(previous, 'send') and valid(r, 'send'):
                sg = r['send'] - previous['send']
                if 0 < sg <= 150:
                    ag = r['arrival'] - previous['arrival']
                    send_gaps.append(sg); arrival_gaps.append(ag)
                    arrival_jitter.append(abs(ag - sg))
            previous = r
        for p in sorted(posts[key], key=lambda r: r['at']):
            # Exact original callback stamp: a newer superset prefix can arrive
            # while an older post is queued. Never attribute its post to that peer.
            candidates = [r for r in group if valid(p, 'sourceArrival') and r['arrival'] == p['sourceArrival']
                          and r['first'] <= p['applied'] <= r['applied'] and r['main'] <= p['at']]
            if len(candidates) != 1:
                unmatched_posts += 1
                continue
            r = candidates[0]
            added.append(p['at'] - r['arrival']); post_cost.append(p['end'] - p['at'])
            if valid(r, 'send') and p['at'] >= r['send']:
                send_to_post.append(p['at'] - r['send'])
            matched.append((p, r))
        for (p0, r0), (p1, r1) in zip(matched, matched[1:]):
            if p1['applied'] <= p0['applied'] or r1['applied'] == r0['applied']:
                continue
            if valid(r0, 'send') and valid(r1, 'send'):
                sg = r1['send'] - r0['send']
                if 0 < sg <= 150:
                    pg = p1['at'] - p0['at']
                    post_gaps.append(pg); post_jitter.append(abs(pg - sg))
    return {'units': 'milliseconds', 'scope': 'driver submission; physical pointer presentation unmeasured',
            'lanes': dict(lanes), 'unmatchedOrAmbiguousPosts': unmatched_posts, 'phoneSendGap': percentiles(send_gaps),
            'hostArrivalGap': percentiles(arrival_gaps), 'hostPostGap': percentiles(post_gaps),
            'arrivalJitterVsSendGap': percentiles(arrival_jitter), 'postJitterVsSendGap': percentiles(post_jitter),
            'sendToArrival': percentiles(delays), 'arrivalToMain': percentiles(dispatch),
            'arrivalToPost': percentiles(added), 'sendToPost': percentiles(send_to_post),
            'postCost': percentiles(post_cost), 'clockUncertainty': percentiles(uncertainty),
            'phoneTouchToCallback': percentiles(touch_delays), 'phoneOfferToSend': percentiles(pump_delays),
            'permissionCost': {api: percentiles(costs) for api, costs in permission_cost.items()}}


if __name__ == '__main__':
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('log', type=Path)
    args = cli.parse_args()
    print(json.dumps(summarize(parse(args.log.read_text().splitlines())), indent=2))
