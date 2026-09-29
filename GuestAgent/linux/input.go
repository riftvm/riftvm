package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"syscall"
	"time"
)

const maxInputEvents = 64

type inputEvent struct {
	Type  uint16 `json:"type"`
	Code  uint16 `json:"code"`
	Value int32  `json:"value"`
}

type inputBatch struct {
	Events                    []inputEvent `json:"events"`
	TraceID                   string       `json:"traceID,omitempty"`
	HostSentAtUnixNanoseconds uint64       `json:"hostSentAtUnixNanoseconds,omitempty"`
}

type inputResult struct {
	Success                          bool   `json:"success"`
	Message                          string `json:"message"`
	TraceID                          string `json:"traceID,omitempty"`
	GuestReceivedAtUnixNanoseconds   uint64 `json:"guestReceivedAtUnixNanoseconds,omitempty"`
	UinputCompletedAtUnixNanoseconds uint64 `json:"uinputCompletedAtUnixNanoseconds,omitempty"`
}

type guestInput interface {
	Available() bool
	AbsolutePointerAvailable() bool
	Write([]inputEvent) error
	Close() error
}

func decodeInputBatch(payload []byte) ([]inputEvent, error) {
	_, events, err := parseInputBatch(payload)
	return events, err
}

// parseInputBatch decodes an input payload exactly once. The batch is returned
// even when validation fails: a rejected request still echoes its trace
// identity, as it did when the trace was decoded separately.
func parseInputBatch(payload []byte) (inputBatch, []inputEvent, error) {
	var batch inputBatch
	if err := json.Unmarshal(payload, &batch); err != nil {
		return batch, nil, errors.New("invalid input payload")
	}
	if err := validateInputEvents(batch.Events); err != nil {
		return batch, nil, err
	}
	return batch, batch.Events, nil
}

func validateInputEvents(events []inputEvent) error {
	if len(events) == 0 || len(events) > maxInputEvents {
		return errors.New("invalid input event count")
	}
	for index, event := range events {
		switch event.Type {
		case 0: // EV_SYN
			if event.Code != 0 || event.Value != 0 {
				return errors.New("invalid synchronization event")
			}
		case 1: // EV_KEY
			if event.Code > 767 || event.Value < 0 || event.Value > 2 {
				return errors.New("invalid key event")
			}
		case 2: // EV_REL
			if (event.Code != 0 && event.Code != 1 && event.Code != 6 && event.Code != 8) || event.Value < -32767 || event.Value > 32767 {
				return errors.New("invalid relative pointer event")
			}
		case 3: // EV_ABS
			if (event.Code != 0 && event.Code != 1) || event.Value < 0 || event.Value > 32767 {
				return errors.New("invalid absolute pointer event")
			}
		default:
			return errors.New("unsupported input event type")
		}
		if index == len(events)-1 && event.Type != 0 {
			return errors.New("input batch must end with SYN_REPORT")
		}
	}
	return nil
}

// inputTarget is the uinput device one synchronized report is written to.
type inputTarget int

const (
	targetKeyboard inputTarget = iota
	targetAbsolute
	targetRelative
)

// inputReportTarget picks the device for one SYN_REPORT-terminated report.
// Motion decides by its own type. A report of mouse buttons alone follows the
// pointer device that last carried motion, so a click lands on the device the
// compositor is actually reading: the tablet in absolute mode, the relative
// pointer while it is captured. moves reports whether the report is pointer
// motion, which is what updates that choice; a wheel report is not.
func inputReportTarget(report []inputEvent, lastPointer inputTarget) (target inputTarget, moves bool) {
	hasButton := false
	for _, event := range report {
		switch {
		case event.Type == 3:
			return targetAbsolute, true
		case event.Type == 2:
			moves = moves || event.Code == 0 || event.Code == 1
			target = targetRelative
		case event.Type == 1 && event.Code >= 272 && event.Code <= 274:
			hasButton = true
		}
	}
	if target == targetRelative {
		return targetRelative, moves
	}
	if hasButton {
		return lastPointer, false
	}
	return targetKeyboard, false
}

func handleInput(device guestInput, payload []byte) inputResult {
	result, _ := handleInputEvents(device, payload)
	return result
}

// handleInputEvents injects one input request and returns the events it
// delivered, so the session can track pressed keys without decoding again.
// The events are nil unless the request succeeded.
func handleInputEvents(device guestInput, payload []byte) (inputResult, []inputEvent) {
	receivedAt := uint64(time.Now().UnixNano())
	batch, events, err := parseInputBatch(payload)
	result := inputResult{
		TraceID:                        batch.TraceID,
		GuestReceivedAtUnixNanoseconds: receivedAt,
	}
	if device == nil || !device.Available() {
		result.Message = "uinput is unavailable"
		return result, nil
	}
	if err != nil {
		result.Message = err.Error()
		return result, nil
	}
	if err := device.Write(events); err != nil {
		result.Message = "could not inject input"
		return result, nil
	}
	result.Success = true
	result.UinputCompletedAtUnixNanoseconds = uint64(time.Now().UnixNano())
	return result, events
}

// inputEventBytes is sizeof(struct input_event) on 64-bit Linux: a 16-byte
// timeval, then type, code and value.
const inputEventBytes = 24

// appendInputEvents appends the kernel representation of events. A zero
// timestamp asks the input stack to timestamp the event itself.
func appendInputEvents(buffer []byte, events []inputEvent) []byte {
	for _, event := range events {
		var data [inputEventBytes]byte
		binary.LittleEndian.PutUint16(data[16:18], event.Type)
		binary.LittleEndian.PutUint16(data[18:20], event.Code)
		binary.LittleEndian.PutUint32(data[20:24], uint32(event.Value))
		buffer = append(buffer, data[:]...)
	}
	return buffer
}

// writeInputReports routes every SYN_REPORT-terminated report in events to its
// device and writes it with a single Write. uinput consumes several
// input_event structures from one write(2) in order, so the bytes each device
// receives, and the order of reports across devices, are exactly those of one
// write per event. device returns nil for a device that does not exist.
//
// The host may coalesce several independently synchronized reports into one
// request. Each report is still routed separately so a keyboard report
// adjacent to an absolute-pointer report never reaches the tablet device.
func writeInputReports(
	events []inputEvent,
	lastPointer *inputTarget,
	device func(inputTarget) io.Writer,
	scratch []byte,
) error {
	start := 0
	for index, event := range events {
		if event.Type != 0 {
			continue
		}
		report := events[start : index+1]
		target, moves := inputReportTarget(report, *lastPointer)
		writer := device(target)
		if writer == nil {
			return syscall.ENODEV
		}
		if moves {
			*lastPointer = target
		}
		scratch = appendInputEvents(scratch[:0], report)
		if _, err := writer.Write(scratch); err != nil {
			return err
		}
		start = index + 1
	}
	return nil
}

// formatInputReport renders events for diagnostics as "type/code/value" items.
func formatInputReport(events []inputEvent) string {
	buffer := make([]byte, 0, len(events)*12)
	for index, event := range events {
		if index > 0 {
			buffer = append(buffer, ' ')
		}
		buffer = strconv.AppendUint(buffer, uint64(event.Type), 10)
		buffer = append(buffer, '/')
		buffer = strconv.AppendUint(buffer, uint64(event.Code), 10)
		buffer = append(buffer, '/')
		buffer = strconv.AppendInt(buffer, int64(event.Value), 10)
	}
	return string(buffer)
}
