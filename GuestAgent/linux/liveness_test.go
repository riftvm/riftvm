package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// testHost is the Host end of an authenticated in-memory session.
type testHost struct {
	t            *testing.T
	connection   net.Conn
	token        []byte
	sessionID    string
	sentSequence uint64
	lastReceived uint64
	done         chan error
}

func startTestSession(t *testing.T, input guestInput, hooks sessionHooks) *testHost {
	t.Helper()
	token := bytes.Repeat([]byte{0x4a}, 32)
	config := enrollment{SchemaVersion: 1, MachineID: "liveness", Token: token, Port: guestAgentPort}
	host, guest := net.Pipe()
	done := make(chan error, 1)
	go func() { done <- serveSession(guest, config, input, hooks) }()
	if err := host.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	var greeting hello
	if err := readFrame(host, &greeting); err != nil {
		t.Fatal(err)
	}
	hostNonce := "test-host"
	response := welcome{Version: protocolVersion, HostNonce: hostNonce}
	response.Proof = sign(token, fmt.Sprintf("host|%d|%s|%s|%s", protocolVersion, config.MachineID, greeting.GuestNonce, hostNonce))
	if err := writeFrame(host, response); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256([]byte(fmt.Sprintf("session|%s|%s|%s", config.MachineID, greeting.GuestNonce, hostNonce)))
	return &testHost{
		t: t, connection: host, token: token, done: done,
		sessionID: base64.StdEncoding.EncodeToString(digest[:]),
	}
}

func (host *testHost) send(requestID, operation string, payload []byte) {
	host.t.Helper()
	host.sentSequence++
	request := makeEnvelope(host.token, host.sessionID, host.sentSequence, requestID, operation, payload)
	if err := writeFrame(host.connection, request); err != nil {
		host.t.Fatalf("send %s: %v", operation, err)
	}
}

// receive reads the next response and verifies it exactly as the Host does:
// authenticated, from this session, with a strictly increasing sequence.
func (host *testHost) receive() envelope {
	host.t.Helper()
	var response envelope
	if err := readFrame(host.connection, &response); err != nil {
		host.t.Fatalf("receive: %v", err)
	}
	if err := verifyEnvelope(host.token, host.sessionID, response, host.lastReceived); err != nil {
		host.t.Fatalf("response rejected: %v", err)
	}
	host.lastReceived = response.Sequence
	return response
}

func (host *testHost) close() {
	host.connection.Close()
	<-host.done
}

// A download start hashes its whole source before it answers. The Host
// disconnects after 30 seconds without a response, so heartbeats must be
// answered while that transfer request is still running.
func TestSlowTransferDoesNotDelayHeartbeats(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	host := startTestSession(t, &recordingInput{available: true}, sessionHooks{
		readStatus: func(bool, bool) status { return status{AgentVersion: "test", BootID: "boot"} },
		handleTransfer: func(session *transferSession, operation string, payload []byte) transferResult {
			if operation == "downloadInfo" {
				close(entered)
				<-release
			}
			return session.handle(operation, payload)
		},
	})
	defer func() { unblock(); host.close() }()

	source := filepath.Join(resolvedTempDir(t), "source.bin")
	content := bytes.Repeat([]byte("slow-transfer"), 4096)
	if err := os.WriteFile(source, content, 0600); err != nil {
		t.Fatal(err)
	}
	host.send("download", "downloadInfo", mustJSON(t, downloadInfoRequest{TransferID: transferTestID, SourcePath: source}))
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("transfer did not start")
	}

	// Later control requests queue behind the transfer, in order.
	host.send("cancel-unknown", "transferCancel", mustJSON(t, transferID{TransferID: "99999999-2222-3333-4444-555555555555"}))
	for index := 0; index < 3; index++ {
		requestID := fmt.Sprintf("heartbeat-%d", index)
		operation := "heartbeat"
		if index == 2 {
			operation = "status"
		}
		started := time.Now()
		host.send(requestID, operation, nil)
		response := host.receive()
		if response.RequestID != requestID || response.Operation != operation {
			t.Fatalf("liveness request %s was answered by %#v", requestID, response)
		}
		if elapsed := time.Since(started); elapsed > time.Second {
			t.Fatalf("liveness response took %v behind a transfer", elapsed)
		}
		var value status
		if err := json.Unmarshal(response.Payload, &value); err != nil || value.BootID != "boot" {
			t.Fatalf("status payload = %s (%v)", response.Payload, err)
		}
	}

	unblock()
	response := host.receive()
	if response.RequestID != "download" || response.Operation != "downloadInfo" {
		t.Fatalf("transfer response = %#v", response)
	}
	var result transferResult
	if err := json.Unmarshal(response.Payload, &result); err != nil {
		t.Fatal(err)
	}
	if !result.Success || result.SHA256 != checksum(content) || result.TotalBytes == nil || *result.TotalBytes != uint64(len(content)) {
		t.Fatalf("transfer result = %#v", result)
	}
	response = host.receive()
	if response.RequestID != "cancel-unknown" || response.Operation != "transferCancel" {
		t.Fatalf("control requests were reordered: %#v", response)
	}
}

