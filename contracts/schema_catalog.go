// Package contracts embeds the public, versioned schema contract in the binary.
package contracts

import _ "embed"

// AISkillConfigWrite holds the shared generation-checked publication statements.
//
//go:embed requirements/ai-skill-config-write.json
var AISkillConfigWrite []byte

// TwoFactorSchemaCatalog is generated from the Nuxt migration authority.
//
//go:embed requirements/two-factor-schema-catalog.json
var TwoFactorSchemaCatalog []byte

// MediaSchemaCatalog is generated from the Nuxt migration authority.
//
//go:embed requirements/media-schema-catalog.json
var MediaSchemaCatalog []byte

// MediaDeleteReferences holds the shared media reference query.
//
//go:embed requirements/media-delete-references.json
var MediaDeleteReferences []byte

// MediaPrivateRead holds the shared private-media authorization query.
//
//go:embed requirements/media-private-read.json
var MediaPrivateRead []byte

// MediaPrivateBind holds the shared protected attachment permission queries.
//
//go:embed requirements/media-private-bind.json
var MediaPrivateBind []byte

// UserSettingsSchemaCatalog is generated from the Nuxt migration authority.
//
//go:embed requirements/user-settings-schema-catalog.json
var UserSettingsSchemaCatalog []byte

// UserVisibilitySQL contains the Oracle statements shared by the three native backends.
//
//go:embed requirements/user-visibility-sql.json
var UserVisibilitySQL []byte

// UserDiscoverySQL contains the shared search and recommendation queries.
//
//go:embed requirements/user-discovery-sql.json
var UserDiscoverySQL []byte

//go:embed requirements/direct-realtime-access.json
var DirectRealtimeAccess []byte

//go:embed requirements/direct-message-delete.json
var DirectMessageDelete []byte

//go:embed requirements/user-avatar.json
var UserAvatarContract []byte

//go:embed requirements/account-statements.json
var AccountStatementsContract []byte

//go:embed requirements/moderation-appeals.json
var ModerationAppealsContract []byte

//go:embed requirements/moderation-reports.json
var ModerationReportsContract []byte

//go:embed requirements/post-likers.json
var PostLikersSQL []byte

//go:embed requirements/content-analytics.json
var ContentAnalyticsSQL []byte

//go:embed requirements/recommendation-feedback.json
var RecommendationFeedbackSQL []byte

//go:embed requirements/sentiment-retirement.json
var SentimentRetirement []byte

//go:embed requirements/moderation-dashboard.json
var ModerationDashboardContract []byte

//go:embed requirements/moderation-user-queue.json
var ModerationUserQueueContract []byte

//go:embed requirements/moderation-content-queue.json
var ModerationContentQueueContract []byte

//go:embed requirements/moderation-post-actions.json
var ModerationPostActionsContract []byte

//go:embed requirements/moderation-user-actions.json
var ModerationUserActionsContract []byte

//go:embed requirements/moderation-publish-policy.json
var ModerationPublishPolicyContract []byte

//go:embed requirements/moderation-ban-expiry.json
var ModerationBanExpiryContract []byte

// AIConversationSchemaCatalog is generated from the Nuxt migration authority.
//
//go:embed requirements/ai-conversation-schema-catalog.json
var AIConversationSchemaCatalog []byte

//go:embed requirements/ai-skill-schema-catalog.json
var AISkillSchemaCatalog []byte

//go:embed requirements/ai-group-evidence.json
var AIGroupEvidence []byte

//go:embed requirements/ai-group-knowledge-source.json
var AIGroupKnowledgeSource string

//go:embed requirements/ai-knowledge-answer.json
var AIKnowledgeAnswerSchema []byte

//go:embed requirements/ai-group-draft.json
var AIGroupDraft []byte

//go:embed requirements/ai-moderation-advice.json
var AIModerationAdvice []byte

//go:embed requirements/ai-moderation-feedback.json
var AIModerationFeedback []byte

//go:embed requirements/ai-model-quota.json
var AIModelQuota []byte
