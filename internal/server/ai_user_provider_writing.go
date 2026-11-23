package server

import (
	"context"

	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

func activeUserWritingProvider(ctx context.Context, repository any, user int64, settings userProviderSettings) (*userProviderRecord, string, error) {
	if settings.key == nil {
		return nil, "", nil
	}
	store, ok := repository.(userProviderReader)
	if !ok {
		return nil, "", errUserProviderUnavailable
	}
	record, err := store.readUserProvider(ctx, user)
	if err != nil {
		return nil, "", errUserProviderUnavailable
	}
	if record == nil || !record.Enabled {
		return nil, "", nil
	}
	key, err := settings.open(user, record)
	if err != nil {
		return nil, "", errUserProviderUnavailable
	}
	return record, key, nil
}

func writingSelection(ctx context.Context, store aiWritingStore, user int64, config RefreshConfig) (ai.Selection, func(string) (string, error), error) {
	record, key, err := activeUserWritingProvider(ctx, store, user, config.userProvider)
	if err != nil {
		return ai.Selection{}, nil, errWritingUnavailable
	}
	if record != nil {
		credential := userProviderContract.ProfileID
		selection := ai.Selection{
			ConfigurationRevision: record.Revision, Role: "writing", ProfileID: userProviderContract.ProfileID,
			ProviderID: userProviderContract.ProfileID, Adapter: "openai-compatible", BaseURL: record.BaseURL,
			Model: record.Model, APIKeyEnv: &credential, ContextWindowTokens: userProviderContract.ContextWindowTokens,
			MaxOutputTokens: userProviderContract.MaxOutputTokens,
		}
		return selection, func(reference string) (string, error) {
			if reference != credential {
				return "", errWritingUnavailable
			}
			return key, nil
		}, nil
	}
	router, err := config.modelRouter()
	if err != nil {
		return ai.Selection{}, nil, errWritingUnavailable
	}
	selection, err := router.Select("writing", nil)
	if err != nil {
		return ai.Selection{}, nil, errWritingUnavailable
	}
	return selection, config.aiCredential, nil
}
