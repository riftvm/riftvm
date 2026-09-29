package main

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

// deviceWrite is one Write received by one fake uinput device.
type deviceWrite struct {
	target inputTarget
	data   []byte
}

type recordingDevices struct {
	writes  []deviceWrite
	missing map[inputTarget]bool
	failAt  int
}

type recordingDevice struct {
	devices *recordingDevices
	target  inputTarget
}

func (device recordingDevice) Write(data []byte) (int, error) {
	devices := device.devices
	if devices.failAt > 0 && len(devices.writes)+1 == devices.failAt {
		return 0, errors.New("injected write failure")
	}
	devices.writes = append(devices.writes, deviceWrite{device.target, append([]byte(nil), data...)})
	return len(data), nil
}

func (devices *recordingDevices) writer(target inputTarget) io.Writer {
	if devices.missing[target] {
		return nil
	}
	return recordingDevice{devices, target}
}

// legacyWriteInputReports is the released implementation, kept verbatim as the
// reference: one 24-byte write per event, a report routed at each SYN_REPORT.
func legacyWriteInputReports(events []inputEvent, lastPointer *inputTarget, devices *recordingDevices) error {
	start := 0
	for index, event := range events {
		if event.Type != 0 {
			continue
		}
		report := events[start : index+1]
		target, moves := inputReportTarget(report, *lastPointer)
		writer := devices.writer(target)
		if writer == nil {
			return syscall.ENODEV
		}
		if moves {
			*lastPointer = target
		}
		for _, event := range report {
			data := make([]byte, 24)
			binary.LittleEndian.PutUint16(data[16:18], event.Type)
			binary.LittleEndian.PutUint16(data[18:20], event.Code)
			binary.LittleEndian.PutUint32(data[20:24], uint32(event.Value))
			if _, err := writer.Write(data); err != nil {
				return err
			}
		}
		start = index + 1
	}
	return nil
}

// deviceStreams merges adjacent writes to the same device. Two recordings with
// equal streams delivered the same bytes to every device in the same order
// across devices, however the bytes were split into writes.
func deviceStreams(writes []deviceWrite) []deviceWrite {
	var streams []deviceWrite
	for _, write := range writes {
		if count := len(streams); count > 0 && streams[count-1].target == write.target {
			streams[count-1].data = append(streams[count-1].data, write.data...)
			continue
		}
		streams = append(streams, deviceWrite{write.target, append([]byte(nil), write.data...)})
	}
	return streams
}

var inputPathCases = map[string][]inputEvent{
	"key press": {{Type: 1, Code: 30, Value: 1}, {Type: 0}},
	"key repeat and release": {
		{Type: 1, Code: 30, Value: 2}, {Type: 0},
		{Type: 1, Code: 30, Value: 0}, {Type: 0},
	},
	"absolute motion": {{Type: 3, Code: 0, Value: 32767}, {Type: 3, Code: 1, Value: 0}, {Type: 0}},
	"relative motion with negative delta": {
		{Type: 2, Code: 0, Value: -32767}, {Type: 2, Code: 1, Value: 12}, {Type: 0},
	},
	"wheel": {{Type: 2, Code: 8, Value: -1}, {Type: 2, Code: 6, Value: 1}, {Type: 0}},
	"keyboard between pointer reports": {
		{Type: 3, Code: 0, Value: 100}, {Type: 3, Code: 1, Value: 200}, {Type: 0},
		{Type: 1, Code: 42, Value: 1}, {Type: 1, Code: 30, Value: 1}, {Type: 0},
		{Type: 1, Code: 272, Value: 1}, {Type: 0},
		{Type: 2, Code: 0, Value: 5}, {Type: 0},
		{Type: 1, Code: 272, Value: 0}, {Type: 0},
		{Type: 1, Code: 30, Value: 0}, {Type: 1, Code: 42, Value: 0}, {Type: 0},
	},
	"button with relative motion": {
		{Type: 1, Code: 273, Value: 1}, {Type: 2, Code: 1, Value: 2}, {Type: 0},
	},
	"bare synchronization": {{Type: 0}},
	"session key release":  {{Type: 1, Code: 28, Value: 0}, {Type: 0}},
}

