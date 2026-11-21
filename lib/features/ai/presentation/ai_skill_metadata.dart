import 'package:flutter/material.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../data/ai_writing_api.dart';

class AiSkillMetadata extends StatelessWidget {
  const AiSkillMetadata({super.key, this.skill, this.modelConfigRevision});

  final AiSkillAvailability? skill;
  final int? modelConfigRevision;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final style = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (skill case final info?)
          Text(
            l10n
                .t('ai.skill.metadata')
                .replaceAll('{name}', l10n.t('ai.skill.${info.id}'))
                .replaceAll('{version}', info.version.toString())
                .replaceAll(
                  '{status}',
                  l10n.t(
                    info.enabled ? 'ai.skill.enabled' : 'ai.skill.disabled',
                  ),
                ),
            style: style,
          ),
        if (modelConfigRevision case final revision?)
          Text(
            l10n
                .t('ai.availability.model_config_revision')
                .replaceAll('{revision}', revision.toString()),
            style: style,
          ),
      ],
    );
  }
}
