package x11

import "core:mem"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

owned_index :: proc(selection: Selection) -> int {
	return int(selection)
}

claim :: proc(backend: ^Backend, selection: Selection, mime_type: string, data: []byte) -> bool {
	if backend == nil || backend.connection == nil || len(data) > backend.config.max_capture_bytes do return false
	if mime_type != "text/plain" && mime_type != "text/plain;charset=utf-8" do return false
	if !utf8.valid_string(string(data)) do return false

	index := owned_index(selection)
	owned := &backend.owned[index]
	delete(owned.mime_type)
	delete(owned.data)
	owned^ = {
		active = true,
		selection = selection,
		selection_atom = selection_atom(backend, selection),
		mime_type = strings.clone(mime_type),
		data = make([]byte, len(data)),
	}
	copy(owned.data, data)

	if !check_request(backend, xcb_set_selection_owner_checked(
		backend.connection, backend.window, owned.selection_atom, CURRENT_TIME,
	), "cannot claim X selection") {
		clear_owned(backend, index)
		return false
	}
	xcb_flush(backend.connection)

	error: ^Error
	reply := xcb_get_selection_owner_reply(backend.connection, xcb_get_selection_owner(backend.connection, owned.selection_atom), &error)
	if error != nil do free_c(error)
	if reply == nil || reply.owner != backend.window {
		if reply != nil do free_c(reply)
		clear_owned(backend, index)
		set_error(backend, "X selection ownership was rejected")
		return false
	}
	free_c(reply)
	return true
}

release :: proc(backend: ^Backend, selection: Selection) {
	index := owned_index(selection)
	if !backend.owned[index].active do return
	_ = xcb_set_selection_owner_checked(backend.connection, ATOM_NONE, backend.owned[index].selection_atom, CURRENT_TIME)
	clear_owned(backend, index)
	xcb_flush(backend.connection)
}

clear_owned :: proc(backend: ^Backend, index: int) {
	selection_atom := backend.owned[index].selection_atom
	delete(backend.owned[index].mime_type)
	delete(backend.owned[index].data)
	backend.owned[index] = {}
	for send_index := len(backend.sends) - 1; send_index >= 0; send_index -= 1 {
		if backend.sends[send_index].selection == selection_atom do remove_send(backend, send_index)
	}
}

handle_selection_clear :: proc(backend: ^Backend, event: ^Selection_Clear_Event) {
	for index in 0 ..< len(backend.owned) {
		if backend.owned[index].active && backend.owned[index].selection_atom == event.selection {
			clear_owned(backend, index)
			return
		}
	}
}

find_owned :: proc(backend: ^Backend, selection_atom: u32) -> ^Owned {
	for &owned in backend.owned {
		if owned.active && owned.selection_atom == selection_atom do return &owned
	}
	return nil
}

change_property :: proc(backend: ^Backend, window, property, typ: u32, format: u8, count: int, data: rawptr) -> bool {
	return check_request(backend, xcb_change_property_checked(
		backend.connection, PROP_MODE_REPLACE, window, property, typ, format, u32(count), data,
	), "cannot write selection property")
}

send_selection_notify :: proc(backend: ^Backend, request: ^Selection_Request_Event, property: u32) {
	buffer: [32]byte
	event := cast(^Selection_Notify_Event)&buffer
	event.response_type = EVENT_SELECTION_NOTIFY
	event.sequence = 0
	event.time = request.time
	event.requestor = request.requestor
	event.selection = request.selection
	event.target = request.target
	event.property = property
	_ = xcb_send_event_checked(backend.connection, 0, request.requestor, 0, &buffer)
	xcb_flush(backend.connection)
}

supported_targets :: proc(backend: ^Backend) -> [7]u32 {
	return {
		backend.atoms.targets,
		backend.atoms.timestamp,
		backend.atoms.utf8_string,
		backend.atoms.text,
		backend.atoms.text_plain_utf8,
		backend.atoms.text_plain,
		ATOM_STRING,
	}
}

target_data :: proc(backend: ^Backend, owned: ^Owned, target: u32) -> ([]byte, u32, bool, bool) {
	if target == ATOM_STRING {
		data, ok := utf8_to_latin1(owned.data)
		return data, ATOM_STRING, ok, true
	}
	if target == backend.atoms.utf8_string || target == backend.atoms.text || target == backend.atoms.text_plain || target == backend.atoms.text_plain_utf8 {
		return owned.data, backend.atoms.utf8_string, true, false
	}
	return nil, 0, false, false
}

