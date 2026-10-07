import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saver_gallery/saver_gallery.dart';

import '../../l10n/app_localizations.dart';
import '../utils/snackbar_util.dart';
import 'cover_preview_dialog.dart' show resolveCoverImageExtension;

typedef ReaderImageSaveCallback =
    Future<void> Function(
      BuildContext context,
      Uint8List imageBytes,
      String imageName,
    );

Future<void> saveReaderImage(
  BuildContext context,
  Uint8List imageBytes,
  String imageName,
) async {
  final l10n = S.of(context);
  final sourceName = imageName.trim().isEmpty ? 'image' : imageName.trim();
  final extension = resolveCoverImageExtension(
    source: sourceName,
    bytes: imageBytes,
  );
  final safeName = sourceName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  final fileName = '${path.basenameWithoutExtension(safeName)}.$extension';

  if (Platform.isAndroid) {
    var status = await Permission.photos.request();
    if (!status.isGranted) {
      status = await Permission.storage.request();
    }
    if (!context.mounted) return;

    if (!status.isGranted) {
      if (status.isPermanentlyDenied) {
        final shouldOpenSettings = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.storagePermissionRequired),
            content: Text(l10n.storagePermissionForGalleryDesc),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancel),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.goToSettings),
              ),
            ],
          ),
        );
        if (shouldOpenSettings == true) await openAppSettings();
      } else {
        SnackBarUtil.showWarning(
          context,
          l10n.storagePermissionRequiredForImage,
        );
      }
      return;
    }

    final temporaryDirectory = await getTemporaryDirectory();
    final temporaryFile = File(
      path.join(
        temporaryDirectory.path,
        '${DateTime.now().microsecondsSinceEpoch}-$fileName',
      ),
    );
    late final SaveResult result;
    try {
      await temporaryFile.writeAsBytes(imageBytes);
      result = await SaverGallery.saveFile(
        filePath: temporaryFile.path,
        fileName: fileName,
        skipIfExists: false,
        androidRelativePath: 'Pictures/KikoFlu',
      );
    } finally {
      if (await temporaryFile.exists()) await temporaryFile.delete();
    }
    if (!context.mounted) return;
    if (result.isSuccess) {
      SnackBarUtil.showSuccess(context, l10n.imageSavedToGallery);
    } else {
      SnackBarUtil.showError(
        context,
        l10n.saveFailedWithError(result.errorMessage ?? l10n.saveImageFailed),
      );
    }
    return;
  }

  if (Platform.isIOS) {
    final outputFile = await FilePicker.platform.saveFile(
      dialogTitle: l10n.saveImage,
      fileName: fileName,
      type: FileType.image,
      bytes: imageBytes,
    );
    if (outputFile != null && context.mounted) {
      SnackBarUtil.showSuccess(context, l10n.imageSavedToPath(outputFile));
    }
    return;
  }

  final outputFile = await FilePicker.platform.saveFile(
    dialogTitle: l10n.saveImage,
    fileName: fileName,
    type: FileType.image,
  );
  if (outputFile == null) return;
  await File(outputFile).writeAsBytes(imageBytes);
  if (context.mounted) {
    SnackBarUtil.showSuccess(context, l10n.imageSavedToPath(outputFile));
  }
}
