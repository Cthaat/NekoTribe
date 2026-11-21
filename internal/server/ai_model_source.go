package server

import (
	"io"
	"os"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

const maxAIModelConfigBytes = 65536

type aiModelFile struct {
	path      string
	mu        sync.Mutex
	nextCheck time.Time
	active    *ai.ModelRouter
	revision  int64
}

func (c RefreshConfig) modelRouter() (*ai.ModelRouter, error) {
	if c.aiModelFile != nil {
		return c.aiModelFile.load()
	}
	if len(c.AIModelConfig) == 0 || len(c.AIModelConfig) > maxAIModelConfigBytes {
		return nil, ai.ErrInvalidConfiguration
	}
	return ai.NewModelRouter([]byte(c.AIModelConfig))
}

func (s *aiModelFile) load() (*ai.ModelRouter, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if now := time.Now(); !now.Before(s.nextCheck) {
		s.nextCheck = now.Add(time.Second)
		if candidate, revision := readAIModelFile(s.path); candidate != nil && revision > s.revision {
			s.active, s.revision = candidate, revision
		}
	}
	if s.active == nil {
		return nil, ai.ErrInvalidConfiguration
	}
	return s.active, nil
}

func readAIModelFile(path string) (*ai.ModelRouter, int64) {
	if info, err := os.Stat(path); err != nil || !info.Mode().IsRegular() {
		return nil, 0
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, 0
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxAIModelConfigBytes+1))
	if err != nil || len(data) > maxAIModelConfigBytes || !utf8.Valid(data) {
		return nil, 0
	}
	router, err := ai.NewModelRouter(data)
	if err != nil {
		return nil, 0
	}
	selection, err := router.Select("knowledge", nil)
	if err != nil {
		return nil, 0
	}
	return router, selection.ConfigurationRevision
}
