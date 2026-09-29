package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// fakeSelection is the desktop selection, per MIME type, and counts the reads.
type fakeSelection struct {
	content map[string][]byte
	pastes  int
	// afterFirstPaste replaces the selection once it has been read, as a
	// copy in the guest between two reads would.
	afterFirstPaste map[string][]byte
}

func (selection *fakeSelection) paste(mimeType string, output io.Writer) error {
	selection.pastes++
	content, offered := selection.content[mimeType]
	if selection.afterFirstPaste != nil {
		selection.content, selection.afterFirstPaste = selection.afterFirstPaste, nil
	}
	if !offered {
		return errors.New("exit status 1")
	}
	// wl-paste delivers a large selection in several writes.
	for len(content) > 0 {
		size := min(len(content), 64*1024)
		if _, err := output.Write(content[:size]); err != nil {
			return err
		}
		content = content[size:]
	}
	return nil
}

type stagingFixture struct {
	t         *testing.T
	directory string
	path      string
	selection *fakeSelection
	created   int
}

func newStagingFixture(t *testing.T, selection *fakeSelection) *stagingFixture {
	t.Helper()
	// The staging directory does not exist until something is staged.
	directory := filepath.Join(resolvedTempDir(t), ".riftvm")
	return &stagingFixture{
		t: t, directory: directory, selection: selection,
		path: filepath.Join(directory, ".riftvm-clipboard-01234567-89ab-cdef-0123-456789abcdef.txt"),
	}
}

func (fixture *stagingFixture) capture() clipboardCapture {
	return clipboardCapture{
		paste: fixture.selection.paste,
		createStaging: func(path string) (io.WriteCloser, secureUploadTarget, error) {
			fixture.created++
			return createClipboardStaging(path)
		},
	}
}

func (fixture *stagingFixture) get(request clipboardRequest) clipboardResult {
	fixture.t.Helper()
	if request.MIMEType == "" {
		request.MIMEType = clipboardTextMIME
	}
	request.RelativePath = ".riftvm/" + filepath.Base(fixture.path)
	if _, err := validateClipboardRequest(request); err != nil {
		fixture.t.Fatal(err)
	}
	return fixture.capture().get(fixture.path, request)
}

// sharedFolderEntries lists everything the capture left in the shared folder.
func (fixture *stagingFixture) sharedFolderEntries() []string {
	fixture.t.Helper()
	entries, err := os.ReadDir(fixture.directory)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		fixture.t.Fatal(err)
	}
	var names []string
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	return names
}

func (fixture *stagingFixture) staged() []byte {
	fixture.t.Helper()
	data, err := os.ReadFile(fixture.path)
	if err != nil {
		fixture.t.Fatal(err)
	}
	return data
}

// legacyClipboardResult is the response of the released Agent.
type legacyClipboardResult struct {
	Success   bool   `json:"success"`
	Message   string `json:"message"`
	ByteCount uint64 `json:"byteCount,omitempty"`
	SHA256    string `json:"sha256,omitempty"`
}

// legacyClipboardRequest is the request of the released Host and Agent.
type legacyClipboardRequest struct {
	RelativePath string `json:"relativePath"`
	MIMEType     string `json:"mimeType"`
	ByteCount    uint64 `json:"byteCount,omitempty"`
	SHA256       string `json:"sha256,omitempty"`
}

func TestOldHostCaptureIsStagedAndAnsweredAsBefore(t *testing.T) {
	content := []byte("copied in the guest\nwith unicode: 你好")
	fixture := newStagingFixture(t, &fakeSelection{content: map[string][]byte{clipboardTextMIME: content}})
	// Exactly what a released Host sends for a capture.
	var request clipboardRequest
	if err := json.Unmarshal([]byte(`{"relativePath":"ignored","mimeType":"text/plain;charset=utf-8","byteCount":0,"sha256":""}`), &request); err != nil {
		t.Fatal(err)
	}
	for poll := 0; poll < 2; poll++ {
		result := fixture.get(request)
		encoded, err := json.Marshal(result)
		if err != nil {
			t.Fatal(err)
		}
		want, _ := json.Marshal(legacyClipboardResult{
			Success: true, Message: "Guest clipboard captured.",
			ByteCount: uint64(len(content)), SHA256: checksum(content),
		})
		if string(encoded) != string(want) {
			t.Fatalf("response changed for an old Host:\n got %s\nwant %s", encoded, want)
		}
		if !bytes.Equal(fixture.staged(), content) {
			t.Fatalf("staged %q", fixture.staged())
		}
		if names := fixture.sharedFolderEntries(); len(names) != 1 {
			t.Fatalf("shared folder holds %v", names)
		}
		// The Host removes the item it has read.
		if err := os.Remove(fixture.path); err != nil {
			t.Fatal(err)
		}
	}
	if fixture.selection.pastes != 2 {
		t.Fatalf("selection read %d times for two captures", fixture.selection.pastes)
	}
}

