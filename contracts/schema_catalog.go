// Package contracts embeds the public, versioned schema contract in the binary.
package contracts

import _ "embed"

// TwoFactorSchemaCatalog is generated from the Nuxt migration authority.
//
//go:embed requirements/two-factor-schema-catalog.json
var TwoFactorSchemaCatalog []byte