func TestInputReportBytesMatchOneWritePerEvent(t *testing.T) {
	for name, events := range inputPathCases {
		for _, initial := range []inputTarget{targetAbsolute, targetRelative} {
			t.Run(fmt.Sprintf("%s/pointer=%d", name, initial), func(t *testing.T) {
				legacyPointer, pointer := initial, initial
				legacy, current := &recordingDevices{}, &recordingDevices{}
				if err := legacyWriteInputReports(events, &legacyPointer, legacy); err != nil {
					t.Fatal(err)
				}
				if err := writeInputReports(events, &pointer, current.writer, nil); err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(deviceStreams(current.writes), deviceStreams(legacy.writes)) {
					t.Fatalf("device bytes changed:\n got %#v\nwant %#v", current.writes, legacy.writes)
				}
				if pointer != legacyPointer {
					t.Fatalf("last pointer = %d, want %d", pointer, legacyPointer)
				}
				reports := 0
				for _, event := range events {
					if event.Type == 0 {
						reports++
					}
				}
				if len(current.writes) != reports {
					t.Fatalf("%d writes for %d reports", len(current.writes), reports)
				}
				for _, write := range current.writes {
					if len(write.data)%inputEventBytes != 0 {
						t.Fatalf("write of %d bytes splits an input_event", len(write.data))
					}
					last := write.data[len(write.data)-inputEventBytes:]
					if !bytes.Equal(last, make([]byte, inputEventBytes)) {
						t.Fatalf("write does not end with SYN_REPORT: %v", last)
					}
				}
			})
		}
	}
}

func TestInputReportForMissingDeviceKeepsEarlierReports(t *testing.T) {
	events := []inputEvent{
		{Type: 1, Code: 30, Value: 1}, {Type: 0},
		{Type: 3, Code: 0, Value: 1}, {Type: 0},
		{Type: 1, Code: 30, Value: 0}, {Type: 0},
	}
	legacyPointer, pointer := targetRelative, targetRelative
	legacy := &recordingDevices{missing: map[inputTarget]bool{targetAbsolute: true}}
	current := &recordingDevices{missing: map[inputTarget]bool{targetAbsolute: true}}
	legacyErr := legacyWriteInputReports(events, &legacyPointer, legacy)
	err := writeInputReports(events, &pointer, current.writer, nil)
	if !errors.Is(err, syscall.ENODEV) || !errors.Is(legacyErr, syscall.ENODEV) {
		t.Fatalf("errors = %v, %v; want ENODEV", err, legacyErr)
	}
	if !reflect.DeepEqual(deviceStreams(current.writes), deviceStreams(legacy.writes)) || len(current.writes) != 1 {
		t.Fatalf("writes before the missing device changed: %#v vs %#v", current.writes, legacy.writes)
	}
	if pointer != legacyPointer {
		t.Fatalf("last pointer = %d, want %d", pointer, legacyPointer)
	}
}

func TestInputReportWriteFailureStopsAtTheFailingReport(t *testing.T) {
	events := []inputEvent{
		{Type: 1, Code: 30, Value: 1}, {Type: 0},
		{Type: 2, Code: 0, Value: 1}, {Type: 0},
		{Type: 3, Code: 0, Value: 1}, {Type: 0},
	}
	pointer := targetAbsolute
	devices := &recordingDevices{failAt: 2}
	if err := writeInputReports(events, &pointer, devices.writer, nil); err == nil {
		t.Fatal("write failure was not reported")
	}
	if len(devices.writes) != 1 || devices.writes[0].target != targetKeyboard {
		t.Fatalf("writes = %#v", devices.writes)
	}
	// As before, the failing report has already claimed the pointer and no
	// later report was routed.
	if pointer != targetRelative {
		t.Fatalf("last pointer = %d", pointer)
	}
}

func TestInputReportReusesScratchWithoutLeakingEarlierReports(t *testing.T) {
	var scratch [maxInputEvents * inputEventBytes]byte
	pointer := targetAbsolute
	devices := &recordingDevices{}
	events := inputPathCases["keyboard between pointer reports"]
	if err := writeInputReports(events, &pointer, devices.writer, scratch[:0]); err != nil {
		t.Fatal(err)
	}
	reference := &recordingDevices{}
	referencePointer := targetAbsolute
	if err := legacyWriteInputReports(events, &referencePointer, reference); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(deviceStreams(devices.writes), deviceStreams(reference.writes)) {
		t.Fatal("reused scratch buffer changed the device bytes")
	}
}

