"""PCM checks for channel mapping and the linear stereo widening stage."""

import math

EQ_FREQUENCIES = (31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000)


def equalizer_graph(gains):
    filters = [
        f"equalizer=f={frequency}:t=q:w=1:g={gain}:precision=f64"
        for frequency, gain in zip(EQ_FREQUENCIES, gains)
        if gain != 0
    ]
    # The specification bypasses zero-gain bands, avoiding roundoff from identity IIRs.
    return "[in]" + (",".join(filters) if filters else "anull") + "[out]"


def tone_amplitude(samples, frequency, rate=48000):
    size = len(samples)
    real = sum(value * math.cos(2 * math.pi * frequency * n / rate)
               for n, value in enumerate(samples))
    imaginary = sum(value * math.sin(2 * math.pi * frequency * n / rate)
                    for n, value in enumerate(samples))
    return 2 * math.hypot(real, imaginary) / size


def add_equalizer_cases(case, require):
    for band, frequency in enumerate(EQ_FREQUENCIES):
        off_frequency = frequency * 2 if frequency < 16000 else frequency // 2
        frames = [
            (round(1200 * (math.sin(2 * math.pi * frequency * n / 48000)
                          + math.sin(2 * math.pi * off_frequency * n / 48000))),) * 2
            for n in range(72000)
        ]
        reference = [pair[0] / 32768 for pair in frames[-48000:]]
        amplitudes = [tone_amplitude(reference, f) for f in (frequency, off_frequency)]
        for gain in (-15, 15):
            gains = [0] * 10
            gains[band] = gain

            def assess(actual, _, gain=gain, frequency=frequency,
                       off_frequency=off_frequency, amplitudes=amplitudes):
                samples = [pair[0] for pair in actual[-48000:]]
                measured = [
                    20 * math.log10(tone_amplitude(samples, f) / amplitude)
                    for f, amplitude in zip((frequency, off_frequency), amplitudes)
                ]
                require(abs(measured[0] - gain) < .03,
                        "EQ center-frequency gain differs by at least 0.03 dB")
                require(abs(measured[1]) < abs(measured[0]) - 1,
                        "EQ does not distinguish its center frequency from the adjacent octave")
                require(all(l == r for l, r in actual), "EQ channel states diverged for identical input")
                return {"center_hz": frequency, "target_db": gain,
                        "measured_center_db": measured[0], "off_frequency_hz": off_frequency,
                        "measured_off_frequency_db": measured[1]}

            case(f"eq_{frequency}_{gain}", equalizer_graph(gains), frames, 48000, assess)
    frames = [
        (round(5000 * math.sin(2 * math.pi * 440 * n / 48000)),
         round(3000 * math.sin(2 * math.pi * 1733 * n / 48000)))
        for n in range(9600)
    ]

    def assess_neutral(actual, _):
        require(all(l == a/32768 and r == b/32768 for (l,r),(a,b) in zip(actual,frames)),
                "neutral 10-band EQ changed PCM")
        return {"max_error": 0}

    case("eq_neutral", equalizer_graph([0] * 10), frames, 48000, assess_neutral)


def add_channel_cases(case, require):
    frames = [
        (round(6000 * math.sin(2 * math.pi * 440 * n / 48000)),
         round(4000 * math.sin(2 * math.pi * 880 * n / 48000 + .3)))
        for n in range(9600)
    ]
    for name, expression, mapping in (
        ("normal", "val(0)|val(1)", lambda l, r: (l, r)),
        ("swap", "val(1)|val(0)", lambda l, r: (r, l)),
        ("clone_left", "val(0)|val(0)", lambda l, r: (l, l)),
        ("clone_right", "val(1)|val(1)", lambda l, r: (r, r)),
    ):
        expected = [mapping(l / 32768, r / 32768) for l, r in frames]

        def assess(actual, _, expected=expected):
            error = max(abs(x-y) for a,b in zip(actual, expected) for x,y in zip(a,b))
            require(error == 0, "channel mapping differs from original samples")
            return {"max_error": error}

        case("channels_" + name, "[in]aeval='" + expression + "':c=stereo,aformat=channel_layouts=stereo[out]",
             frames, 48000, assess)


def add_stereo_cases(case, require):
    frames = [
        (round(6000 * math.sin(2 * math.pi * 440 * n / 48000)),
         round(4000 * math.sin(2 * math.pi * 880 * n / 48000 + .3)))
        for n in range(9600)
    ]
    for width in (0, .5, 1, 2):
        graph = (
            f"[in]aeval='(val(0)+val(1))/2+{width}*(val(0)-val(1))/2|"
            f"(val(0)+val(1))/2-{width}*(val(0)-val(1))/2':c=stereo,aformat=channel_layouts=stereo[out]"
        )

        def assess(actual, _, width=width, frames=frames):
            mid_error = side_error = 0
            for (l,r), (left,right) in zip(actual, frames):
                expected_mid = (left+right)/65536
                expected_side = width*(left-right)/65536
                mid_error = max(mid_error, abs((l+r)/2-expected_mid))
                side_error = max(side_error, abs((l-r)/2-expected_side))
            require(mid_error < 1e-7 and side_error < 1e-7, "stereo mid/side mapping differs")
            if width == 1:
                require(all(l == a/32768 and r == b/32768 for (l,r),(a,b) in zip(actual,frames)),
                        "neutral stereo width changed PCM")
            return {"midside_mid_error": mid_error, "midside_side_error": side_error}

        case("stereo_width_" + str(width), graph, frames, 48000, assess)
        if width == 2:
            identical = [(l,l) for l,r in frames]
            case("stereo_identical_width2", graph, identical, 48000,
                 lambda actual, report: assess(actual, report, width=2, frames=identical))
