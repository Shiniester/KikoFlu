import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'tab_page_motion.dart';

/// Slides shared content without keeping an outgoing provider consumer alive.
class LibraryContentTransition extends StatefulWidget {
  const LibraryContentTransition({super.key, required this.child});

  final Widget child;

  @override
  State<LibraryContentTransition> createState() =>
      LibraryContentTransitionState();
}

class LibraryContentTransitionState extends State<LibraryContentTransition>
    with SingleTickerProviderStateMixin {
  final _paintKey = GlobalKey();
  late final _controller = AnimationController(
    vsync: this,
    duration: tabPageDuration,
    value: 1,
  )..addStatusListener(_onStatusChanged);
  late final _progress = CurvedAnimation(
    parent: _controller,
    curve: Curves.ease,
  );
  ui.Image? _outgoing;
  double _direction = 1;

  void animate(VoidCallback change, {bool reverse = false}) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
      change();
      return;
    }
    final boundary =
        _paintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    // Keep the painted frame even when a provider has marked the child dirty.
    // ignore: invalid_use_of_protected_member
    final layer = boundary?.layer;
    final image =
        boundary != null &&
            boundary.attached &&
            boundary.hasSize &&
            !boundary.size.isEmpty &&
            layer is OffsetLayer
        ? layer.toImageSync(
            Offset.zero & boundary.size,
            pixelRatio: MediaQuery.devicePixelRatioOf(context),
          )
        : null;
    final previous = _outgoing;
    setState(() {
      _outgoing = image;
      _direction = reverse ? -1 : 1;
    });
    _releaseImage(previous);
    change();
    if (image != null) _controller.forward(from: 0);
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status != AnimationStatus.completed || _outgoing == null) return;
    final image = _outgoing;
    setState(() => _outgoing = null);
    _releaseImage(image);
  }

  void _releaseImage(ui.Image? image) {
    if (image == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _controller.value = 1;
  }

  @override
  void dispose() {
    _progress.dispose();
    _controller.dispose();
    _outgoing?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: _paintKey,
    child: ClipRect(
      child: AnimatedBuilder(
        animation: _progress,
        child: widget.child,
        builder: (context, child) {
          final image = _outgoing;
          final progress = _progress.value;
          return AbsorbPointer(
            absorbing: image != null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FractionalTranslation(
                  translation: Offset(
                    image == null ? 0 : _direction * (1 - progress),
                    0,
                  ),
                  child: child,
                ),
                if (image != null)
                  ExcludeSemantics(
                    child: FractionalTranslation(
                      translation: Offset(-_direction * progress, 0),
                      child: RawImage(image: image, fit: BoxFit.fill),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}
