package server

import (
	"regexp"
	"strings"
)

// Zod/v3 email's ASCII pattern; RE2 has no lookahead, so guard dots separately.
var newEmailPattern = regexp.MustCompile(`^[A-Za-z0-9_'+\-.]*[A-Za-z0-9_+-]@([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,}$`)

func validNewEmail(value string) bool {
	return !strings.HasPrefix(value, ".") && !strings.Contains(value, "..") && newEmailPattern.MatchString(value)
}

func validRegistrationName(value string) bool {
	length := 0
	for _, r := range value {
		length++
		if r > 0xffff {
			length++
		}
		if length >= 2 {
			return true
		}
	}
	return false
}

// Match the existing Nuxt new-password String.length rule after loginString's
// JS trim. Old-password login must not call this policy.
func validNewPassword(password string) bool {
	length := 0
	for _, r := range password {
		length++
		if r > 0xffff {
			length++
		}
		if length >= 6 {
			return true
		}
	}
	return false
}
