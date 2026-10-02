#!/usr/bin/env python3
"""Postprocess validated receipts on identical emitted-frame indices, without rebuilding."""
import argparse
import collections
import hashlib
import json
import pathlib


def quantile(values, fraction=.5):
    values = sorted(v for v in values if v is not None)
    return values[min(len(values)-1, int((len(values)-1)*fraction))] if values else None


def fmt(value, digits=2):
    return '—' if value is None else f'{value:.{digits}f}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('receipts', type=pathlib.Path, nargs='+')
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    output = ['# Matched-frame codec comparison', '',
              'Run codec-ab-report.py first to validate the complete matrices. Fidelity and callback cost below use only frame indices emitted and decoded by both codecs. These samples may still favor easy frames; counts are explicit.',
              'Held PSNR uses each offered media-timeline frame against its decoded output or recorded last-decoded hold. It is a synthetic coasting proxy, not observed phone presentation. Encoded Mb/s per media duration divides total encoded bytes by media-timeline duration, not measured transport throughput.',
              'Each missing encode waits up to 250 ms in the harness, so wall-clock submission schedules diverge after drops. Neither drop fraction nor callback latency establishes achieved live FPS.', '',
              f'Analysis SHA256: `{hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()}`', '',
              '| Mode | Geometry | Target Mb/s | Repeat | Common frames (still/scroll/video/mixed) | Codec | Common text SSIM p50 | Common PSNR Y p50 | Held PSNR Y p10/p50 (coverage) | Common encode p50/p90 ms | Common decode p50/p90 ms | Encoded Mb/s at media FPS | Drops | Thermal before/after |',
              '|---|---|---:|---:|---:|---|---:|---:|---|---:|---:|---:|---:|---|']
    phase_output = ['', '## Common frames by content', '',
                    '| Mode | Geometry | Target Mb/s | Repeat | Content | Common/offered | Codec | Text SSIM p50 | PSNR Y p50 | Encode p50/p90 ms | Decode p50/p90 ms |',
                    '|---|---|---:|---:|---|---:|---|---:|---:|---:|---:|']
    for receipt in args.receipts:
        records = [json.loads(line) for line in receipt.read_text().splitlines() if line]
        meta = next(x for x in records if x['kind'] == 'meta')
        aggregates = {x['run']: x for x in records if x['kind'] == 'aggregate'}
        expected = {f'{case}-r{r+1}' for case in meta['caseLabels'] for r in range(meta['repeatCount'])}
        if set(aggregates) != expected:
            raise ValueError('Incomplete matrix; validate full receipts first')
        frames = collections.defaultdict(dict)
        pairs = collections.defaultdict(dict)
        for row in records:
            if row['kind'] == 'frame':
                frames[row['run']][row['index']] = row
        for run, row in aggregates.items():
            pairs[(row['geometry'], row['kbps'], run.rsplit('-r', 1)[1])][row['codec']] = row
        for (geometry, kbps, repeat), pair in pairs.items():
            if set(pair) != {'H264', 'H265'}:
                raise ValueError('Unpaired codec point')
            timelines = {codec: frames[row['run']] for codec, row in pair.items()}
            for codec, row in pair.items():
                if set(timelines[codec]) != set(range(row['frames'])):
                    raise ValueError('Incomplete timeline')
                if row['decodeMissing'] or row['wrongTimestamp'] or row['wrongDimensions']:
                    raise ValueError('Invalid decoded frame')
            if any(timelines['H264'][i]['sourceHash'] != timelines['H265'][i]['sourceHash'] for i in timelines['H264']):
                raise ValueError('Different source')
            emitted = {codec: {i for i, frame in timeline.items()
                               if not frame.get('encodeMissing', False) and not frame.get('decodeMissing', False)}
                       for codec, timeline in timelines.items()}
            common = sorted(emitted['H264'] & emitted['H265'])
            phases = ['still', 'scroll-reverse', 'video', 'mixed']
            composition = collections.Counter(timelines['H264'][i]['phase'] for i in common)
            counts = '/'.join(str(composition[p]) for p in phases)
            for codec in ['H264', 'H265']:
                row, timeline = pair[codec], timelines[codec]
                fs = [timeline[i] for i in common]
                held = [frame.get('psnrY') if frame.get('psnrY') is not None else frame.get('heldPSNRY')
                        for frame in timeline.values()]
                coverage = sum(v is not None for v in held)
                ep, dp = [f.get('encodeMs') for f in fs], [f.get('decodeMs') for f in fs]
                mbps = row['totalBytes']*8*meta['fps']/row['frames']/1_000_000
                output.append(f"| {meta['mode']} | {geometry} | {kbps/1000:g} | {repeat} | {len(common)}/{row['frames']} ({counts}) | {codec} | {fmt(quantile([f.get('textSSIM') for f in fs]),4)} | {fmt(quantile([f.get('psnrY') for f in fs]))} | {fmt(quantile(held,.1))}/{fmt(quantile(held))} ({coverage}/{row['frames']}) | {fmt(quantile(ep))}/{fmt(quantile(ep,.9))} | {fmt(quantile(dp))}/{fmt(quantile(dp,.9))} | {mbps:.2f} | {row['encodeMissing']} | {row['thermalBefore']}/{row['thermalAfter']} |")
                for phase in phases:
                    pf = [f for f in fs if f['phase'] == phase]
                    offered = sum(f['phase'] == phase for f in timeline.values())
                    pe, pd = [f.get('encodeMs') for f in pf], [f.get('decodeMs') for f in pf]
                    phase_output.append(f"| {meta['mode']} | {geometry} | {kbps/1000:g} | {repeat} | {phase} | {len(pf)}/{offered} | {codec} | {fmt(quantile([f.get('textSSIM') for f in pf]),4)} | {fmt(quantile([f.get('psnrY') for f in pf]))} | {fmt(quantile(pe))}/{fmt(quantile(pe,.9))} | {fmt(quantile(pd))}/{fmt(quantile(pd,.9))} |")
        output.extend(['', f'Receipt SHA256: `{receipt}` = `{hashlib.sha256(receipt.read_bytes()).hexdigest()}`', ''])
    args.output.write_text('\n'.join(output+phase_output)+'\n')


if __name__ == '__main__':
    main()
