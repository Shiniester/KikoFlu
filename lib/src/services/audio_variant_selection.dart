import '../utils/file_tree_utils.dart';
import 'player_audio_variant_classifier.dart';
import 'subtitle_matching.dart';

enum AudioVariantSelectionPurpose { subtitleGeneration, download }

class AudioVariantSelection {
  const AudioVariantSelection({required this.target, required this.selected});

  final PlayerAudioVariant target;
  final PlayerAudioVariant selected;
}

class AudioVariantSelectionService {
  static const _classifier = PlayerAudioVariantClassifier();

  static List<PlayerAudioVariant> candidatesFor({
    required PlayerAudioVariant target,
    required List<PlayerAudioVariant> allVariants,
    required AudioVariantSelectionPurpose purpose,
    AudioFormatPreference preference = const AudioFormatPreference(),
    bool showAll = false,
  }) {
    final candidatesByPath = <String, PlayerAudioVariant>{
      target.fullPath: target,
    };
    for (final variant in allVariants) {
      if (showAll ||
          SubtitleMatcher.checkAudioNames(
            variant.title,
            target.title,
          ).isMatch) {
        candidatesByPath.putIfAbsent(variant.fullPath, () => variant);
      }
    }

    final candidates = candidatesByPath.values.toList();
    if (purpose == AudioVariantSelectionPurpose.subtitleGeneration) {
      candidates.sort(_compareGenerationCandidates);
    } else {
      final preferredPaths = _classifier
          .selectBest(candidates, preference: preference)
          .map((variant) => variant.fullPath)
          .toSet();
      candidates.sort((a, b) {
        final preferred = (preferredPaths.contains(b.fullPath) ? 1 : 0)
            .compareTo(preferredPaths.contains(a.fullPath) ? 1 : 0);
        return preferred != 0 ? preferred : _comparePath(a, b);
      });
    }
    return List.unmodifiable(candidates);
  }

  static PlayerAudioVariant recommendFor({
    required PlayerAudioVariant target,
    required List<PlayerAudioVariant> allVariants,
    required AudioVariantSelectionPurpose purpose,
    AudioFormatPreference preference = const AudioFormatPreference(),
  }) {
    final candidates =
        candidatesFor(
              target: target,
              allVariants: allVariants,
              purpose: purpose,
              preference: preference,
            )
            .where((candidate) => !_hasDifferentTrackNumber(target, candidate))
            .toList();

    if (purpose == AudioVariantSelectionPurpose.subtitleGeneration) {
      candidates.sort(_compareGenerationCandidates);
      return candidates.first;
    }

    final preferred = _classifier.selectBest(
      candidates,
      preference: preference,
    );
    return preferred.isEmpty ? target : preferred.first;
  }

  static int _compareGenerationCandidates(
    PlayerAudioVariant a,
    PlayerAudioVariant b,
  ) {
    var compared = (a.format == AudioFormat.mp3 ? 0 : 1).compareTo(
      b.format == AudioFormat.mp3 ? 0 : 1,
    );
    if (compared != 0) return compared;
    compared = _traitRank(a.se).compareTo(_traitRank(b.se));
    if (compared != 0) return compared;
    compared = _traitRank(a.ejaculation).compareTo(_traitRank(b.ejaculation));
    if (compared != 0) return compared;

    final aSize = _size(a);
    final bSize = _size(b);
    if (aSize != null && bSize != null && aSize != bSize) {
      return aSize.compareTo(bSize);
    }
    if (aSize == null && bSize != null) return 1;
    if (aSize != null && bSize == null) return -1;
    return _comparePath(a, b);
  }

  static int _traitRank(PlayerBinaryTrait value) => switch (value) {
    PlayerBinaryTrait.absent => 0,
    PlayerBinaryTrait.unknown => 1,
    PlayerBinaryTrait.present => 2,
  };

  static int? _size(PlayerAudioVariant variant) {
    final size = FileTreeUtils.property(variant.source, 'size');
    return size is num && size > 0 ? size.toInt() : null;
  }

  static int _comparePath(PlayerAudioVariant a, PlayerAudioVariant b) {
    final compared = a.fullPath.toLowerCase().compareTo(
      b.fullPath.toLowerCase(),
    );
    return compared != 0 ? compared : a.fullPath.compareTo(b.fullPath);
  }

  static bool _hasDifferentTrackNumber(
    PlayerAudioVariant target,
    PlayerAudioVariant candidate,
  ) {
    final targetNumber = _leadingTrackNumber(target.title);
    final candidateNumber = _leadingTrackNumber(candidate.title);
    return targetNumber != null &&
        candidateNumber != null &&
        targetNumber != candidateNumber;
  }

  static int? _leadingTrackNumber(String title) {
    final match = RegExp(
      r'^\s*(?:track|trk)?[\s._-]*0*(\d+)(?=$|[\s._-])',
      caseSensitive: false,
    ).firstMatch(SubtitleMatcher.prepareAudio(title).baseName);
    return int.tryParse(match?.group(1) ?? '');
  }
}
