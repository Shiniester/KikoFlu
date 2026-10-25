import 'package:equatable/equatable.dart';

class AudioSlice extends Equatable {
  const AudioSlice({required this.startMs, required this.endMs});

  final int startMs;
  final int endMs;

  @override
  List<Object?> get props => [startMs, endMs];
}

class AudioSliceState extends Equatable {
  const AudioSliceState()
    : trackKey = null,
      slices = const [],
      pendingStartMs = null,
      preview = null,
      onlySlices = false,
      isLoading = false;

  AudioSliceState.withValues({
    this.trackKey,
    List<AudioSlice> slices = const [],
    this.pendingStartMs,
    this.preview,
    this.onlySlices = false,
    this.isLoading = false,
  }) : slices = List.unmodifiable(slices);

  static const Object _unset = Object();

  final String? trackKey;
  final List<AudioSlice> slices;
  final int? pendingStartMs;
  final AudioSlice? preview;
  final bool onlySlices;
  final bool isLoading;

  AudioSliceState copyWith({
    Object? trackKey = _unset,
    List<AudioSlice>? slices,
    Object? pendingStartMs = _unset,
    Object? preview = _unset,
    bool? onlySlices,
    bool? isLoading,
    bool clearTrackKey = false,
    bool clearPendingStart = false,
    bool clearPreview = false,
  }) => AudioSliceState.withValues(
    trackKey: clearTrackKey
        ? null
        : identical(trackKey, _unset)
        ? this.trackKey
        : trackKey as String?,
    slices: slices ?? this.slices,
    pendingStartMs: clearPendingStart
        ? null
        : identical(pendingStartMs, _unset)
        ? this.pendingStartMs
        : pendingStartMs as int?,
    preview: clearPreview
        ? null
        : identical(preview, _unset)
        ? this.preview
        : preview as AudioSlice?,
    onlySlices: onlySlices ?? this.onlySlices,
    isLoading: isLoading ?? this.isLoading,
  );

  @override
  List<Object?> get props => [
    trackKey,
    slices,
    pendingStartMs,
    preview,
    onlySlices,
    isLoading,
  ];
}
