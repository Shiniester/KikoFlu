#!/usr/bin/env python3
"""Check that native mpv control values survive HLS input-rate changes."""

import argparse
import json
import math
from pathlib import Path

from native import probe, run
from runtime_graphs import CHANNEL_MODE_TARGET, channel_mode_graph


FIXTURE_DIR = Path(__file__).resolve().parent / 'fixtures' / 'hls-fs-change'
AO_RATE = 48000
EXPECTED_RATES = (44100, 96000, 44100, 96000)
EXPECTED_MODES = (0, 3, 1, 2, 3)
MODE_RATE_SCALE = 100000
DIAGNOSTIC_TOLERANCE = 0.005
MIN_STABLE_FRAMES = 128
VALID_STATES = tuple((mode, rate) for mode in range(4) for rate in (44100, 96000))
STATE_CODES = tuple((state, state[0] + state[1] / MODE_RATE_SCALE) for state in VALID_STATES)


def make_playlist(output_dir):
    fixture_playlist = FIXTURE_DIR / 'switch.m3u8'
    segments = ('0.aac', '1.aac')
    if not fixture_playlist.is_file() or any(not (FIXTURE_DIR / name).is_file() for name in segments):
        raise RuntimeError(f'HLS fixture is incomplete: {FIXTURE_DIR}')
    listed_segments = [line.strip() for line in fixture_playlist.read_text(encoding='utf-8').splitlines()
                       if line.strip() and not line.startswith('#')]
    if listed_segments != list(segments):
        raise RuntimeError(f'HLS fixture must list {segments}, got {listed_segments}')
    for name in segments:
        (output_dir / f'control-cache-{name}').write_bytes((FIXTURE_DIR / name).read_bytes())

    playlist_segments = ('0.aac',) * 12 + ('1.aac', '0.aac', '1.aac')
    lines = ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:1', '#EXT-X-MEDIA-SEQUENCE:0']
    previous = None
    for name in playlist_segments:
        if previous is not None and name != previous:
            lines.append('#EXT-X-DISCONTINUITY')
        lines.extend(('#EXTINF:0.5,', f'control-cache-{name}'))
        previous = name
    lines.append('#EXT-X-ENDLIST')
    playlist = output_dir / 'control-cache-fs-switch.m3u8'
    playlist.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return playlist


def native_errors(report):
    return [row for row in report.get('logs', [])
            if row.get('level') in ('error', 'fatal')]


def native_ok(report, allowed_error_marker=None):
    errors = native_errors(report)
    unexpected_errors = [row for row in errors
                         if allowed_error_marker is None or
                         allowed_error_marker not in row.get('text', '')]
    return (not unexpected_errors and
            report.get('process', {}).get('return_code') == 0 and
            report.get('end_file') == {'reason': 0, 'error': 0} and
            report.get('initialized_handles') == 1 and
            sum(row[0] == probe.FILE_LOADED for row in report.get('events', [])) == 1 and
            report.get('ao_closed') is True and not report.get('timed_out', False))


def classify_diagnostic(value):
    if not math.isfinite(value):
        return None
    state, code = min(STATE_CODES, key=lambda candidate: abs(value - candidate[1]))
    return state if abs(value - code) <= DIAGNOSTIC_TOLERANCE else None


def runs(values):
    result = []
    for index, value in enumerate(values):
        if not result or result[-1][2] != value:
            if result:
                result[-1][1] = index
            result.append([index, None, value])
    if result:
        result[-1][1] = len(values)
    return result


def analyze_diagnostic(values):
    classified = [classify_diagnostic(value) for value in values]
    plateaus = []
    transients = []
    for start, end, state in runs(classified):
        samples = [value for value in values[start:end] if math.isfinite(value)]
        record = {
            'start': start,
            'end': end,
            'frames': end - start,
            'mode': state[0] if state is not None else None,
            'sample_rate': state[1] if state is not None else None,
            'raw_min': min(samples) if samples else None,
            'raw_max': max(samples) if samples else None,
        }
        if state is not None and record['frames'] >= MIN_STABLE_FRAMES:
            plateaus.append(record)
        else:
            transients.append(record)
    finite_values = [value for value in values if math.isfinite(value)]
    return {
        'frames': len(values),
        'raw_min': min(finite_values) if finite_values else None,
        'raw_max': max(finite_values) if finite_values else None,
        'transient_frames': sum(record['frames'] for record in transients),
        'transient_runs': transients,
        'plateaus': plateaus,
    }


