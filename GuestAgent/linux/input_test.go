package main

import (
	"encoding/json"
	"errors"
	"testing"
)

type recordingInput struct {
	available bool
	absolute  bool
	events    []inputEvent
	err       error
}

func (input *recordingInput) Available() bool                { return input.available }
func (input *recordingInput) AbsolutePointerAvailable() bool { return input.absolute }
func (input *recordingInput) Write(events []inputEvent) error {
	input.events = append(input.events, events...)
	return input.err
}
func (input *recordingInput) Close() error { return nil }

func inputPayload(t *testing.T, events ...inputEvent) []byte {
	t.Helper()
	payload, err := json.Marshal(inputBatch{Events: events})
	if err != nil {
		t.Fatal(err)
	}
	return payload
}

func TestInputBatchValidationAndDelivery(t *testing.T) {
	device := &recordingInput{available: true}
	result := handleInput(device, inputPayload(t,
		inputEvent{Type: 1, Code: 28, Value: 1},
		inputEvent{Type: 2, Code: 0, Value: -12},
		inputEvent{Type: 0, Code: 0, Value: 0},
	))
	if !result.Success || len(device.events) != 3 {
		t.Fatalf("unexpected result: %#v", result)
	}
	absolute := handleInput(device, inputPayload(t,
		inputEvent{Type: 3, Code: 0, Value: 32767},
		inputEvent{Type: 3, Code: 1, Value: 0},
		inputEvent{Type: 0, Code: 0, Value: 0},
	))
	if !absolute.Success {
		t.Fatalf("absolute input was rejected: %#v", absolute)
	}

	bad := handleInput(device, inputPayload(t, inputEvent{Type: 1, Code: 28, Value: 1}))
	if bad.Success {
		t.Fatal("accepted a batch without SYN_REPORT")
	}
	bad = handleInput(device, inputPayload(t,
		inputEvent{Type: 4, Code: 0, Value: 1}, inputEvent{Type: 0},
	))
	if bad.Success {
		t.Fatal("accepted an unsupported event type")
	}
	bad = handleInput(device, inputPayload(t,
		inputEvent{Type: 3, Code: 0, Value: 32768}, inputEvent{Type: 0},
	))
	if bad.Success {
		t.Fatal("accepted an out-of-range absolute coordinate")
	}
}

func TestInputReportsUnavailableAndWriteFailure(t *testing.T) {
	if handleInput(&recordingInput{}, inputPayload(t, inputEvent{Type: 0})).Success {
		t.Fatal("reported unavailable uinput as successful")
	}
	device := &recordingInput{available: true, err: errors.New("write")}
	if handleInput(device, inputPayload(t, inputEvent{Type: 0})).Success {
		t.Fatal("reported failed uinput write as successful")
	}
}

func TestInputTraceReportsGuestReceiveAndUinputCompletion(t *testing.T) {
	payload, err := json.Marshal(inputBatch{
		Events:                    []inputEvent{{Type: 1, Code: 30, Value: 1}, {Type: 0}},
		TraceID:                   "trace-1",
		HostSentAtUnixNanoseconds: 42,
	})
	if err != nil {
		t.Fatal(err)
	}
	result := handleInput(&recordingInput{available: true}, payload)
	if !result.Success || result.TraceID != "trace-1" {
		t.Fatalf("trace identity was not preserved: %#v", result)
	}
	if result.GuestReceivedAtUnixNanoseconds == 0 || result.UinputCompletedAtUnixNanoseconds == 0 {
		t.Fatalf("trace timestamps were not populated: %#v", result)
	}
	if result.UinputCompletedAtUnixNanoseconds < result.GuestReceivedAtUnixNanoseconds {
		t.Fatalf("uinput completion preceded receipt: %#v", result)
	}
}

func TestButtonsFollowThePointerDeviceThatLastMoved(t *testing.T) {
	syn := inputEvent{Type: 0}
	press := []inputEvent{{Type: 1, Code: 272, Value: 1}, syn}
	absolute := []inputEvent{{Type: 3, Code: 0, Value: 10}, {Type: 3, Code: 1, Value: 20}, syn}
	relative := []inputEvent{{Type: 2, Code: 0, Value: 3}, syn}
	wheel := []inputEvent{{Type: 2, Code: 8, Value: -1}, syn}
	key := []inputEvent{{Type: 1, Code: 30, Value: 1}, syn}

	cases := []struct {
		name        string
		report      []inputEvent
		lastPointer inputTarget
		target      inputTarget
		moves       bool
	}{
		{"absolute motion", absolute, targetRelative, targetAbsolute, true},
		{"relative motion", relative, targetAbsolute, targetRelative, true},
		{"click after absolute motion", press, targetAbsolute, targetAbsolute, false},
		// A captured pointer moves the relative device; its clicks must go
		// there too, not to a tablet the compositor is not reading.
		{"click after relative motion", press, targetRelative, targetRelative, false},
		{"wheel does not take the buttons", wheel, targetAbsolute, targetRelative, false},
		{"button before relative motion", []inputEvent{{Type: 1, Code: 272, Value: 1}, {Type: 2, Code: 1, Value: 2}, syn}, targetAbsolute, targetRelative, true},
		{"keyboard", key, targetAbsolute, targetKeyboard, false},
	}
	for _, c := range cases {
		target, moves := inputReportTarget(c.report, c.lastPointer)
		if target != c.target || moves != c.moves {
			t.Errorf("%s: got target %d moves %v, want %d %v", c.name, target, moves, c.target, c.moves)
		}
	}
}

func TestHorizontalWheelIsAcceptedInput(t *testing.T) {
	payload := []byte(`{"events":[{"type":2,"code":6,"value":1},{"type":0,"code":0,"value":0}]}`)
	if _, err := decodeInputBatch(payload); err != nil {
		t.Fatalf("horizontal wheel rejected: %v", err)
	}
}