direct_limit :: proc(backend: ^Backend) -> int {
	server_limit := int(xcb_get_maximum_request_length(backend.connection)) * 4 - 64
	if server_limit < 1024 do server_limit = 1024
	return min(server_limit, backend.config.incr_chunk_bytes)
}

handle_selection_request :: proc(backend: ^Backend, request: ^Selection_Request_Event) {
	owned := find_owned(backend, request.selection)
	if owned == nil {
		send_selection_notify(backend, request, ATOM_NONE)
		return
	}
	property := request.property
	if property == ATOM_NONE do property = request.target

	if request.target == backend.atoms.targets {
		targets := supported_targets(backend)
		if change_property(backend, request.requestor, property, ATOM_ATOM, 32, len(targets), raw_data(targets[:])) {
			send_selection_notify(backend, request, property)
		} else {
			send_selection_notify(backend, request, ATOM_NONE)
		}
		return
	}
	if request.target == backend.atoms.timestamp {
		timestamp := owned.timestamp
		if change_property(backend, request.requestor, property, ATOM_INTEGER, 32, 1, &timestamp) {
			send_selection_notify(backend, request, property)
		} else {
			send_selection_notify(backend, request, ATOM_NONE)
		}
		return
	}

	data, typ, ok, allocated := target_data(backend, owned, request.target)
	if allocated do defer delete(data)
	if !ok {
		send_selection_notify(backend, request, ATOM_NONE)
		return
	}
	if len(data) <= direct_limit(backend) {
		if change_property(backend, request.requestor, property, typ, 8, len(data), raw_data(data)) {
			send_selection_notify(backend, request, property)
		} else {
			send_selection_notify(backend, request, ATOM_NONE)
		}
		return
	}
	if len(backend.sends) >= 8 {
		send_selection_notify(backend, request, ATOM_NONE)
		return
	}
	for index := len(backend.sends) - 1; index >= 0; index -= 1 {
		if backend.sends[index].requestor == request.requestor && backend.sends[index].property == property do remove_send(backend, index)
	}

	events := EVENT_MASK_PROPERTY_CHANGE | EVENT_MASK_STRUCTURE_NOTIFY
	if !check_request(backend, xcb_change_window_attributes_checked(
		backend.connection, request.requestor, CW_EVENT_MASK, &events,
	), "cannot watch INCR requestor") {
		send_selection_notify(backend, request, ATOM_NONE)
		return
	}
	length := u32(len(data))
	if !change_property(backend, request.requestor, property, backend.atoms.incr, 32, 1, &length) {
		send_selection_notify(backend, request, ATOM_NONE)
		return
	}
	copy_data := make([]byte, len(data))
	copy(copy_data, data)
	append(&backend.sends, Send{
		requestor = request.requestor,
		property = property,
		target = typ,
		selection = request.selection,
		started = time.tick_now(),
		data = copy_data,
	})
	send_selection_notify(backend, request, property)
}

send_increment :: proc(backend: ^Backend, index: int) {
	if index < 0 || index >= len(backend.sends) do return
	send := &backend.sends[index]
	if send.sent_zero {
		remove_send(backend, index)
		return
	}
	remaining := len(send.data) - send.offset
	count := min(remaining, direct_limit(backend))
	data: rawptr
	if count > 0 do data = raw_data(send.data[send.offset:send.offset + count])
	if !change_property(backend, send.requestor, send.property, send.target, 8, count, data) {
		remove_send(backend, index)
		return
	}
	send.offset += count
	send.started = time.tick_now()
	if count == 0 do send.sent_zero = true
	xcb_flush(backend.connection)
}

remove_send :: proc(backend: ^Backend, index: int) {
	if index < 0 || index >= len(backend.sends) do return
	delete(backend.sends[index].data)
	unordered_remove(&backend.sends, index)
}

handle_destroy_notify :: proc(backend: ^Backend, event: ^Destroy_Notify_Event) {
	for index := len(backend.sends) - 1; index >= 0; index -= 1 {
		if backend.sends[index].requestor == event.window do remove_send(backend, index)
	}
}