def check_synthetic_diagnostics():
    def code(mode, rate):
        return mode + rate / MODE_RATE_SCALE

    def ringing(start, end):
        return [end + (start - end) * math.exp(-index / 12) * math.cos(index * 0.7)
                for index in range(96)]

    normal_44 = code(0, 44100)
    clone_44 = code(3, 44100)
    clone_96 = code(3, 96000)
    healthy = analyze_diagnostic(
        [normal_44] * 256 + ringing(normal_44, clone_44) + [clone_44] * 256 +
        ringing(clone_44, clone_96) + [clone_96] * 256)
    healthy_states = [(row['mode'], row['sample_rate']) for row in healthy['plateaus']]
    if healthy_states != [(0, 44100), (3, 44100), (3, 96000)] or healthy['transient_frames'] == 0:
        raise RuntimeError('synthetic diagnostic ringing check failed')

    reset_96 = code(0, 96000)
    reset = analyze_diagnostic(
        [normal_44] * 256 + ringing(normal_44, clone_44) + [clone_44] * 256 +
        ringing(clone_44, reset_96) + [reset_96] * 256)
    reset_states = [(row['mode'], row['sample_rate']) for row in reset['plateaus']]
    first_new_rate = next((row for row in reset['plateaus'] if row['sample_rate'] == 96000), None)
    if (reset_states != [(0, 44100), (3, 44100), (0, 96000)] or
            first_new_rate is None or first_new_rate['mode'] == 3):
        raise RuntimeError('synthetic diagnostic reset check failed to detect stable normal mode')


