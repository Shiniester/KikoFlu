import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Reuses the settled palette as a texture while the player pages move.
class PlayerPaletteBackground extends StatefulWidget {
  const PlayerPaletteBackground({
    super.key,
    required this.gradient,
    required this.duration,
  });

  final LinearGradient gradient;
  final Duration duration;

  @override
  State<PlayerPaletteBackground> createState() =>
      _PlayerPaletteBackgroundState();
}

class _PlayerPaletteBackgroundState extends State<PlayerPaletteBackground> {
  final _snapshot = SnapshotController(allowSnapshotting: true);

  @override
  void didUpdateWidget(PlayerPaletteBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gradient != widget.gradient) {
      _snapshot.allowSnapshotting = false;
      if (widget.duration == Duration.zero) {
        _snapshot.allowSnapshotting = true;
      }
    }
  }

  @override
  void dispose() {
    _snapshot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final background = AnimatedContainer(
      duration: widget.duration,
      curve: Curves.easeInOutCubic,
      onEnd: () => _snapshot.allowSnapshotting = true,
      decoration: BoxDecoration(gradient: widget.gradient),
    );
    // CanvasKit shares the UI and raster thread; keep its live paint path.
    if (kIsWeb) return background;
    return SnapshotWidget(
      controller: _snapshot,
      autoresize: true,
      child: background,
    );
  }
}