func TestKnownDigestIsAnsweredWithoutTouchingTheSharedFolder(t *testing.T) {
	content := []byte("copied in the guest")
	fixture := newStagingFixture(t, &fakeSelection{content: map[string][]byte{clipboardTextMIME: content}})
	for poll := 0; poll < 3; poll++ {
		result := fixture.get(clipboardRequest{KnownSHA256: checksum(content)})
		want := clipboardResult{
			Success: true, Message: clipboardUnchangedMessage, Unchanged: true,
			ByteCount: uint64(len(content)), SHA256: checksum(content),
		}
		if result != want {
			t.Fatalf("result = %#v", result)
		}
	}
	if fixture.created != 0 || fixture.sharedFolderEntries() != nil {
		t.Fatalf("unchanged selection staged %d files: %v", fixture.created, fixture.sharedFolderEntries())
	}
	if _, err := os.Lstat(fixture.directory); !os.IsNotExist(err) {
		t.Fatalf("staging directory was created: %v", err)
	}
	if fixture.selection.pastes != 3 {
		t.Fatalf("selection read %d times for three polls", fixture.selection.pastes)
	}
}

func TestChangedSelectionIsStagedFromTheFirstRead(t *testing.T) {
	content := []byte("a new selection")
	fixture := newStagingFixture(t, &fakeSelection{content: map[string][]byte{clipboardTextMIME: content}})
	result := fixture.get(clipboardRequest{KnownSHA256: checksum([]byte("the previous selection"))})
	want := clipboardResult{
		Success: true, Message: "Guest clipboard captured.",
		ByteCount: uint64(len(content)), SHA256: checksum(content),
	}
	if result != want {
		t.Fatalf("result = %#v", result)
	}
	if !bytes.Equal(fixture.staged(), content) || fixture.selection.pastes != 1 {
		t.Fatalf("staged %q after %d reads", fixture.staged(), fixture.selection.pastes)
	}
	if names := fixture.sharedFolderEntries(); !reflect.DeepEqual(names, []string{filepath.Base(fixture.path)}) {
		t.Fatalf("shared folder holds %v", names)
	}
}

func TestLargeChangedSelectionIsReadAgainIntoTheStagingFile(t *testing.T) {
	content := bytes.Repeat([]byte("0123456789abcdef"), clipboardUnchangedBufferBytes/16+1)
	fixture := newStagingFixture(t, &fakeSelection{content: map[string][]byte{clipboardTextMIME: content}})
	result := fixture.get(clipboardRequest{KnownSHA256: checksum([]byte("the previous selection"))})
	if !result.Success || result.Unchanged || result.SHA256 != checksum(content) || result.ByteCount != uint64(len(content)) {
		t.Fatalf("result = %#v", result)
	}
	if !bytes.Equal(fixture.staged(), content) || fixture.selection.pastes != 2 {
		t.Fatalf("staged %d bytes after %d reads", len(fixture.staged()), fixture.selection.pastes)
	}

	// The same large selection, once known, is hashed and not staged.
	if err := os.Remove(fixture.path); err != nil {
		t.Fatal(err)
	}
	result = fixture.get(clipboardRequest{KnownSHA256: checksum(content)})
	if !result.Unchanged || fixture.sharedFolderEntries() != nil {
		t.Fatalf("result = %#v, shared folder %v", result, fixture.sharedFolderEntries())
	}
}

