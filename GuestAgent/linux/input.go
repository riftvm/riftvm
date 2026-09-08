package main

import (
	"encoding/json"
	"errors"
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
	var batch inputBatch
	if err := json.Unmarshal(payload, &batch); err != nil {
		return nil, errors.New("invalid input payload")
	}
	if len(batch.Events) == 0 || len(batch.Events) > maxInputEvents {
		return nil, errors.New("invalid input event count")
	}
	for index, event := range batch.Events {
		switch event.Type {
		case 0: // EV_SYN
			if event.Code != 0 || event.Value != 0 {
				return nil, errors.New("invalid synchronization event")
			}
		case 1: // EV_KEY
			if event.Code > 767 || event.Value < 0 || event.Value > 2 {
				return nil, errors.New("invalid key event")
			}
		case 2: // EV_REL
			if (event.Code != 0 && event.Code != 1 && event.Code != 8) || event.Value < -32767 || event.Value > 32767 {
				return nil, errors.New("invalid relative pointer event")
			}
		case 3: // EV_ABS
			if (event.Code != 0 && event.Code != 1) || event.Value < 0 || event.Value > 32767 {
				return nil, errors.New("invalid absolute pointer event")
			}
		default:
			return nil, errors.New("unsupported input event type")
		}
		if index == len(batch.Events)-1 && event.Type != 0 {
			return nil, errors.New("input batch must end with SYN_REPORT")
		}
	}
	return batch.Events, nil
}

func handleInput(device guestInput, payload []byte) inputResult {
	receivedAt := uint64(time.Now().UnixNano())
	var traced inputBatch
	_ = json.Unmarshal(payload, &traced)
	result := inputResult{
		TraceID:                        traced.TraceID,
		GuestReceivedAtUnixNanoseconds: receivedAt,
	}
	if device == nil || !device.Available() {
		result.Message = "uinput is unavailable"
		return result
	}
	events, err := decodeInputBatch(payload)
	if err != nil {
		result.Message = err.Error()
		return result
	}
	if err := device.Write(events); err != nil {
		result.Message = "could not inject input"
		return result
	}
	result.Success = true
	result.UinputCompletedAtUnixNanoseconds = uint64(time.Now().UnixNano())
	return result
}