// Status is slow on a busy desktop. It must not hold up transfers either.
func TestSlowStatusDoesNotDelayControlRequests(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	host := startTestSession(t, &recordingInput{available: true}, sessionHooks{
		readStatus: func(bool, bool) status {
			close(entered)
			<-release
			return status{AgentVersion: "test"}
		},
	})
	defer func() { unblock(); host.close() }()
	host.send("status", "status", nil)
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("status did not start")
	}
	host.send("cancel", "transferCancel", mustJSON(t, transferID{TransferID: transferTestID}))
	if response := host.receive(); response.RequestID != "cancel" {
		t.Fatalf("control request waited for status: %#v", response)
	}
	unblock()
	if response := host.receive(); response.RequestID != "status" {
		t.Fatalf("status response = %#v", response)
	}
}

func TestLivenessRequestsKeepTheirOrder(t *testing.T) {
	var lock sync.Mutex
	calls := 0
	host := startTestSession(t, &recordingInput{available: true}, sessionHooks{
		readStatus: func(bool, bool) status {
			lock.Lock()
			defer lock.Unlock()
			calls++
			return status{UptimeSeconds: uint64(calls)}
		},
	})
	defer host.close()
	for index := 1; index <= 8; index++ {
		host.send(fmt.Sprintf("heartbeat-%d", index), "heartbeat", nil)
	}
	for index := 1; index <= 8; index++ {
		response := host.receive()
		var value status
		if err := json.Unmarshal(response.Payload, &value); err != nil {
			t.Fatal(err)
		}
		if response.RequestID != fmt.Sprintf("heartbeat-%d", index) || value.UptimeSeconds != uint64(index) {
			t.Fatalf("heartbeat %d answered by %#v (%d)", index, response, value.UptimeSeconds)
		}
	}
}

func TestSessionEndInterruptsARunningChecksum(t *testing.T) {
	source := filepath.Join(resolvedTempDir(t), "source.bin")
	if err := os.WriteFile(source, bytes.Repeat([]byte{7}, 4096), 0600); err != nil {
		t.Fatal(err)
	}
	session := newTransferSession()
	defer session.close()
	session.interrupt()
	result := session.handle("downloadInfo", mustJSON(t, downloadInfoRequest{TransferID: transferTestID, SourcePath: source}))
	if result.Success || result.Message != errTransferInterrupted.Error() {
		t.Fatalf("interrupted checksum result = %#v", result)
	}
	if len(session.downloads) != 0 {
		t.Fatal("interrupted download remained registered")
	}
}

func TestUnsupportedOperationStillEndsTheSession(t *testing.T) {
	host := startTestSession(t, &recordingInput{available: true}, sessionHooks{
		readStatus: func(bool, bool) status { return status{} },
	})
	host.send("unknown", "arbitraryCommand", nil)
	select {
	case err := <-host.done:
		if err == nil || err.Error() != "unsupported operation" {
			t.Fatalf("session error = %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("session survived an unsupported operation")
	}
	host.connection.Close()
}