func TestSelectionThatChangesBetweenTheReadsIsReportedAsStaged(t *testing.T) {
	first := bytes.Repeat([]byte{'a'}, clipboardUnchangedBufferBytes+1)
	second := []byte("copied while the first read was compared")
	fixture := newStagingFixture(t, &fakeSelection{
		content:         map[string][]byte{clipboardTextMIME: first},
		afterFirstPaste: map[string][]byte{clipboardTextMIME: second},
	})
	result := fixture.get(clipboardRequest{KnownSHA256: checksum([]byte("the previous selection"))})
	// The digest always describes the bytes that were staged.
	if !result.Success || result.SHA256 != checksum(second) || !bytes.Equal(fixture.staged(), second) {
		t.Fatalf("result = %#v, staged %q", result, fixture.staged())
	}
}

func TestMissingFormatNeverTouchesTheSharedFolder(t *testing.T) {
	// Text is copied; the Host probes for an image first, every second.
	selection := &fakeSelection{content: map[string][]byte{clipboardTextMIME: []byte("text")}}
	for name, request := range map[string]clipboardRequest{
		"old host": {MIMEType: clipboardImageMIME},
		"new host": {MIMEType: clipboardImageMIME, KnownSHA256: checksum([]byte("an earlier image"))},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newStagingFixture(t, selection)
			fixture.path = filepath.Join(fixture.directory, ".riftvm-clipboard-01234567-89ab-cdef-0123-456789abcdef.png")
			result := fixture.get(request)
			if want := (clipboardResult{Message: "could not read the Wayland clipboard"}); result != want {
				t.Fatalf("result = %#v", result)
			}
			if fixture.created != 0 {
				t.Fatalf("a missing format staged %d files", fixture.created)
			}
			if _, err := os.Lstat(fixture.directory); !os.IsNotExist(err) {
				t.Fatalf("staging directory was created: %v", err)
			}
		})
	}
}

func TestEmptySelectionIsStagedAsAnEmptyItem(t *testing.T) {
	fixture := newStagingFixture(t, &fakeSelection{content: map[string][]byte{clipboardTextMIME: {}}})
	for name, request := range map[string]clipboardRequest{
		"old host": {},
		"new host": {KnownSHA256: checksum([]byte("the previous selection"))},
	} {
		t.Run(name, func(t *testing.T) {
			result := fixture.get(request)
			want := clipboardResult{Success: true, Message: "Guest clipboard captured.", SHA256: checksum(nil)}
			if result != want || len(fixture.staged()) != 0 {
				t.Fatalf("result = %#v", result)
			}
			if err := os.Remove(fixture.path); err != nil {
				t.Fatal(err)
			}
		})
	}
	result := fixture.get(clipboardRequest{KnownSHA256: checksum(nil)})
	if !result.Unchanged || result.ByteCount != 0 || fixture.sharedFolderEntries() != nil {
		t.Fatalf("result = %#v", result)
	}
}

func TestMalformedKnownDigestIsIgnoredNotRejected(t *testing.T) {
	content := []byte("copied in the guest")
	for name, known := range map[string]string{
		"uppercase": "A" + checksum(content)[1:],
		"short":     checksum(content)[:63],
		"not hex":   "z" + checksum(content)[1:],
		"text":      "unchanged",
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newStagingFixture(t, &fakeSelection{content: map[string][]byte{clipboardTextMIME: content}})
			result := fixture.get(clipboardRequest{KnownSHA256: known})
			if !result.Success || result.Unchanged || !bytes.Equal(fixture.staged(), content) {
				t.Fatalf("result = %#v", result)
			}
		})
	}
}

