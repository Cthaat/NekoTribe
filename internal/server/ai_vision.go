package server

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
	"github.com/Cthaat/NekoTribe/backend-go/internal/ai"
)

const maxVisionMediaID int64 = 9007199254740991

var (
	errVisionImageMissing     = errors.New("vision image unavailable")
	errVisionImageUnsupported = errors.New("vision image type or size unsupported")
	errVisionUnavailable      = errors.New("vision service unavailable")
)

type visionDefinition struct {
	SQL             map[string]string `json:"sql"`
	MaxAltTextBytes int               `json:"max_alt_text_bytes"`
	MaxTags         int               `json:"max_tags"`
	MaxTagChars     int               `json:"max_tag_chars"`
}

var visionContract = func() visionDefinition {
	var contract visionDefinition
	if json.Unmarshal(contracts.AIVision, &contract) != nil || contract.MaxAltTextBytes < 1 || contract.MaxTags < 1 || contract.MaxTagChars < 1 {
		panic("invalid AI vision contract")
	}
	return contract
}()

type storedVisionImage struct {
	ID               int64
	Key, Scope, MIME string
	Size             int64
}

type visionImageReference struct {
	MediaID int64  `json:"media_id"`
	Version string `json:"version"`
}

func (image storedVisionImage) reference() visionImageReference {
	hash := sha256.New()
	fmt.Fprintf(hash, "%d\n%s\n%s\n%d", image.ID, image.Key, image.MIME, image.Size)
	return visionImageReference{image.ID, hex.EncodeToString(hash.Sum(nil))}
}

func validVisionMediaID(id int64) bool { return id >= 1 && id <= maxVisionMediaID }

func (image storedVisionImage) validTypeAndSize() bool {
	return ai.IsVisionImageType(image.MIME) && image.Size >= 1 && image.Size <= ai.MaxVisionImageBytes
}

func (image storedVisionImage) storageKey() (string, error) {
	switch image.Scope {
	case "post":
		return normalizePrivateMediaStorageKey(image.Key, image.Scope)
	case "public":
		if key, valid := s3ManagedKey(image.Key); valid {
			return key, nil
		}
	}
	return "", errLocalFileKey
}

func scanVisionImage(row interface{ Scan(...any) error }) (storedVisionImage, error) {
	var image storedVisionImage
	var key, mime, scope sql.NullString
	var size sql.NullInt64
	err := row.Scan(&image.ID, &key, &scope, &mime, &size)
	image.Key, image.Scope, image.MIME, image.Size = key.String, scope.String, mime.String, size.Int64
	return image, err
}

func readStoredVisionImage(ctx context.Context, config LocalStorageConfig, stored storedVisionImage) (ai.VisionImage, error) {
	if !stored.validTypeAndSize() {
		return ai.VisionImage{}, errVisionImageUnsupported
	}
	key, err := stored.storageKey()
	if err != nil || !validVisionMediaID(stored.ID) {
		return ai.VisionImage{}, errVisionImageMissing
	}
	if config.Unsupported {
		return ai.VisionImage{}, errVisionUnavailable
	}
	var data []byte
	if config.s3 != nil {
		data, err = readS3VisionImage(ctx, config.s3, key, stored.Scope == "post", stored.Size)
	} else {
		data, err = readLocalVisionImage(ctx, config.Root, key, stored.Size)
	}
	if err != nil {
		return ai.VisionImage{}, err
	}
	image := ai.VisionImage{MIMEType: stored.MIME, Data: data}
	if int64(len(data)) != stored.Size || !image.Valid() {
		return ai.VisionImage{}, errVisionImageMissing
	}
	return image, nil
}

func readS3VisionImage(ctx context.Context, storage *s3Storage, key string, private bool, size int64) ([]byte, error) {
	resp, err := storage.request(ctx, http.MethodGet, key, "", "", "", nil, 0, private)
	if err != nil {
		return nil, errVisionUnavailable
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, errVisionImageMissing
	}
	if resp.StatusCode != http.StatusOK {
		return nil, errVisionUnavailable
	}
	encoding := resp.Header.Get("Content-Encoding")
	if (encoding != "" && !strings.EqualFold(encoding, "identity")) || (resp.ContentLength >= 0 && resp.ContentLength != size) {
		return nil, errVisionImageMissing
	}
	return readVisionImageBytes(ctx, resp.Body, size)
}

func readLocalVisionImage(ctx context.Context, rootPath, key string, size int64) ([]byte, error) {
	if rootPath == "" {
		rootPath = "./storage"
	}
	root, err := os.OpenRoot(rootPath)
	if err != nil {
		return nil, visionLocalReadError(err)
	}
	defer root.Close()
	parts := strings.Split(key, "/")
	for i := range parts {
		info, err := root.Lstat(filepath.Join(parts[:i+1]...))
		if err != nil {
			return nil, visionLocalReadError(err)
		}
		if info.Mode()&os.ModeSymlink != 0 || (i < len(parts)-1 && !info.IsDir()) || (i == len(parts)-1 && !info.Mode().IsRegular()) {
			return nil, errVisionImageMissing
		}
	}
	file, err := root.Open(filepath.FromSlash(key))
	if err != nil {
		return nil, visionLocalReadError(err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, visionLocalReadError(err)
	}
	if !info.Mode().IsRegular() || info.Size() != size {
		return nil, errVisionImageMissing
	}
	return readVisionImageBytes(ctx, file, size)
}

func visionLocalReadError(err error) error {
	if errors.Is(err, os.ErrNotExist) {
		return errVisionImageMissing
	}
	return errVisionUnavailable
}

func readVisionImageBytes(ctx context.Context, reader io.Reader, size int64) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(mediaContextReader{ctx: ctx, source: reader}, size+1))
	if errors.Is(err, io.ErrUnexpectedEOF) {
		return nil, errVisionImageMissing
	}
	if err != nil {
		return nil, errVisionUnavailable
	}
	return data, nil
}
