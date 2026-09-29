package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"testing"
)

type discardingInput struct{}

func (discardingInput) Available() bool                { return true }
func (discardingInput) AbsolutePointerAvailable() bool { return true }
func (discardingInput) Write([]inputEvent) error       { return nil }
func (discardingInput) Close() error                   { return nil }

// BenchmarkInputFrame measures one authenticated input round trip through the
// real session loop: frame decode, envelope verification, batch validation,
// injection into a no-op device, and the signed acknowledgement. It uses only
// the wire protocol, so the same benchmark runs against older Agent sources.
func BenchmarkInputFrame(b *testing.B) {
	token := bytes.Repeat([]byte{0x4a}, 32)
	config := enrollment{SchemaVersion: 1, MachineID: "benchmark", Token: token, Port: guestAgentPort}
	host, guest := net.Pipe()
	done := make(chan error, 1)
	go func() { done <- serveWithInput(guest, config, discardingInput{}) }()
	defer func() { host.Close(); <-done }()

	var greeting hello
	if err := readFrame(host, &greeting); err != nil {
		b.Fatal(err)
	}
	hostNonce := "benchmark-host"
	response := welcome{Version: protocolVersion, HostNonce: hostNonce}
	response.Proof = sign(token, fmt.Sprintf("host|%d|%s|%s|%s", protocolVersion, config.MachineID, greeting.GuestNonce, hostNonce))
	if err := writeFrame(host, response); err != nil {
		b.Fatal(err)
	}
	digest := sha256.Sum256([]byte(fmt.Sprintf("session|%s|%s|%s", config.MachineID, greeting.GuestNonce, hostNonce)))
	sessionID := base64.StdEncoding.EncodeToString(digest[:])
	// A typical pointer report with a key transition, as the Host coalesces it.
	payload, err := json.Marshal(inputBatch{Events: []inputEvent{
		{Type: 3, Code: 0, Value: 16000}, {Type: 3, Code: 1, Value: 9000}, {Type: 0},
		{Type: 1, Code: 30, Value: 1}, {Type: 0},
		{Type: 1, Code: 30, Value: 0}, {Type: 0},
	}})
	if err != nil {
		b.Fatal(err)
	}
	// Pre-sign the requests so the measurement is dominated by the Agent.
	frames := make([][]byte, b.N)
	for index := range frames {
		var frame bytes.Buffer
		request := makeEnvelope(token, sessionID, uint64(index+1), "benchmark-input", "input", payload)
		if err := writeFrame(&frame, request); err != nil {
			b.Fatal(err)
		}
		frames[index] = frame.Bytes()
	}
	header := make([]byte, 4)
	body := make([]byte, 4096)
	b.ReportAllocs()
	b.ResetTimer()
	for index := 0; index < b.N; index++ {
		if _, err := host.Write(frames[index]); err != nil {
			b.Fatal(err)
		}
		if _, err := io.ReadFull(host, header); err != nil {
			b.Fatal(err)
		}
		length := int(header[0])<<24 | int(header[1])<<16 | int(header[2])<<8 | int(header[3])
		if length > len(body) {
			b.Fatalf("unexpected acknowledgement size %d", length)
		}
		if _, err := io.ReadFull(host, body[:length]); err != nil {
			b.Fatal(err)
		}
	}
}
