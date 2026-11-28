import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../shared/widgets/glass/liquid_glass_tokens.dart';
import '../../../shared/widgets/glass/liquid_glass_surface.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../data/call_media.dart';
import '../data/call_signaling.dart';
import 'call_controller.dart';

class CallMenu extends StatelessWidget {
  const CallMenu({super.key, required this.onSelected});

  final ValueChanged<CallMode> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopupMenuButton<CallMode>(
      tooltip: l10n.t('call.start'),
      icon: const Icon(Icons.call_outlined),
      onSelected: onSelected,
      itemBuilder: (_) => [
        PopupMenuItem(value: CallMode.voice, child: Text(l10n.t('call.voice'))),
        PopupMenuItem(value: CallMode.video, child: Text(l10n.t('call.video'))),
      ],
    );
  }
}

class CallOverlay extends ConsumerStatefulWidget {
  const CallOverlay({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends ConsumerState<CallOverlay> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        ref.read(callControllerProvider).end();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callControllerProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (call.phase != null ||
            call.outcome != null ||
            call.mediaError != null)
          Positioned.fill(
            child: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: LiquidGlassSurface(preset: LiquidGlassPreset.popover,
                      borderRadius: BorderRadius.circular(24), child: _CallPanel(call: call)),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CallPanel extends StatelessWidget {
  const _CallPanel({required this.call});

  final CallController call;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final phase = call.phase;
    final remote = call.remoteVideo;
    final local = call.localVideo;
    final status = switch (phase) {
      CallPhase.incoming =>
        call.mode == CallMode.video
            ? 'call.incoming_video'
            : 'call.incoming_voice',
      CallPhase.preparing => 'call.preparing',
      CallPhase.ringing => 'call.ringing',
      CallPhase.connecting => 'call.connecting',
      CallPhase.connected =>
        call.mode == CallMode.video ? 'call.video' : 'call.voice',
      null => _outcomeText(),
    };
    return Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                l10n.t(status),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (call.peerName case final name?) Text(name),
            if (call.mode == CallMode.video && remote != null && local != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(
                  height: (MediaQuery.sizeOf(context).height * 0.35)
                      .clamp(100, 230)
                      .toDouble(),
                  child: ColoredBox(
                    color: Colors.black,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        RTCVideoView(remote),
                        Positioned(
                          right: 4,
                          bottom: 4,
                          width: 96,
                          height: 72,
                          child: RTCVideoView(local, mirror: true),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                if (phase == CallPhase.incoming)
                  FilledButton.icon(
                    onPressed: () => unawaited(call.accept()),
                    icon: const Icon(Icons.call),
                    label: Text(l10n.t('call.accept')),
                  ),
                if (phase != null)
                  OutlinedButton.icon(
                    onPressed: call.end,
                    icon: const Icon(Icons.call_end),
                    label: Text(
                      l10n.t(switch (phase) {
                        CallPhase.incoming => 'call.reject',
                        CallPhase.preparing ||
                        CallPhase.ringing => 'common.cancel',
                        _ => 'call.hangup',
                      }),
                    ),
                  )
                else
                  TextButton(
                    onPressed: call.clearOutcome,
                    child: Text(l10n.t('common.close')),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _outcomeText() => switch (call.mediaError) {
    CallMediaError.unsupported => 'call.unsupported',
    CallMediaError.insecure => 'call.insecure',
    CallMediaError.permissionDenied => 'call.permission',
    CallMediaError.deviceUnavailable => 'call.device_unavailable',
    CallMediaError.failed => 'call.failed',
    null => switch (call.outcome) {
      CallOutcome.rejected => 'call.rejected',
      CallOutcome.timeout => 'call.timeout',
      CallOutcome.busy => 'call.busy',
      CallOutcome.unavailable => 'call.unavailable',
      CallOutcome.disconnected => 'call.disconnected',
      CallOutcome.ended => 'call.ended',
      CallOutcome.answeredElsewhere => 'call.answered_elsewhere',
      CallOutcome.failed || null => 'call.failed',
    },
  };
}