func TestInputReportReachesAFileDescriptorUnchanged(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "uinput")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	events := inputPathCases["key repeat and release"]
	pointer := targetAbsolute
	if err := writeInputReports(events, &pointer, func(inputTarget) io.Writer { return file }, nil); err != nil {
		t.Fatal(err)
	}
	written, err := os.ReadFile(file.Name())
	if err != nil {
		t.Fatal(err)
	}
	legacy := &recordingDevices{}
	legacyPointer := targetAbsolute
	if err := legacyWriteInputReports(events, &legacyPointer, legacy); err != nil {
		t.Fatal(err)
	}
	var want []byte
	for _, write := range legacy.writes {
		want = append(want, write.data...)
	}
	if !bytes.Equal(written, want) {
		t.Fatalf("descriptor received %v, want %v", written, want)
	}
}

func TestInputDiagnosticTextIsUnchanged(t *testing.T) {
	for name, events := range inputPathCases {
		parts := make([]string, 0, len(events))
		for _, event := range events {
			parts = append(parts, fmt.Sprintf("%d/%d/%d", event.Type, event.Code, event.Value))
		}
		if got, want := formatInputReport(events), strings.Join(parts, " "); got != want {
			t.Fatalf("%s: got %q, want %q", name, got, want)
		}
	}
	if got := formatInputReport(nil); got != "" {
		t.Fatalf("empty report = %q", got)
	}
}

func TestInputIsDecodedOnceWithUnchangedResults(t *testing.T) {
	device := &recordingInput{available: true}
	payload := []byte(`{"events":[{"type":1,"code":30,"value":1},{"type":0,"code":0,"value":0}],"traceID":"t-1","future":true}`)
	result, events := handleInputEvents(device, payload)
	if !result.Success || result.TraceID != "t-1" || len(events) != 2 || !reflect.DeepEqual(events, device.events) {
		t.Fatalf("result=%#v events=%#v", result, events)
	}
	for name, test := range map[string]struct {
		payload string
		device  guestInput
		message string
		traceID string
	}{
		"rejected batch keeps its trace": {
			`{"events":[{"type":1,"code":30,"value":1}],"traceID":"t-2"}`,
			&recordingInput{available: true}, "input batch must end with SYN_REPORT", "t-2",
		},
		"mistyped field keeps the decoded trace": {
			`{"traceID":"t-3","events":"none"}`,
			&recordingInput{available: true}, "invalid input payload", "t-3",
		},
		"malformed": {`{"events":`, &recordingInput{available: true}, "invalid input payload", ""},
		"unavailable device wins over validation": {
			`{"events":[],"traceID":"t-4"}`, &recordingInput{}, "uinput is unavailable", "t-4",
		},
		"write failure": {
			`{"events":[{"type":0,"code":0,"value":0}]}`,
			&recordingInput{available: true, err: errors.New("write")}, "could not inject input", "",
		},
	} {
		t.Run(name, func(t *testing.T) {
			result, events := handleInputEvents(test.device, []byte(test.payload))
			if result.Success || events != nil || result.Message != test.message || result.TraceID != test.traceID {
				t.Fatalf("result=%#v events=%#v", result, events)
			}
			if result.GuestReceivedAtUnixNanoseconds == 0 || result.UinputCompletedAtUnixNanoseconds != 0 {
				t.Fatalf("timestamps=%#v", result)
			}
		})
	}
}

// legacyEnvelopeText is the released formatting of the authenticated text.
func legacyEnvelopeText(value envelope) string {
	return fmt.Sprintf("message|%d|%s|%d|%s|%s|%s", value.Version, value.SessionID, value.Sequence, value.RequestID, value.Operation, base64.StdEncoding.EncodeToString(value.Payload))
}