def main():
    check_synthetic_diagnostics()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libmpv', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    library = args.libmpv.resolve()
    if not library.is_file():
        parser.error(f'--libmpv does not exist: {library}')
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    playlist = make_playlist(output.parent)

    graph = channel_mode_graph(mode=0, diagnostic=True)
    old_tail = "|val(2)':c=5.0,"
    if graph.count(old_tail) != 1:
        raise RuntimeError('channel mode graph diagnostic output changed unexpectedly')
    graph = graph.replace(old_tail, "|val(2)+s/100000':c=5.0,", 1)
    baseline_report, baseline = run(
        output.parent, library, 'control_cache_baseline', graph, [], AO_RATE,
        source_url=str(playlist), demuxer_format='hls', actions=((0, ['set', 'volume', '100']),),
        output_channels=5, timeout=20)
    action_values = (('3', 0.2), ('1', 1.2), ('2', 2.2), ('3', 3.2),
                     ('native_cache_invalid', 4.2))
    actions = tuple((when, ['af-command', 'effects', 'volume', value, CHANNEL_MODE_TARGET])
                    for value, when in action_values)
    controlled_report, controlled = run(
        output.parent, library, 'control_cache_controlled', graph, [], AO_RATE,
        source_url=str(playlist), demuxer_format='hls', output_channels=5,
        actions=actions, timeout=20)

    baseline_errors = native_errors(baseline_report)
    controlled_errors = native_errors(controlled_report)
    intentional_invalid_errors = [row for row in controlled_errors
                                  if 'native_cache_invalid' in row.get('text', '')]
    baseline_ok = (native_ok(baseline_report) and len(baseline) > 0 and
                   len(baseline_report.get('actions', [])) == 1 and
                   baseline_report['actions'][0].get('reply_error') == 0 and
                   all(math.isfinite(value) for row in baseline for value in row))
    same_frame_count = len(baseline) > 0 and len(controlled) == len(baseline)
    controlled_ok = native_ok(controlled_report, 'native_cache_invalid') and same_frame_count
    baseline_diagnostic = analyze_diagnostic([row[4] for row in baseline])
    controlled_diagnostic = analyze_diagnostic([row[4] for row in controlled])
    states = controlled_diagnostic['plateaus']
    rates = []
    modes = []
    for state in states:
        mode, rate = state['mode'], state['sample_rate']
        if not rates or rates[-1] != rate:
            rates.append(rate)
        if not modes or modes[-1] != mode:
            modes.append(mode)

    action_reports = controlled_report.get('actions', [])
    valid_actions = action_reports[:4]
    invalid_action = action_reports[4] if len(action_reports) == 5 else {}

    def attempts_ok(action, expected_reply):
        attempts = action.get('attempts', [])
        if not attempts or attempts[0].get('target') != CHANNEL_MODE_TARGET:
            return False
        if (len(attempts) > 2 or action.get('reply_error') != expected_reply or
                attempts[-1].get('reply_error') != expected_reply):
            return False
        if len(attempts) == 1:
            return attempts[0].get('reply_error') != -12
        return (attempts[0].get('reply_error') == -12 and
                attempts[1].get('target') == CHANNEL_MODE_TARGET.split('@', 1)[1])

    valid_commands_ok = (len(valid_actions) == 4 and
                         all(attempts_ok(action, 0) for action in valid_actions))
    invalid_command_error = invalid_action.get('reply_error')
    invalid_command_ok = (len(action_reports) == 5 and
                          attempts_ok(invalid_action, invalid_command_error) and
                          isinstance(invalid_command_error, int) and invalid_command_error < 0)

    expected_state_runs = [(row['mode'], row['sample_rate']) for row in states]
    expected_runs = [(0, 44100), (3, 44100), (1, 44100), (2, 44100), (3, 44100),
                     (3, 96000), (3, 44100), (3, 96000)]
    first_switch = next((row for row in states if row['sample_rate'] != 44100), None)
    suffix_error = None
    suffix_clones_right = False
    if same_frame_count and first_switch is not None:
        suffix_error = max((abs(controlled[index][channel] - baseline[index][1])
                            for index in range(first_switch['start'], len(baseline))
                            for channel in (0, 1)), default=None)
        later_plateaus = [row for row in states if row['start'] >= first_switch['start']]
        suffix_clones_right = bool(first_switch['mode'] == 3 and later_plateaus and
                                   all(row['mode'] == 3 for row in later_plateaus))

    controlled_ok = (controlled_ok and all(math.isfinite(value) for row in controlled for value in row) and
                      valid_commands_ok and invalid_command_ok and
                      tuple(rates) == EXPECTED_RATES and tuple(modes) == EXPECTED_MODES and
                      expected_state_runs == expected_runs and first_switch is not None and
                      suffix_clones_right and suffix_error == 0.0)
    passed = baseline_ok and controlled_ok
    args.output.write_text(json.dumps({
        'gate_status': 'pass' if passed else 'fail',
        'source': 'committed AAC HLS fixture, first segment repeated 12 times before 96/44.1/96 kHz changes',
        'ao_sample_rate': AO_RATE,
        'baseline': {
            'passed': baseline_ok,
            'frames': len(baseline),
            'diagnostic_channel': 5,
            'raw_pcm': 'control_cache_baseline.pcm',
            'native_errors': baseline_errors,
            'diagnostic': baseline_diagnostic,
            'native': baseline_report,
        },
        'controlled': {
            'passed': controlled_ok,
            'frames': len(controlled),
            'expected_frames_from_baseline': len(baseline),
            'diagnostic_channel': 5,
            'raw_pcm': 'control_cache_controlled.pcm',
            'diagnostic': controlled_diagnostic,
            'observed_input_sample_rates': rates,
            'observed_control_modes': modes,
            'stable_state_runs': states,
            'first_rate_change_frame': first_switch['start'] if first_switch else None,
            'valid_control_replies': [action.get('reply_error') for action in valid_actions],
            'invalid_control_reply': invalid_command_error,
            'intentional_invalid_control_errors': intentional_invalid_errors,
            'unexpected_native_errors': [row for row in controlled_errors
                                         if row not in intentional_invalid_errors],
            'latest_clone_right_after_first_rate_change': suffix_clones_right,
            'suffix_max_error_to_baseline_right': suffix_error,
            'native': controlled_report,
        },
    }, indent=2), encoding='utf-8')
    print('control_cache_contract', passed, len(baseline), len(controlled), flush=True)
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__':
    main()
