import 'package:flutter/material.dart';

import 'file_explorer_header.dart';
import 'file_explorer_status_view.dart';
import 'file_tree_view.dart';

class FileExplorerTreePanel extends StatelessWidget {
  const FileExplorerTreePanel({
    super.key,
    required this.isLoading,
    required this.empty,
    required this.emptyMessage,
    required this.title,
    required this.items,
    required this.expandedFolders,
    required this.onToggleFolder,
    required this.onFileTap,
    this.onFileLongPress,
    this.errorMessage,
    this.onRetry,
    this.trailing,
    this.progressMessage,
    this.displayNameFor,
    this.metadataBuilder,
    this.audioMetadataBuilder,
    this.audioDurationBuilder,
    this.trailingBuilder,
    this.videoBeforeAudio = true,
    this.downloadedFiles = const {},
    this.audioWithLibrarySubtitles = const {},
    this.showDownloadedBadge = false,
    this.fadeDownloadedItems = false,
    this.showHeader = true,
  });

  final bool isLoading;
  final bool empty;
  final String emptyMessage;
  final String? errorMessage;
  final VoidCallback? onRetry;
  final String title;
  final Widget? trailing;
  final String? progressMessage;
  final List<dynamic> items;
  final Set<String> expandedFolders;
  final ValueChanged<String> onToggleFolder;
  final FileTreeItemTap onFileTap;
  final FileTreeItemLongPress? onFileLongPress;
  final FileTreeDisplayNameBuilder? displayNameFor;
  final FileTreeMetadataBuilder? metadataBuilder;
  final FileTreeMetadataBuilder? audioMetadataBuilder;
  final FileTreeMetadataBuilder? audioDurationBuilder;
  final FileTreeTrailingBuilder? trailingBuilder;
  final bool videoBeforeAudio;
  final Map<String, bool> downloadedFiles;
  final Set<String> audioWithLibrarySubtitles;
  final bool showDownloadedBadge;
  final bool fadeDownloadedItems;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    if (isLoading || errorMessage != null || empty) {
      return SliverToBoxAdapter(
        child: FileExplorerStatusView(
          isLoading: isLoading,
          errorMessage: errorMessage,
          empty: empty,
          emptyMessage: emptyMessage,
          onRetry: onRetry,
          child: const SizedBox.shrink(),
        ),
      );
    }
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showHeader)
                FileExplorerHeader(title: title, trailing: trailing),
              if (showHeader &&
                  progressMessage != null &&
                  progressMessage!.isNotEmpty)
                FileExplorerProgressBanner(message: progressMessage!),
            ],
          ),
        ),
        FileTreeView(
          items: items,
          expandedFolders: expandedFolders,
          onToggleFolder: onToggleFolder,
          onFileTap: onFileTap,
          onFileLongPress: onFileLongPress,
          displayNameFor: displayNameFor,
          metadataBuilder: metadataBuilder,
          audioMetadataBuilder: audioMetadataBuilder,
          audioDurationBuilder: audioDurationBuilder,
          trailingBuilder: trailingBuilder,
          videoBeforeAudio: videoBeforeAudio,
          downloadedFiles: downloadedFiles,
          audioWithLibrarySubtitles: audioWithLibrarySubtitles,
          showDownloadedBadge: showDownloadedBadge,
          fadeDownloadedItems: fadeDownloadedItems,
        ),
      ],
    );
  }
}
