package x11

import "core:time"

Selection :: enum { Clipboard, Primary }

Config :: struct {
	max_capture_bytes: int,
	max_pending_captures: int,
	transfer_timeout:  time.Duration,
	incr_chunk_bytes:  int,
	watch_primary:     bool,
}

default_config :: proc() -> Config {
	return {
		max_capture_bytes = 20 * 1024 * 1024,
		max_pending_captures = 32,
		transfer_timeout = 5 * time.Second,
		incr_chunk_bytes = 64 * 1024,
	}
}

Capture :: struct {
	selection: Selection,
	mime_type: string,
	data:      []byte,
}

destroy_capture :: proc(capture: ^Capture) {
	if capture == nil do return
	delete(capture.mime_type)
	delete(capture.data)
	capture^ = {}
}

Atoms :: struct {
	clipboard, targets, utf8_string, text, text_plain, text_plain_utf8: u32,
	incr, timestamp, property, property_alt: u32,
}

Receive_Phase :: enum { Idle, Targets, Data, Incremental }

Receive :: struct {
	phase: Receive_Phase,
	selection: Selection,
	selection_atom, owner, target: u32,
	property: u32,
	started: time.Tick,
	data: [dynamic]byte,
}

Owned :: struct {
	active: bool,
	selection: Selection,
	selection_atom: u32,
	mime_type: string,
	data: []byte,
	timestamp: u32,
}

Send :: struct {
	requestor, property, target, selection: u32,
	offset: int,
	sent_zero: bool,
	started: time.Tick,
	data: []byte,
}

Backend :: struct {
	connection: ^Connection,
	window, root: u32,
	xfixes_event: u8,
	atoms: Atoms,
	config: Config,
	receive: Receive,
	owned: [2]Owned,
	sends: [dynamic]Send,
	captures: [dynamic]Capture,
	last_error: string,
	receive_generation: u32,
}