func TestCaptureRefusesToReplaceAnExistingItem(t *testing.T) {
	fixture := newStagingFixture(t, &fakeSelection{content: map[string][]byte{clipboardTextMIME: []byte("new")}})
	if err := os.MkdirAll(fixture.directory, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fixture.path, []byte("existing"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, request := range []clipboardRequest{{}, {KnownSHA256: checksum([]byte("other"))}} {
		result := fixture.get(request)
		if result.Success || !bytes.Equal(fixture.staged(), []byte("existing")) {
			t.Fatalf("result = %#v, staged %q", result, fixture.staged())
		}
		if names := fixture.sharedFolderEntries(); len(names) != 1 {
			t.Fatalf("temporary staging output was left behind: %v", names)
		}
	}
}

func TestCaptureReportsAStagingFailure(t *testing.T) {
	selection := &fakeSelection{content: map[string][]byte{clipboardTextMIME: []byte("text")}}
	capture := clipboardCapture{
		paste: selection.paste,
		createStaging: func(string) (io.WriteCloser, secureUploadTarget, error) {
			return nil, nil, clipboardStagingError{message: "could not create clipboard staging output: read-only file system"}
		},
	}
	for _, request := range []clipboardRequest{
		{MIMEType: clipboardTextMIME},
		{MIMEType: clipboardTextMIME, KnownSHA256: checksum([]byte("other"))},
	} {
		result := capture.get("/mnt/mac/.riftvm/item.txt", request)
		if want := (clipboardResult{Message: "could not create clipboard staging output: read-only file system"}); result != want {
			t.Fatalf("result = %#v", result)
		}
	}
}

type failingPaste struct {
	content []byte
	err     error
}

func (paste failingPaste) run(_ string, output io.Writer) error {
	if _, err := output.Write(paste.content); err != nil {
		return err
	}
	return paste.err
}

func TestInterruptedCaptureLeavesNothingBehind(t *testing.T) {
	for name, request := range map[string]clipboardRequest{
		"old host": {},
		"new host": {KnownSHA256: checksum([]byte("other"))},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newStagingFixture(t, &fakeSelection{})
			capture := fixture.capture()
			capture.paste = failingPaste{content: []byte("partial"), err: errors.New("signal: killed")}.run
			request.MIMEType = clipboardTextMIME
			result := capture.get(fixture.path, request)
			if want := (clipboardResult{Message: "could not read the Wayland clipboard"}); result != want {
				t.Fatalf("result = %#v", result)
			}
			if names := fixture.sharedFolderEntries(); len(names) != 0 {
				t.Fatalf("interrupted capture left %v", names)
			}
		})
	}
}

func TestOversizedSelectionIsRejected(t *testing.T) {
	if testing.Short() {
		t.Skip("writes more than 100 MiB")
	}
	oversized := make([]byte, maximumClipboardBytes+1)
	for name, request := range map[string]clipboardRequest{
		"old host": {},
		"new host": {KnownSHA256: checksum([]byte("other"))},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newStagingFixture(t, &fakeSelection{content: map[string][]byte{clipboardTextMIME: oversized}})
			result := fixture.get(request)
			if want := (clipboardResult{Message: "clipboard output is invalid"}); result != want {
				t.Fatalf("result = %#v", result)
			}
			if names := fixture.sharedFolderEntries(); len(names) != 0 {
				t.Fatalf("oversized capture left %v", names)
			}
		})
	}
}

func TestClipboardMessagesStayCompatibleAcrossVersions(t *testing.T) {
	known := checksum([]byte("known"))
	// New Host to old Agent: the unknown field is ignored and the request is
	// the one the old Agent has always served.
	sent, err := json.Marshal(clipboardRequest{
		RelativePath: ".riftvm/.riftvm-clipboard-01234567-89ab-cdef-0123-456789abcdef.txt",
		MIMEType:     clipboardTextMIME, KnownSHA256: known,
	})
	if err != nil {
		t.Fatal(err)
	}
	var old legacyClipboardRequest
	if err := json.Unmarshal(sent, &old); err != nil {
		t.Fatal(err)
	}
	if old.MIMEType != clipboardTextMIME || old.ByteCount != 0 || old.SHA256 != "" {
		t.Fatalf("old Agent decoded %#v", old)
	}
	// An old system Agent forwards what it decoded: the field is dropped and
	// the Session Agent stages the selection.
	forwarded, _ := json.Marshal(old)
	var received clipboardRequest
	if err := json.Unmarshal(forwarded, &received); err != nil || knownClipboardDigest(received) != "" {
		t.Fatalf("request behind an old system Agent = %#v (%v)", received, err)
	}

	// Old Host to new Agent: no field, so no new behaviour and no new keys.
	var fromOldHost clipboardRequest
	if err := json.Unmarshal([]byte(`{"relativePath":"x","mimeType":"image/png","byteCount":0,"sha256":""}`), &fromOldHost); err != nil {
		t.Fatal(err)
	}
	if knownClipboardDigest(fromOldHost) != "" {
		t.Fatal("a request without the field named a known digest")
	}
	for _, result := range []clipboardResult{
		{Success: true, Message: "Guest clipboard captured.", ByteCount: 4, SHA256: known},
		{Success: true, Message: "Guest clipboard updated.", ByteCount: 4, SHA256: known},
		{Message: "could not read the Wayland clipboard"},
	} {
		encoded, _ := json.Marshal(result)
		want, _ := json.Marshal(legacyClipboardResult{result.Success, result.Message, result.ByteCount, result.SHA256})
		if string(encoded) != string(want) {
			t.Fatalf("response gained fields: %s, want %s", encoded, want)
		}
	}

	// Old Agent to new Host or new system Agent: a response without the field
	// is a full capture.
	var fromOldAgent clipboardResult
	if err := json.Unmarshal([]byte(`{"success":true,"message":"Guest clipboard captured.","byteCount":4,"sha256":"`+known+`"}`), &fromOldAgent); err != nil {
		t.Fatal(err)
	}
	if fromOldAgent.Unchanged || !fromOldAgent.Success || fromOldAgent.SHA256 != known {
		t.Fatalf("old Agent response decoded as %#v", fromOldAgent)
	}
	encoded, _ := json.Marshal(clipboardResult{Success: true, Message: clipboardUnchangedMessage, ByteCount: 4, SHA256: known, Unchanged: true})
	if want := `{"success":true,"message":"Guest clipboard unchanged.","byteCount":4,"sha256":"` + known + `","unchanged":true}`; string(encoded) != want {
		t.Fatalf("unchanged response = %s", encoded)
	}
}

