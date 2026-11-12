"""Real PCM checks for the separate one-octave actual-Fs equalizer template."""
import argparse
import cmath
import json
import math
from pathlib import Path

from adaptive_eq import equalizer_auto_graph, EQ_PRESETS
from basic import EQ_FREQUENCIES, tone_amplitude
from native import run


def peaking_response(frequency, center, gain, rate):
    """Standard digital peaking-biquad response with a one-octave bandwidth.

    The bandwidth-to-alpha equation includes the bilinear frequency correction.
    It is independent of the native graph, coefficient commands, and FFmpeg code.
    Formula source: https://www.w3.org/TR/audio-eq-cookbook/ (peaking EQ, BW=1).
    """
    if gain == 0:
        return 1.
    b0, b1, b2, a0, a1, a2 = peaking_coefficients(center, gain, rate)
    z = cmath.exp(-2j*math.pi*frequency/rate)
    return abs((b0+b1*z+b2*z*z)/(a0+a1*z+a2*z*z))


def peaking_coefficients(center, gain, rate):
    center = max(10, min(rate*.45, center))
    omega = 2*math.pi*center/rate
    a = 10**(gain/40)
    alpha = math.sin(omega)*math.sinh(math.log(2)/2*omega/math.sin(omega))
    return 1+alpha*a, -2*math.cos(omega), 1-alpha*a, 1+alpha/a, -2*math.cos(omega), 1-alpha/a


def response_errors(actual, original, gains, frequencies, rate):
    # One full second gives coherent integer-Hz bins. Discard the first half
    # second to exclude the initial filter transient, including the 31 Hz band.
    reference = [row[0]/32768 for row in original[-rate:]]
    samples = [row[0] for row in actual[-rate:]]
    result = []
    for frequency in frequencies:
        measured = 20*math.log10(tone_amplitude(samples, frequency, rate)/
                                 tone_amplitude(reference, frequency, rate))
        expected = sum(20*math.log10(peaking_response(frequency, center, gain, rate))
                       for center, gain in zip(EQ_FREQUENCIES, gains))
        result.append({'frequency_hz':frequency, 'expected_db':expected, 'measured_db':measured,
                       'error_db':abs(measured-expected)})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--libmpv', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    checks = []
    cases = []
    for rate in (44100, 48000, 96000):
        gains = [0]*10
        gains[5] = 6
        cases.append((f'octave_1000_{rate}', rate, gains, (700, 1000, 1400)))
    gains = [0]*10
    gains[-1] = 6
    cases.append(('clamp_16000_to_7200', 16000, gains, (5760, 7200, 7560)))
    for name, gains in EQ_PRESETS.items():
        if name != 'flat':
            cases.append(('preset_'+name, 48000, gains, (*EQ_FREQUENCIES, 700, 1400)))
    for name, rate, gains, frequencies in cases:
        frames = [(round(100*sum(math.sin(2*math.pi*f*n/rate) for f in frequencies)),)*2
                  for n in range(rate*3//2+17)]
        report, actual = run(args.output.parent, args.libmpv.resolve(), name,
                             equalizer_auto_graph(gains), frames, rate)
        if len(actual) == len(frames):
            report['response'] = response_errors(actual, frames, gains, frequencies, rate)
            report['maximum_error_db'] = max(row['error_db'] for row in report['response'])
        report['passed'] = (native_ok(report, actual, frames) and report.get('maximum_error_db',math.inf)<.03
                            and all(left==right for left,right in actual))
        checks.append(report)
        print(name, report['passed'], len(actual), report.get('maximum_error_db'), flush=True)
    # A full impulse recurrence checks the initial frame, which steady-state
    # measurements intentionally omit. The safe 10 Hz placeholder must never
    # process that first impulse instead of the native 7200 Hz selected cutoff.
    frames = [(10000, -12000)] + [(0, 0)]*1616
    gains = [0]*9+[6]
    b0, b1, b2, a0, a1, a2 = peaking_coefficients(16000, 6, 16000)
    expected = []
    x1 = x2 = y1 = y2 = (0., 0.)
    for pair in frames:
        x = tuple(value/32768 for value in pair)
        y = tuple((b0*x[ch]+b1*x1[ch]+b2*x2[ch]-a1*y1[ch]-a2*y2[ch])/a0 for ch in (0, 1))
        expected.append(y)
        x1, x2, y1, y2 = x, x1, y, y1
    report, actual = run(args.output.parent, args.libmpv.resolve(), 'clamp_first_frame_impulse',
                         equalizer_auto_graph(gains), frames, 16000)
    report['maximum_error'] = (max(abs(a-b) for pair,ref in zip(actual,expected) for a,b in zip(pair,ref))
                               if len(actual)==len(expected) else math.inf)
    report['first_frame_error'] = max(abs(a-b) for a,b in zip(actual[0],expected[0])) if actual else math.inf
    report['passed'] = native_ok(report, actual, frames) and report['maximum_error']<1e-6
    checks.append(report)
    print(report['name'], report['passed'], len(actual), report['maximum_error'], flush=True)
    for rate in (16000, 44100, 48000, 96000):
        frames = [(round(11000*math.sin(n*.17)), round(7000*math.sin(n*.31)))
                  for n in range(rate//10+17)]
        report, actual = run(args.output.parent, args.libmpv.resolve(), f'octave_neutral_{rate}',
                             equalizer_auto_graph(EQ_PRESETS['flat']), frames, rate)
        report['maximum_error'] = (max(abs(value-original/32768) for pair,source in zip(actual,frames)
                                      for value,original in zip(pair,source)) if len(actual)==len(frames) else math.inf)
        report['passed'] = native_ok(report, actual, frames) and report['maximum_error']==0
        checks.append(report)
        print(report['name'], report['passed'], len(actual), report['maximum_error'], flush=True)
    args.output.write_text(json.dumps({'gate_status':'incomplete',
        'scope':'one-octave static curves and initial snapshot; runtime smoothing/resend not tested',
        # Same response budget as the existing EQ center checks. Keep unrelated
        # mpv warnings in the report; filter errors and invalid-frequency warnings fail.
        'response_budget_db':.03, 'neutral_budget':0, 'checks':checks},indent=2),encoding='utf-8')
    raise SystemExit(0 if all(row['passed'] for row in checks) else 1)


def native_ok(report, actual, frames):
    report.update(frames=len(actual), expected_frames=len(frames))
    return (len(actual)==len(frames) and report['process'].get('return_code')==0 and
            report.get('end_file')=={'reason':0,'error':0} and
            not any(row['level'] in ('error','fatal') or 'Invalid frequency and/or width' in row['text']
                    for row in report.get('logs',[])))


if __name__ == '__main__':
    main()
