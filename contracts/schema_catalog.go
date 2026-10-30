// Package contracts embeds the public, versioned schema contract in the binary.
package contracts

import _ "embed"

// TwoFactorSchemaCatalog is generated from the Nuxt migration authority.
//
//go:embed requirements/two-factor-schema-catalog.json
var TwoFactorSchemaCatalog []byte

// MediaSchemaCatalog is generated from the Nuxt migration authority.
//
//go:embed requirements/media-schema-catalog.json
var MediaSchemaCatalog []byte

// UserSettingsSchemaCatalog is generated from the Nuxt migration authority.
//
//go:embed requirements/user-settings-schema-catalog.json
var UserSettingsSchemaCatalog []byte

// AIConversationSchemaCatalog is generated from the Nuxt migration authority.
//
//go:embed requirements/ai-conversation-schema-catalog.json
var AIConversationSchemaCatalog []byte
