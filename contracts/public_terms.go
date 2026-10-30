package contracts

import _ "embed"

//go:embed requirements/ai-public-terms-catalog.json
var publicTermsCatalog string

// PublicTermsCatalog returns an independent copy of the bundled reviewed catalog.
func PublicTermsCatalog() []byte { return []byte(publicTermsCatalog) }
