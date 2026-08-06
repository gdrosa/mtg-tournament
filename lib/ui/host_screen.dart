import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../host/host_controller.dart';
import '../host/online_relay.dart';
import '../shared/hosting.dart';
import '../shared/models.dart';
import '../shared/tournament_engine.dart';
import 'app_scope.dart';
import 'card_prep.dart';
import 'deck_editor_screen.dart';

/// The organizer's screen: create a LAN or online tournament and play in it.
class HostScreen extends StatefulWidget {
  const HostScreen({super.key});
  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  // The shared app-wide controller (created in main, resumed once at startup).
  late HostController c;

  /// The player the organizer tapped first while re-pairing a round; the next
  /// tap swaps the two seats.
  String? _swapFrom;

  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // One repaint a second, and only while a round clock is actually running.
    // The countdown is derived from an absolute deadline, so a dropped tick
    // costs nothing and nothing here touches tournament state.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && c.snapshot['roundEndsAt'] != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    c = AppScope.of(context);
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(m), duration: const Duration(seconds: 1)),
  );

  Future<void> _guard(Future<void> Function() fn) async {
    try {
      await fn();
    } on EngineError catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final active = c.server.joinCode != null;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Host a tournament'),
            actions: [
              if (active)
                IconButton(
                  tooltip: 'End event',
                  icon: const Icon(Icons.stop_circle_outlined),
                  onPressed: _confirmEnd,
                ),
            ],
          ),
          body: _body(),
        );
      },
    );
  }

  Widget _body() {
    if (!c.ready) return const Center(child: CircularProgressIndicator());
    if (c.server.joinCode == null) {
      final ownerId = c.server.ownerPlayerId;
      return _CreateForm(
        onCreate: _create,
        initialNick: c.server.owner?.nickname ?? '',
        onlineConfigured: c.onlineHostingConfigured,
        existingDecks: ownerId == null
            ? const <Deck>[]
            : c.server.decksOf(ownerId),
      );
    }
    if (c.hostingPaused) return _paused();
    final snap = c.snapshot;
    final page = switch (snap['phase']) {
      'lobby' => _lobby(snap),
      'running' => _running(snap),
      'finished' => _finished(snap),
      _ => const Center(child: CircularProgressIndicator()),
    };
    if (c.isServing) return page;
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          child: ListTile(
            dense: true,
            leading: c.transportError == null
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.warning_amber_rounded),
            title: Text(c.hostingStatusLabel),
            subtitle: c.transportError == null
                ? Text(
                    c.hostingMode == HostingMode.online
                        ? 'The tournament is safe on this phone.'
                        : 'Looking for a usable Wi-Fi address.',
                  )
                : Text(c.transportError!),
            trailing: TextButton(
              onPressed: () => _guard(() => c.retryHosting()),
              child: const Text('Retry'),
            ),
          ),
        ),
        Expanded(child: page),
      ],
    );
  }

  // Shown after the organizer taps "Stop hosting" in the notification: the
  // event is preserved, just not being served. One tap brings it back online.
  Widget _paused() {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.pause_circle_outline,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text('Hosting stopped', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'Your tournament "${c.server.engine?.name ?? ''}" is saved. '
                'Players can\'t reach it until you resume ${c.hostingMode.label} hosting.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => _guard(() => c.resumeHosting()),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Resume hosting'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _confirmEnd,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('End event'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmEnd() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End this event?'),
        content: const Text(
          'The tournament closes. Your decks and history are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End event'),
          ),
        ],
      ),
    );
    if (ok == true) await c.endEvent();
  }

  Future<void> _create(
    String name,
    String nick, {
    required HostingMode mode,
    String? existingDeckId,
    String deck = '',
    String main = '',
    String side = '',
    String format = '',
    String series = '',
    TournamentKind kind = TournamentKind.swiss,
    int rounds = 0,
    int roundMinutes = 0,
  }) async {
    await _guard(() async {
      Future<void> create() => c.createEvent(
        name: name,
        nickname: nick,
        mode: mode,
        kind: kind,
        format: format,
        series: series,
        rounds: rounds,
        roundMinutes: roundMinutes,
      );
      try {
        await create();
      } on RelayException catch (e) {
        // The relay only refuses this way when the build's provisioning key is
        // missing or revoked, and the organizer can fix it here and now.
        if (!relayNeedsProvisionKey(e)) rethrow;
        final key = await _askProvisionKey();
        if (key == null) return; // cancelled: nothing was created
        await c.setRelayProvisionKey(key);
        await create();
      }
      if (existingDeckId != null) {
        c.joinWithDeck(existingDeckId);
      } else {
        c.registerHostDeck(name: deck, main: main, side: side);
      }
    });
  }

  /// Ask for a relay provisioning key. Returns null when the organizer backs
  /// out, in which case no online event is created.
  Future<String?> _askProvisionKey() async {
    final ctrl = TextEditingController(text: c.effectiveRelayProvisionKey);
    final key = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Provisioning key needed'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'This relay no longer accepts the key built into the app. Ask '
              'the relay owner for a current key, or host on LAN instead.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Provisioning key'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Use key'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return (key == null || key.isEmpty) ? null : key;
  }

  // ---- lobby ----
  Widget _lobby(Map snap) {
    final players = (snap['players'] as List?) ?? [];
    final theme = Theme.of(context);
    final joinUrl = c.joinUrl;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text('Players join at', style: theme.textTheme.bodyMedium),
                const SizedBox(height: 8),
                Chip(
                  avatar: Icon(
                    c.hostingMode == HostingMode.online
                        ? Icons.public
                        : Icons.wifi,
                    size: 18,
                  ),
                  label: Text(
                    '${c.hostingMode.label} · ${c.hostingStatusLabel}',
                  ),
                ),
                const SizedBox(height: 12),
                if (joinUrl != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(data: joinUrl, size: 200),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    joinUrl,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  // A phone on a VPN, tethering, or a second adapter can end up
                  // advertising an address no player can open. Offer the others.
                  if (c.hostingMode == HostingMode.lan &&
                      c.lanCandidates.length > 1)
                    TextButton(
                      onPressed: _pickLanAddress,
                      child: const Text('Players can\'t open this link?'),
                    ),
                ] else ...[
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(),
                  ),
                  Text(
                    c.transportError ?? 'Preparing the join link…',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Code: ${c.server.joinCode}',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  c.hostingMode == HostingMode.online
                      ? 'Players can join from anywhere. Keep this phone connected to the internet.'
                      : 'Players must use the same Wi-Fi. Internet is not required.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Players (${players.length})',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                for (final p in players)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text('${p['nickname']}'),
                    subtitle: Text('${p['deckName']}'),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: c.canEditCards ? _prepImages : null,
          icon: const Icon(Icons.cloud_download_outlined),
          label: const Text('Prepare card images (for offline play)'),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: players.length >= 2
              ? () => _guard(() async => c.start())
              : null,
          icon: const Icon(Icons.play_arrow),
          label: Text(
            players.length >= 2
                ? 'Start tournament'
                : 'Need at least 2 players',
          ),
        ),
      ],
    );
  }

  /// Let the organizer advertise a different local address. The list is ranked,
  /// so the first entry is the automatic pick.
  Future<void> _pickLanAddress() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Which address are players on?'),
              subtitle: Text(
                'Pick the one for the Wi-Fi everyone shares. The QR code and '
                'link update immediately.',
              ),
            ),
            const Divider(height: 1),
            for (final a in c.lanCandidates)
              ListTile(
                leading: Icon(
                  a.ip == c.lanIp
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(a.ip),
                subtitle: Text(a.interfaceName),
                onTap: () {
                  Navigator.pop(ctx);
                  c.useLanAddress(a.ip);
                },
              ),
          ],
        ),
      ),
    );
  }

  // Download + cache every registered deck's card images while the host has
  // internet, so the reveal works offline during the tournament.
  Future<void> _prepImages() => showImagePrepDialog(context, c);

  // ---- running ----
  Widget _running(Map snap) {
    final theme = Theme.of(context);
    final pairings = (snap['pairings'] as List?) ?? [];
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      children: [
        _roundHeader(snap),
        const SizedBox(height: 8),
        _attentionBanner(snap),
        _myMatchCard(snap),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Pairings',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    if (_swapFrom != null)
                      TextButton(
                        onPressed: () => setState(() => _swapFrom = null),
                        child: const Text('Cancel swap'),
                      ),
                  ],
                ),
                Text(
                  _swapFrom == null
                      ? 'Tap a player, then tap another, to swap their seats '
                            'before they play.'
                      : 'Now tap the player to swap with.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                for (final p in pairings) _pairingRow(p),
              ],
            ),
          ),
        ),
        if (snap['roundComplete'] == true) ...[
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => _guard(() async => c.advance()),
            icon: const Icon(Icons.skip_next),
            label: const Text('Generate next round'),
          ),
        ],
        const SizedBox(height: 12),
        _standingsCard(snap),
      ],
    );
  }

  Widget _roundHeader(Map snap) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            'Round ${snap['round']} of ${snap['plannedRounds']}',
            style: theme.textTheme.titleLarge,
          ),
        ),
        // A knockout's length is arithmetic, so there is nothing to edit.
        if (snap['kind'] == 'swiss')
          IconButton(
            tooltip: 'Change the number of rounds',
            icon: const Icon(Icons.format_list_numbered),
            onPressed: () => _editRounds(snap),
          ),
        _timerChip(snap),
      ],
    );
  }

  String _mmss(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Widget _timerChip(Map snap) {
    final endsAt = snap['roundEndsAt'] as String?;
    final minutes = (snap['roundMinutes'] as num?)?.toInt() ?? 0;
    final left = endsAt == null
        ? null
        : DateTime.parse(endsAt).difference(DateTime.now());
    final expired = left != null && left.isNegative;
    return ActionChip(
      avatar: Icon(
        expired ? Icons.alarm_on : Icons.timer_outlined,
        size: 18,
        color: expired ? Theme.of(context).colorScheme.error : null,
      ),
      label: Text(
        left == null
            ? (minutes > 0 ? 'Paused' : 'No timer')
            : (expired ? 'Time!' : _mmss(left)),
      ),
      onPressed: () => _timerSheet(snap),
    );
  }

  /// Round-timer controls. The clock is a wall clock for the players; it never
  /// ends a round or changes a result by itself.
  Future<void> _timerSheet(Map snap) async {
    final minutes = (snap['roundMinutes'] as num?)?.toInt() ?? 0;
    final running = snap['roundEndsAt'] != null;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Round timer'),
              subtitle: Text(
                'Shown to every player. It never advances the round on its own.',
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final m in const [0, 25, 30, 40, 50, 60])
                    ChoiceChip(
                      label: Text(m == 0 ? 'Off' : '$m min'),
                      selected: minutes == m,
                      onSelected: (_) {
                        Navigator.pop(ctx);
                        _guard(() async => c.setRoundMinutes(m));
                      },
                    ),
                ],
              ),
            ),
            if (minutes > 0)
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: Text(running ? 'Restart the clock' : 'Start the clock'),
                onTap: () {
                  Navigator.pop(ctx);
                  _guard(() async => c.startRoundTimer());
                },
              ),
            if (running)
              ListTile(
                leading: const Icon(Icons.stop_circle_outlined),
                title: const Text('Stop the clock'),
                onTap: () {
                  Navigator.pop(ctx);
                  _guard(() async => c.stopRoundTimer());
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editRounds(Map snap) async {
    final played = (snap['round'] as num?)?.toInt() ?? 1;
    final ctrl = TextEditingController(text: '${snap['plannedRounds']}');
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Number of rounds'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Round $played has already been paired, so that is the minimum. '
              'Results already played are never affected.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Rounds'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text.trim())),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (value != null) await _guard(() async => c.setRounds(value));
  }

  /// One tappable player seat. Two taps swap; the engine refuses if either
  /// match already carries a reported result.
  void _tapSeat(String playerId) {
    final from = _swapFrom;
    if (from == null || from == playerId) {
      setState(() => _swapFrom = from == null ? playerId : null);
      return;
    }
    setState(() => _swapFrom = null);
    _guard(() async => c.swapPairing(from, playerId));
  }

  Widget _seat(Map p, String label, String? playerId) {
    final theme = Theme.of(context);
    final editable = p['editable'] == true && playerId != null;
    final selected = _swapFrom != null && _swapFrom == playerId;
    return InkWell(
      onTap: editable ? () => _tapSeat(playerId) : null,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: selected
            ? BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(6),
              )
            : null,
        child: Text(label, style: theme.textTheme.bodyMedium),
      ),
    );
  }

  // Prominent, impossible-to-miss alert for every match awaiting the host: a
  // reported infraction (with who flagged it) or a result mismatch, each with
  // resolve actions. Empty when nothing needs attention.
  Widget _attentionBanner(Map snap) {
    final pairings = (snap['pairings'] as List?) ?? [];
    final review = pairings.where((p) => p['needsReview'] == true).toList();
    if (review.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final onColor = theme.colorScheme.onErrorContainer;
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: onColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    review.length == 1
                        ? 'A match needs your attention'
                        : '${review.length} matches need your attention',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: onColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            for (final p in review) ...[
              const Divider(height: 20),
              Text(
                p['isInfraction'] == true
                    ? '👎 Infraction reported'
                          '${(p['reportedBy'] as List?)?.isNotEmpty == true ? ' by ${(p['reportedBy'] as List).join(', ')}' : ''}'
                    : '⚠ Players reported different results',
                style: TextStyle(color: onColor, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                p['p2'] == null ? '${p['p1']}' : '${p['p1']}  vs  ${p['p2']}',
                style: TextStyle(color: onColor),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: _resolveActions(p)),
            ],
          ],
        ),
      ),
    );
  }

  // Confirm an already-accepted result as-is (dismiss an infraction with no
  // penalty / no score change).
  Future<void> _keepResult(String matchId, String result) async {
    final parts = result.split('-');
    if (parts.length < 2) return;
    final a = int.tryParse(parts[0]), b = int.tryParse(parts[1]);
    if (a == null || b == null) return;
    await _guard(() async => c.resolve(matchId, a, b));
  }

  // Resolve actions for a review match, built from REAL data: the agreed result
  // (if any) plus each score a player actually declared (so a mismatch is
  // resolved to what someone reported, not a hardcoded 2–1), plus an "Other…"
  // override for host adjudication / penalties.
  List<Widget> _resolveActions(Map p) {
    final matchId = '${p['matchId']}';
    final result = p['result'] as String?;
    final widgets = <Widget>[];
    final seen = <String>{};
    if (result != null) {
      widgets.add(
        FilledButton.tonal(
          onPressed: () => _keepResult(matchId, result),
          child: Text('Keep result $result'),
        ),
      );
      seen.add(result);
    }
    for (final r in (p['reports'] as List?) ?? const []) {
      final a = r['p1'] as int, b = r['p2'] as int;
      if (!seen.add('$a-$b')) {
        continue; // skip the agreed result / identical reports
      }
      widgets.add(
        OutlinedButton(
          onPressed: () => _guard(() async => c.resolve(matchId, a, b)),
          child: Text('${r['by']} said $a–$b'),
        ),
      );
    }
    widgets.add(
      OutlinedButton(
        onPressed: () => _customResolve(p),
        child: const Text('Other…'),
      ),
    );
    return widgets;
  }

  // Host override: pick any best-of-3 outcome (penalties, or a score neither
  // player reported). Scores are canonical p1–p2.
  Future<void> _customResolve(Map p) async {
    final matchId = '${p['matchId']}';
    final p1 = '${p['p1']}', p2 = '${p['p2']}';
    const options = [
      [2, 0],
      [2, 1],
      [1, 2],
      [0, 2],
      [1, 1],
    ];
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text('Set the result — $p1 vs $p2')),
            const Divider(height: 1),
            for (final s in options)
              ListTile(
                title: Text(
                  s[0] == s[1]
                      ? '$p1 ${s[0]}–${s[1]} $p2 (draw)'
                      : '$p1 ${s[0]}–${s[1]} $p2',
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _guard(() async => c.resolve(matchId, s[0], s[1]));
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _pairingRow(Map p) {
    final theme = Theme.of(context);
    final review = p['needsReview'] == true;
    final title = p['p2'] == null
        ? '${p['p1']} — bye'
        : '${p['p1']}  vs  ${p['p2']}';
    // Needs-review rows stack the resolve controls BELOW the name in a full-width
    // Wrap; putting them beside an Expanded text squeezes the name to one
    // character per line and overflows the buttons off-screen.
    if (review) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(
                  label: Text(
                    p['isInfraction'] == true ? 'Infraction' : 'Mismatch',
                  ),
                  labelStyle: TextStyle(
                    color: theme.colorScheme.onErrorContainer,
                    fontSize: 12,
                  ),
                  backgroundColor: theme.colorScheme.errorContainer,
                  visualDensity: VisualDensity.compact,
                  side: BorderSide.none,
                ),
                ..._resolveActions(p),
              ],
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _seat(p, '${p['p1']}', p['p1Id'] as String?),
                Text(
                  p['p2'] == null ? '— bye' : 'vs',
                  style: theme.textTheme.bodySmall,
                ),
                if (p['p2'] != null)
                  _seat(p, '${p['p2']}', p['p2Id'] as String?),
              ],
            ),
          ),
          Text(
            p['result'] == null ? (p['state'] as String) : '${p['result']}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: p['state'] == 'confirmed'
                  ? Colors.greenAccent
                  : theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  // host plays through the same flow as a remote player
  Widget _myMatchCard(Map snap) {
    final m = snap['yourMatch'] as Map?;
    if (m == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final id = '${m['matchId']}';
    final children = <Widget>[];
    if (m['bye'] == true) {
      children.add(const Text('You have a bye this round (free win).'));
    } else {
      children.add(
        Text(
          'Your match — vs ${m['opponent']}',
          style: theme.textTheme.titleMedium,
        ),
      );
      if (m['needsResult'] == true && m['mySubmission'] == null) {
        children.add(const SizedBox(height: 8));
        children.add(
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _scoreChip(id, 2, 0, '2–0'),
              _scoreChip(id, 2, 1, '2–1'),
              _scoreChip(id, 1, 2, '1–2'),
              _scoreChip(id, 0, 2, '0–2'),
            ],
          ),
        );
      } else if (m['state'] == 'needsReview' &&
          m['reviewReason'] == 'resultMismatch') {
        children.add(
          const Text('Result mismatch — resolve it in Pairings below.'),
        );
      } else if (m['revealed'] != true && m['mySubmission'] != null) {
        children.add(
          Text('You reported ${m['mySubmission']}. Waiting for your opponent…'),
        );
      }
      if (m['revealed'] == true) {
        final d = m['opponentDeck'] as Map?;
        children.add(const SizedBox(height: 8));
        children.add(
          Text(
            'Result ${m['accepted']} · ${m['opponent']}\'s deck: ${d?['name'] ?? ''}',
          ),
        );
        final oppDeckId = d?['deckId'] as String?;
        if (oppDeckId != null) {
          children.add(const SizedBox(height: 6));
          children.add(
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DeckEditorScreen(
                      deckId: oppDeckId,
                      readOnly: true,
                      titleOverride: "${m['opponent']}'s deck",
                    ),
                  ),
                ),
                icon: const Icon(Icons.style),
                label: const Text('View their cards'),
              ),
            ),
          );
        }
        if (m['needsInfraction'] == true) {
          children.add(const SizedBox(height: 8));
          children.add(
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () => _guard(() async => c.infraction(id, true)),
                    child: const Text('👍 All good'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () =>
                        _guard(() async => c.infraction(id, false)),
                    child: const Text('👎 Report'),
                  ),
                ),
              ],
            ),
          );
        } else if (m['state'] == 'needsReview') {
          children.add(const SizedBox(height: 8));
          children.add(
            Text(
              m['reviewReason'] == 'infractionReported'
                  ? '👎 Infraction reported — resolve it in the banner above.'
                  : 'Under review — resolve it in the banner above.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          );
        } else if (m['confirmed'] == true) {
          children.add(const Text('Match confirmed ✓'));
        }
      }
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  Widget _scoreChip(String id, int mine, int opp, String label) =>
      OutlinedButton(
        onPressed: () => _guard(() async => c.submit(id, mine, opp)),
        child: Text(label),
      );

  Widget _standingsCard(Map snap) {
    final theme = Theme.of(context);
    final standings = (snap['standings'] as List?) ?? [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Standings', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            for (final r in standings)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        '${r['rank']}',
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${r['nickname']}'),
                          Text(
                            '${r['deckName']} · ${r['record']}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${r['matchPoints']} pts',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _finished(Map snap) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      children: [
        Text(
          'Tournament complete',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 12),
        _standingsCard(snap),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _confirmEnd,
          icon: const Icon(Icons.add),
          label: const Text('New tournament'),
        ),
      ],
    );
  }
}