func TestEnvelopeTextAndProofAreByteIdentical(t *testing.T) {
	token := bytes.Repeat([]byte{0x5a}, 32)
	for _, value := range []envelope{
		{},
		{Version: 1, SessionID: "session-a", Sequence: 7, RequestID: "request-7", Operation: "status", Payload: []byte("payload")},
		{Version: 1, SessionID: "s", Sequence: ^uint64(0), RequestID: "6E0B7C1E-7B0B-4B59-8C7B-0D8E5F0F2C11", Operation: "input", Payload: []byte(`{"events":[]}`)},
		{Version: -3, SessionID: "a|b", Sequence: 1, RequestID: "üñí|%s%d", Operation: "\xff\x00", Payload: []byte{0, 1, 2, 0xfb, 0xff}},
		{Version: 1, SessionID: "s", Sequence: 2, RequestID: "r", Operation: "clipboardGet", Payload: bytes.Repeat([]byte{0xa5}, 4099)},
	} {
		if got, want := envelopeText(value), legacyEnvelopeText(value); got != want {
			t.Fatalf("envelope text changed:\n got %q\nwant %q", got, want)
		}
		signed := makeEnvelope(token, value.SessionID, value.Sequence, value.RequestID, value.Operation, value.Payload)
		reference := value
		reference.Version = protocolVersion
		if want := sign(token, legacyEnvelopeText(reference)); signed.Proof != want {
			t.Fatalf("proof changed: got %s, want %s", signed.Proof, want)
		}
	}
}

type countingWriter struct {
	writes [][]byte
}

func (writer *countingWriter) Write(data []byte) (int, error) {
	writer.writes = append(writer.writes, append([]byte(nil), data...))
	return len(data), nil
}

func TestFrameIsWrittenOnceWithUnchangedBytes(t *testing.T) {
	value := makeEnvelope(bytes.Repeat([]byte{1}, 32), "session", 3, "request", "input", []byte(`{"success":true}`))
	var writer countingWriter
	if err := writeFrame(&writer, value); err != nil {
		t.Fatal(err)
	}
	if len(writer.writes) != 1 {
		t.Fatalf("frame used %d writes", len(writer.writes))
	}
	body, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(body)))
	if want := append(header[:], body...); !bytes.Equal(writer.writes[0], want) {
		t.Fatalf("frame bytes changed:\n got %q\nwant %q", writer.writes[0], want)
	}
	var decoded envelope
	if err := readFrame(bytes.NewReader(writer.writes[0]), &decoded); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(decoded, value) {
		t.Fatalf("decoded %#v", decoded)
	}
}

// BenchmarkInputEventWrite compares the descriptor writes of one request: the
// released one write(2) per event against one per report.
func BenchmarkInputEventWrite(b *testing.B) {
	events := inputPathCases["keyboard between pointer reports"]
	file, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		b.Fatal(err)
	}
	defer file.Close()
	b.Run("per-event", func(b *testing.B) {
		b.ReportAllocs()
		pointer := targetAbsolute
		for index := 0; index < b.N; index++ {
			start := 0
			for position, event := range events {
				if event.Type != 0 {
					continue
				}
				report := events[start : position+1]
				_, moves := inputReportTarget(report, pointer)
				if moves {
					pointer = targetAbsolute
				}
				for _, event := range report {
					data := make([]byte, 24)
					binary.LittleEndian.PutUint16(data[16:18], event.Type)
					binary.LittleEndian.PutUint16(data[18:20], event.Code)
					binary.LittleEndian.PutUint32(data[20:24], uint32(event.Value))
					if _, err := file.Write(data); err != nil {
						b.Fatal(err)
					}
				}
				start = position + 1
			}
			_ = legacyFormatInputReport(events)
		}
	})
	b.Run("per-report", func(b *testing.B) {
		b.ReportAllocs()
		pointer := targetAbsolute
		var scratch [maxInputEvents * inputEventBytes]byte
		var last []inputEvent
		device := func(inputTarget) io.Writer { return file }
		for index := 0; index < b.N; index++ {
			if err := writeInputReports(events, &pointer, device, scratch[:0]); err != nil {
				b.Fatal(err)
			}
			last = append(last[:0], events...)
		}
	})
}

func legacyFormatInputReport(events []inputEvent) string {
	parts := make([]string, 0, len(events))
	for _, event := range events {
		parts = append(parts, fmt.Sprintf("%d/%d/%d", event.Type, event.Code, event.Value))
	}
	return strings.Join(parts, " ")
}
