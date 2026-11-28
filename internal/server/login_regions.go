package server

import (
	"encoding/json"
	"strings"
)

type loginRegionMap map[string]string

// Match the deployment-local canonical IP snapshot used by Nuxt and Rust.
func parseLoginRegions(value string) loginRegionMap {
	var regions loginRegionMap
	if json.Unmarshal([]byte(value), &regions) != nil {
		return nil
	}
	return regions
}
func (m loginRegionMap) changed(previous, current string) bool {
	a, b := canonicalClientIP(previous), canonicalClientIP(current)
	if a == "unknown" || b == "unknown" {
		return false
	}
	first, last := strings.TrimSpace(m[a]), strings.TrimSpace(m[b])
	return first != "" && last != "" && first != last
}