func TestSystemAgentForwardsOnlyAValidUnchangedAnswer(t *testing.T) {
	known := checksum([]byte("known"))
	request := clipboardRequest{MIMEType: clipboardTextMIME, KnownSHA256: known}
	unchanged := clipboardResult{Success: true, Message: clipboardUnchangedMessage, ByteCount: 5, SHA256: known, Unchanged: true}
	captured := clipboardResult{Success: true, Message: "Guest clipboard captured.", ByteCount: 5, SHA256: known}
	failed := clipboardResult{Message: "could not read the Wayland clipboard"}
	invalid := clipboardResult{Message: "invalid desktop clipboard response"}
	for name, test := range map[string]struct {
		operation string
		request   clipboardRequest
		result    clipboardResult
		want      clipboardResult
	}{
		"unchanged":                     {"clipboardGet", request, unchanged, unchanged},
		"captured":                      {"clipboardGet", request, captured, captured},
		"captured for an old host":      {"clipboardGet", clipboardRequest{MIMEType: clipboardTextMIME}, captured, captured},
		"failed":                        {"clipboardGet", request, failed, failed},
		"set":                           {"clipboardSet", clipboardRequest{MIMEType: clipboardTextMIME, SHA256: known, ByteCount: 5}, captured, captured},
		"unchanged for an old host":     {"clipboardGet", clipboardRequest{MIMEType: clipboardTextMIME}, unchanged, invalid},
		"unchanged with another digest": {"clipboardGet", clipboardRequest{MIMEType: clipboardTextMIME, KnownSHA256: checksum([]byte("other"))}, unchanged, invalid},
		"unchanged without success":     {"clipboardGet", request, clipboardResult{Message: "x", SHA256: known, Unchanged: true}, invalid},
		"unchanged set":                 {"clipboardSet", request, unchanged, invalid},
	} {
		t.Run(name, func(t *testing.T) {
			if got := checkedClipboardProxyResult(test.operation, test.request, test.result); got != test.want {
				t.Fatalf("forwarded %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestKnownDigestDoesNotChangeRequestValidation(t *testing.T) {
	request := clipboardRequest{
		RelativePath: ".riftvm/.riftvm-clipboard-01234567-89ab-cdef-0123-456789abcdef.txt",
		MIMEType:     clipboardTextMIME,
	}
	want, err := validateClipboardRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	for _, known := range []string{checksum([]byte("known")), "not a digest", "A123"} {
		request.KnownSHA256 = known
		if got, err := validateClipboardRequest(request); err != nil || got != want {
			t.Fatalf("known digest %q changed validation: %q, %v", known, got, err)
		}
	}
}