class _CreateForm extends StatefulWidget {
  final Future<void> Function(
    String name,
    String nick, {
    required HostingMode mode,
    String? existingDeckId,
    String deck,
    String main,
    String side,
    String format,
    String series,
    TournamentKind kind,
    int rounds,
    int roundMinutes,
  })
  onCreate;
  final String initialNick;
  final bool onlineConfigured;
  final List<Deck> existingDecks;
  const _CreateForm({
    required this.onCreate,
    this.initialNick = '',
    required this.onlineConfigured,
    this.existingDecks = const [],
  });
  @override
  State<_CreateForm> createState() => _CreateFormState();
}

class _CreateFormState extends State<_CreateForm> {
  final name = TextEditingController();
  late final nick = TextEditingController(text: widget.initialNick);
  final deck = TextEditingController();
  final main = TextEditingController();
  final side = TextEditingController();
  // Optional, and only ever used for grouping in statistics.
  final format = TextEditingController();
  final series = TextEditingController();
  // Blank = "decide from the number of players when the event starts".
  final rounds = TextEditingController();
  final timer = TextEditingController();
  bool _busy = false;
  HostingMode? _mode;
  TournamentKind _kind = TournamentKind.swiss;
  // The owner's saved deck to play with; null = "create a new deck below".
  String? _selectedDeckId;

