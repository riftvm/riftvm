package main

import (
	"errors"
	"path/filepath"
	"regexp"
	"strings"
)

const (
	clipboardSharedRoot = "/mnt/riftvm-shared"
	clipboardFilePrefix = ".riftvm-clipboard-"
	// clipboardStagingDirectory is the RiftVM-owned entry of a multi-folder
	// share. The Host stages clipboard items there when it shares several
	// folders, because the root of such a share holds only the folders.
	clipboardStagingDirectory = ".riftvm"
	// clipboardStagingDirectoryCapability tells the Host this Agent accepts
	// items in clipboardStagingDirectory.
	clipboardStagingDirectoryCapability = "clipboard-staging-directory-v1"
	maximumClipboardBytes               = 100 * 1024 * 1024
	clipboardTextMIME                   = "text/plain;charset=utf-8"
	clipboardImageMIME                  = "image/png"
)

var clipboardItemPattern = regexp.MustCompile(
	`^\.riftvm-clipboard-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.(?:txt|png)$`,
)

type clipboardRequest struct {
	RelativePath string `json:"relativePath"`
	MIMEType     string `json:"mimeType"`
	ByteCount    uint64 `json:"byteCount,omitempty"`
	SHA256       string `json:"sha256,omitempty"`
}

type clipboardResult struct {
	Success   bool   `json:"success"`
	Message   string `json:"message"`
	ByteCount uint64 `json:"byteCount,omitempty"`
	SHA256    string `json:"sha256,omitempty"`
}

func validateClipboardRequest(request clipboardRequest) (string, error) {
	if request.MIMEType != clipboardTextMIME && request.MIMEType != clipboardImageMIME {
		return "", errors.New("unsupported clipboard MIME type")
	}
	if request.ByteCount > maximumClipboardBytes {
		return "", errors.New("clipboard item exceeds 100 MiB")
	}
	if request.SHA256 != "" && !isLowerHexSHA256(request.SHA256) {
		return "", errors.New("invalid clipboard SHA-256")
	}
	clean := filepath.ToSlash(filepath.Clean(request.RelativePath))
	if clean != request.RelativePath || filepath.IsAbs(clean) || strings.Contains(clean, "..") {
		return "", errors.New("invalid clipboard relative path")
	}
	name := clean
	if directory, file, nested := strings.Cut(clean, "/"); nested {
		if directory != clipboardStagingDirectory {
			return "", errors.New("clipboard path is outside the shared staging root")
		}
		name = file
	}
	if strings.Contains(name, "/") || !strings.HasPrefix(name, clipboardFilePrefix) ||
		!clipboardItemPattern.MatchString(name) {
		return "", errors.New("clipboard path is outside the shared staging root")
	}
	extension := filepath.Ext(name)
	if (request.MIMEType == clipboardTextMIME && extension != ".txt") ||
		(request.MIMEType == clipboardImageMIME && extension != ".png") {
		return "", errors.New("clipboard MIME type does not match the staging extension")
	}
	return filepath.Join(clipboardSharedRoot, filepath.FromSlash(clean)), nil
}

func isLowerHexSHA256(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, character := range value {
		if (character < '0' || character > '9') && (character < 'a' || character > 'f') {
			return false
		}
	}
	return true
}
