import 'package:flutter/material.dart';

import '../host/host_controller.dart';

/// Shows a modal progress dialog while [HostController.downloadAllDeckImages]
/// resolves any text-only decks and downloads every referenced card image for
/// offline play, then reports an honest success/failure summary.
///
/// Shared by the host lobby ("Prepare card images") and the Decks tab ("Fetch
/// all card images") so there is exactly one prep experience and one place that
/// tells the truth about what could not be fetched.
Future<void> showImagePrepDialog(BuildContext context, HostController c) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final progress = ValueNotifier<List<int>>(const [0, 0]);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Preparing card images'),
      content: ValueListenableBuilder<List<int>>(
        valueListenable: progress,
        builder: (_, v, _) {
          final done = v[0], total = v[1];
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: total > 0 ? done / total : null),
              const SizedBox(height: 14),
              Text(
                total > 0
                    ? 'Downloading $done / $total'
                    : 'Resolving decks from Scryfall…',
              ),
            ],
          );
        },
      ),
    ),
  );
  void show(String msg) => messenger.showSnackBar(
    SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
  );
  try {
    final r = await c.downloadAllDeckImages(
      onProgress: (d, t) => progress.value = [d, t],
    );
    navigator.pop();
    final problems = r.imagesFailed + r.linesFailed;
    show(
      problems == 0
          ? 'Card images are ready for offline play.'
          : 'Cached ${r.imagesCached} image(s); $problems still need internet — retry before going offline.',
    );
  } catch (e) {
    navigator.pop();
    show('Image prep failed (offline?): $e');
  } finally {
    progress.dispose();
  }
}
