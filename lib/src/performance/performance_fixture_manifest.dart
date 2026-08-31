import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

@immutable
class PerformanceFixtureManifest {
  const PerformanceFixtureManifest({
    required this.fixtureVersion,
    required this.seed,
    required this.contentHash,
    required this.works,
    required this.downloadTasks,
    required this.activeDownloads,
    required this.localRecords,
    required this.zipUncompressedBytes,
    required this.trackSwitches,
    required this.worksPath,
    required this.downloadTasksPath,
    required this.subtitleRootPath,
    required this.zipPath,
  });

  static const int currentVersion = 2;

  final int fixtureVersion;
  final int seed;
  final String contentHash;
  final int works;
  final int downloadTasks;
  final int activeDownloads;
  final int localRecords;
  final int zipUncompressedBytes;
  final int trackSwitches;
  final String worksPath;
  final String downloadTasksPath;
  final String subtitleRootPath;
  final String zipPath;

  factory PerformanceFixtureManifest.fromJson(Map<String, Object?> json) {
    return PerformanceFixtureManifest(
      fixtureVersion: _requiredInt(json, 'fixtureVersion'),
      seed: _requiredInt(json, 'seed'),
      contentHash: _requiredString(json, 'contentHash'),
      works: _requiredInt(json, 'works'),
      downloadTasks: _requiredInt(json, 'downloadTasks'),
      activeDownloads: _requiredInt(json, 'activeDownloads'),
      localRecords: _requiredInt(json, 'localRecords'),
      zipUncompressedBytes: _requiredInt(json, 'zipUncompressedBytes'),
      trackSwitches: _requiredInt(json, 'trackSwitches'),
      worksPath: _requiredString(json, 'worksPath'),
      downloadTasksPath: _requiredString(json, 'downloadTasksPath'),
      subtitleRootPath: _requiredString(json, 'subtitleRootPath'),
      zipPath: _requiredString(json, 'zipPath'),
    )..validate();
  }

  static Future<PerformanceFixtureManifest> read(File file) async {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('Performance fixture manifest is not a map');
    }
    return PerformanceFixtureManifest.fromJson(
      Map<String, Object?>.from(decoded),
    );
  }

  void validate() {
    if (fixtureVersion != currentVersion) {
      throw FormatException(
        'Fixture version $fixtureVersion is not supported; expected '
        '$currentVersion.',
      );
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(contentHash)) {
      throw const FormatException('Fixture contentHash must be SHA-256');
    }
    if (works != 500 ||
        downloadTasks != 1000 ||
        activeDownloads != 3 ||
        localRecords != 10000 ||
        trackSwitches != 50) {
      throw const FormatException(
        'Fixture cardinality does not match schema 2',
      );
    }
  }

  String resolvePath(String manifestPath, String relativePath) {
    return p.normalize(p.join(p.dirname(manifestPath), relativePath));
  }

  Map<String, Object?> toReportJson() => {
    'fixtureVersion': fixtureVersion,
    'seed': seed,
    'contentHash': contentHash,
    'works': works,
    'downloadTasks': downloadTasks,
    'activeDownloads': activeDownloads,
    'localRecords': localRecords,
    'zipUncompressedBytes': zipUncompressedBytes,
    'trackSwitches': trackSwitches,
  };

  static int _requiredInt(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! num) throw FormatException('Missing integer fixture.$key');
    return value.toInt();
  }

  static String _requiredString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Missing string fixture.$key');
    }
    return value;
  }
}

@immutable
class PerformancePlaybackTrack {
  const PerformancePlaybackTrack({required this.workId, required this.hash});

  final int workId;
  final String hash;

  factory PerformancePlaybackTrack.fromJson(Map<String, Object?> json) {
    final workId = json['workId'];
    final hash = json['hash'];
    if (workId is! num || hash is! String || hash.isEmpty) {
      throw const FormatException('Invalid playback track fixture');
    }
    return PerformancePlaybackTrack(workId: workId.toInt(), hash: hash);
  }

  Map<String, Object?> toJson() => {'workId': workId, 'hash': hash};
}

@immutable
class PerformancePlaybackFixtureManifest {
  const PerformancePlaybackFixtureManifest({
    required this.fixtureVersion,
    required this.serverHash,
    required this.contentHash,
    required this.tracks,
  });

  final int fixtureVersion;
  final String serverHash;
  final String contentHash;
  final List<PerformancePlaybackTrack> tracks;

  factory PerformancePlaybackFixtureManifest.fromJson(
    Map<String, Object?> json,
  ) {
    final rawTracks = json['tracks'];
    if (rawTracks is! List) {
      throw const FormatException('Playback fixture is missing tracks');
    }
    final manifest = PerformancePlaybackFixtureManifest(
      fixtureVersion: (json['fixtureVersion'] as num?)?.toInt() ?? 0,
      serverHash: json['serverHash']?.toString() ?? '',
      contentHash: json['contentHash']?.toString() ?? '',
      tracks: rawTracks
          .map(
            (track) => PerformancePlaybackTrack.fromJson(
              Map<String, Object?>.from(track as Map),
            ),
          )
          .toList(growable: false),
    );
    final sha256Pattern = RegExp(r'^[a-f0-9]{64}$');
    if (manifest.fixtureVersion != PerformanceFixtureManifest.currentVersion ||
        !sha256Pattern.hasMatch(manifest.serverHash) ||
        !sha256Pattern.hasMatch(manifest.contentHash) ||
        manifest.tracks.length < 10) {
      throw const FormatException('Playback fixture is incomplete');
    }
    return manifest;
  }

  Map<String, Object?> toJson() => {
    'fixtureVersion': fixtureVersion,
    'serverHash': serverHash,
    'contentHash': contentHash,
    'tracks': tracks.map((track) => track.toJson()).toList(growable: false),
  };
}
