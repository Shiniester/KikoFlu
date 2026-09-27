import 'package:flutter/material.dart';

/// Keeps the displayed cover while an offstage route resumes its image stream.
class WorkCoverImage extends StatefulWidget {
  const WorkCoverImage({
    super.key,
    required this.image,
    required this.placeholder,
    required this.errorBuilder,
    this.width,
    this.height,
    this.fadeInDuration = const Duration(milliseconds: 120),
  });

  final ImageProvider image;
  final WidgetBuilder placeholder;
  final ImageErrorWidgetBuilder errorBuilder;
  final double? width;
  final double? height;
  final Duration fadeInDuration;

  @override
  State<WorkCoverImage> createState() => _WorkCoverImageState();
}

class _WorkCoverImageState extends State<WorkCoverImage> {
  bool _hasFrame = false;

  @override
  void didUpdateWidget(WorkCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _hasFrame = false;
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    height: widget.height,
    child: Image(
      key: ValueKey(widget.image),
      image: widget.image,
      width: widget.width,
      height: widget.height,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      errorBuilder: widget.errorBuilder,
      frameBuilder: (context, child, frame, synchronous) {
        if (frame != null) _hasFrame = true;
        // Re-resolving an evicted stream resets frame, but gaplessPlayback still
        // has the previously decoded image. Do not replace it with a placeholder.
        if (!_hasFrame) return widget.placeholder(context);
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: synchronous ? 1 : 0, end: 1),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : widget.fadeInDuration,
          builder: (context, opacity, child) =>
              Opacity(opacity: opacity, child: child),
          child: child,
        );
      },
    ),
  );
}