  @override
  void initState() {
    super.initState();
    // Default to reusing a saved deck when one exists, so the host isn't forced
    // to retype a list every event.
    if (widget.existingDecks.isNotEmpty) {
      _selectedDeckId = widget.existingDecks.first.id;
    }
  }

  @override
  void dispose() {
    for (final c in [
      name,
      nick,
      deck,
      main,
      side,
      format,
      series,
      rounds,
      timer,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final decks = widget.existingDecks;
    final newDeck = _selectedDeckId == null;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      children: [
        Text('Create event', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 4),
        const Text(
          'You host on this phone and also play. Players join from their browser.',
        ),
        const SizedBox(height: 12),
        Text('Connection', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              avatar: const Icon(Icons.public, size: 18),
              label: const Text('Online'),
              selected: _mode == HostingMode.online,
              onSelected: (_) => setState(() => _mode = HostingMode.online),
            ),
            ChoiceChip(
              avatar: const Icon(Icons.wifi, size: 18),
              label: const Text('LAN'),
              selected: _mode == HostingMode.lan,
              onSelected: (_) => setState(() => _mode = HostingMode.lan),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(switch (_mode) {
          HostingMode.online =>
            widget.onlineConfigured
                ? 'Players can join from anywhere. Everyone needs internet, and this phone remains the host.'
                : 'Online hosting needs a relay URL in this app build. See docs/ONLINE_HOSTING.md.',
          HostingMode.lan =>
            'Players join on the same Wi-Fi. The tournament keeps working without internet.',
          null => 'Choose how players will connect to this tournament.',
        }, style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        _field('Event name', name, hint: 'e.g. Friday Night Modern'),
        _field('Your nickname', nick, hint: 'e.g. Giuseppe'),
        Text('Structure', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final k in TournamentKind.values)
              ChoiceChip(
                label: Text(k.label),
                selected: _kind == k,
                onSelected: (_) => setState(() => _kind = k),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _kind == TournamentKind.swiss
              ? 'Everyone plays every round. Leave the round count blank and it '
                    'is set from the number of players; you can change it later.'
              : 'Losers are knocked out each round. The bracket length follows '
                    'from how many players enter.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_kind == TournamentKind.swiss) ...[
              Expanded(
                child: _field(
                  'Rounds (optional)',
                  rounds,
                  hint: 'auto',
                  number: true,
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: _field(
                'Round timer (min)',
                timer,
                hint: 'off',
                number: true,
              ),
            ),
          ],
        ),
        // Optional labels. They change nothing about how the event runs; they
        // are what lets statistics say "your Modern record" or "the spring
        // league" later on.
        _field('Format (optional)', format, hint: 'e.g. Modern'),
        _field('Series or league (optional)', series, hint: 'e.g. Spring 2026'),
        if (decks.isNotEmpty) ...[
          Text('Your deck', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final d in decks)
                ChoiceChip(
                  label: Text(d.name),
                  selected: _selectedDeckId == d.id,
                  onSelected: (_) => setState(() => _selectedDeckId = d.id),
                ),
              ChoiceChip(
                label: const Text('+ New deck'),
                selected: newDeck,
                onSelected: (_) => setState(() => _selectedDeckId = null),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (newDeck) ...[
          _field('Your deck name', deck, hint: 'e.g. Domain Zoo'),
          _field('Maindeck', main, lines: 4),
          _field('Sideboard', side, lines: 2),
        ],
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(
            _busy
                ? _mode == HostingMode.online
                      ? 'Opening online lobby…'
                      : 'Starting LAN server…'
                : 'Create & open lobby',
          ),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final useExisting = _selectedDeckId != null;
    if (_mode == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose Online or LAN hosting.')),
      );
      return;
    }
    if (_mode == HostingMode.online && !widget.onlineConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Online hosting is not configured in this app build.'),
        ),
      );
      return;
    }
    if (name.text.trim().isEmpty ||
        nick.text.trim().isEmpty ||
        (!useExisting && deck.text.trim().isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter an event name, a nickname, and pick or name a deck',
          ),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    // Blank or unparseable means "not set": 0 leaves the engine's default.
    final roundCount = _kind == TournamentKind.swiss
        ? (int.tryParse(rounds.text.trim()) ?? 0)
        : 0;
    final minutes = int.tryParse(timer.text.trim()) ?? 0;
    if (useExisting) {
      await widget.onCreate(
        name.text.trim(),
        nick.text.trim(),
        mode: _mode!,
        existingDeckId: _selectedDeckId,
        format: format.text.trim(),
        series: series.text.trim(),
        kind: _kind,
        rounds: roundCount,
        roundMinutes: minutes,
      );
    } else {
      await widget.onCreate(
        name.text.trim(),
        nick.text.trim(),
        mode: _mode!,
        deck: deck.text.trim(),
        main: main.text,
        side: side.text,
        format: format.text.trim(),
        series: series.text.trim(),
        kind: _kind,
        rounds: roundCount,
        roundMinutes: minutes,
      );
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _field(
    String label,
    TextEditingController ctrl, {
    String? hint,
    int lines = 1,
    bool number = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: ctrl,
      maxLines: lines,
      keyboardType: number ? TextInputType.number : null,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );
}
