package x11

import "core:mem"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import media "../media"

set_error :: proc(backend: ^Backend, message: string) {
	delete(backend.last_error)
	backend.last_error = strings.clone(message)
}

check_request :: proc(backend: ^Backend, cookie: Cookie, message: string) -> bool {
	error := xcb_request_check(backend.connection, cookie)
	if error == nil do return true
	free_c(error)
	set_error(backend, message)
	return false
}

fail_init :: proc(backend: ^Backend, message: string) -> bool {
	deinit(backend)
	set_error(backend, message)
	return false
}

intern_atom :: proc(connection: ^Connection, name: string) -> (u32, bool) {
	error: ^Error
	reply := xcb_intern_atom_reply(
		connection,
		xcb_intern_atom(connection, 0, u16(len(name)), cstring(raw_data(name))),
		&error,
	)
	if error != nil do free_c(error)
	if reply == nil do return 0, false
	defer free_c(reply)
	return reply.atom, reply.atom != 0
}

init :: proc(backend: ^Backend, config := Config{}) -> bool {
	backend^ = {}
	backend.config = config
	if backend.config.max_text_bytes <= 0 do backend.config.max_text_bytes = default_config().max_text_bytes
	if backend.config.max_image_bytes <= 0 do backend.config.max_image_bytes = default_config().max_image_bytes
	if backend.config.max_pending_captures <= 0 do backend.config.max_pending_captures = default_config().max_pending_captures
	if backend.config.transfer_timeout <= 0 do backend.config.transfer_timeout = default_config().transfer_timeout
	if backend.config.incr_chunk_bytes <= 0 do backend.config.incr_chunk_bytes = default_config().incr_chunk_bytes

	screen_number: i32
	backend.connection = xcb_connect(nil, &screen_number)
	if backend.connection == nil || xcb_connection_has_error(backend.connection) != 0 {
		return fail_init(backend, "cannot connect to DISPLAY")
	}

	screens := xcb_setup_roots_iterator(xcb_get_setup(backend.connection))
	for _ in 0 ..< screen_number do xcb_screen_next(&screens)
	if screens.rem == 0 || screens.data == nil {
		return fail_init(backend, "X screen is unavailable")
	}
	backend.root = screens.data.root

	extension_name := "XFIXES"
	error: ^Error
	extension := xcb_query_extension_reply(
		backend.connection,
		xcb_query_extension(backend.connection, u16(len(extension_name)), cstring(raw_data(extension_name))),
		&error,
	)
	if error != nil do free_c(error)
	if extension == nil || extension.present == 0 {
		if extension != nil do free_c(extension)
		return fail_init(backend, "XFixes is unavailable")
	}
	backend.xfixes_event = extension.first_event
	free_c(extension)

	error = nil
	version := xcb_xfixes_query_version_reply(
		backend.connection, xcb_xfixes_query_version(backend.connection, 5, 0), &error,
	)
	if error != nil do free_c(error)
	if version == nil {
		return fail_init(backend, "XFixes version query failed")
	}
	free_c(version)

	names := [13]string{"CLIPBOARD", "TARGETS", "UTF8_STRING", "TEXT", "text/plain", "text/plain;charset=utf-8", "image/png", "image/jpeg", "text/uri-list", "INCR", "TIMESTAMP", "MINNI_SELECTION_A", "MINNI_SELECTION_B"}
	values := [13]^u32{&backend.atoms.clipboard, &backend.atoms.targets, &backend.atoms.utf8_string, &backend.atoms.text, &backend.atoms.text_plain, &backend.atoms.text_plain_utf8, &backend.atoms.image_png, &backend.atoms.image_jpeg, &backend.atoms.uri_list, &backend.atoms.incr, &backend.atoms.timestamp, &backend.atoms.property, &backend.atoms.property_alt}
	for name, index in names {
		atom, ok := intern_atom(backend.connection, name)
		if !ok {
			return fail_init(backend, "cannot intern required X atom")
		}
		values[index]^ = atom
	}

	backend.window = xcb_generate_id(backend.connection)
	event_mask := EVENT_MASK_PROPERTY_CHANGE
	if !check_request(backend, xcb_create_window_checked(
		backend.connection, u8(COPY_FROM_PARENT), backend.window, backend.root,
		0, 0, 1, 1, 0, WINDOW_CLASS_INPUT_OUTPUT, COPY_FROM_PARENT,
		CW_EVENT_MASK, &event_mask,
	), "cannot create clipboard window") {
		message := strings.clone(backend.last_error)
		deinit(backend)
		defer delete(message)
		return fail_init(backend, message)
	}

	if !watch_selection(backend, backend.atoms.clipboard) ||
	   (backend.config.watch_primary && !watch_selection(backend, ATOM_PRIMARY)) {
		message := strings.clone(backend.last_error)
		deinit(backend)
		defer delete(message)
		return fail_init(backend, message)
	}
	xcb_flush(backend.connection)

	inspect_owner(backend, .Clipboard)
	if backend.config.watch_primary do inspect_owner(backend, .Primary)
	return true
}

watch_selection :: proc(backend: ^Backend, selection: u32) -> bool {
	return check_request(backend, xcb_xfixes_select_selection_input_checked(
		backend.connection, backend.root, selection, XFIXES_SELECTION_MASK,
	), "cannot watch X selection")
}

deinit :: proc(backend: ^Backend) {
	cancel_receive(backend)
	for &capture in backend.captures do destroy_capture(&capture)
	delete(backend.captures)
	for &owned in backend.owned {
		delete(owned.mime_type)
		delete(owned.data)
	}
	for &send in backend.sends do delete(send.data)
	delete(backend.sends)
	if backend.connection != nil {
		if backend.window != 0 do _ = xcb_destroy_window_checked(backend.connection, backend.window)
		xcb_disconnect(backend.connection)
	}
	delete(backend.last_error)
	backend^ = {}
}

file_descriptor :: proc(backend: ^Backend) -> i32 {
	if backend == nil || backend.connection == nil do return -1
	return xcb_get_file_descriptor(backend.connection)
}

has_pending :: proc(backend: ^Backend) -> bool {
	return backend != nil && (backend.receive.phase != .Idle || len(backend.sends) > 0)
}

selection_atom :: proc(backend: ^Backend, selection: Selection) -> u32 {
	if selection == .Primary do return ATOM_PRIMARY
	return backend.atoms.clipboard
}

inspect_owner :: proc(backend: ^Backend, selection: Selection) {
	error: ^Error
	atom := selection_atom(backend, selection)
	reply := xcb_get_selection_owner_reply(backend.connection, xcb_get_selection_owner(backend.connection, atom), &error)
	if error != nil do free_c(error)
	if reply == nil do return
	owner := reply.owner
	free_c(reply)
	if owner != 0 && owner != backend.window do begin_receive(backend, selection, atom, owner, CURRENT_TIME)
}

begin_receive :: proc(backend: ^Backend, selection: Selection, selection_atom, owner, timestamp: u32) {
	cancel_receive(backend)
	backend.receive.phase = .Targets
	backend.receive.selection = selection
	backend.receive.selection_atom = selection_atom
	backend.receive.owner = owner
	backend.receive.started = time.tick_now()
	backend.receive_generation += 1
	backend.receive.property = backend.atoms.property
	if backend.receive_generation & 1 == 0 do backend.receive.property = backend.atoms.property_alt
	_ = xcb_delete_property_checked(backend.connection, backend.window, backend.receive.property)
	if !check_request(backend, xcb_convert_selection_checked(
		backend.connection, backend.window, selection_atom, backend.atoms.targets,
		backend.receive.property, timestamp,
	), "cannot request clipboard targets") {
		cancel_receive(backend)
	}
	xcb_flush(backend.connection)
}

cancel_receive :: proc(backend: ^Backend) {
	delete(backend.receive.data)
	backend.receive = {}
}

timed_out :: proc(start: time.Tick, limit: time.Duration) -> bool {
	return start != {} && time.tick_since(start) >= limit
}

tick :: proc(backend: ^Backend) {
	if backend.receive.phase != .Idle && timed_out(backend.receive.started, backend.config.transfer_timeout) {
		set_error(backend, "clipboard transfer timed out")
		cancel_receive(backend)
	}
	for index := len(backend.sends) - 1; index >= 0; index -= 1 {
		if timed_out(backend.sends[index].started, backend.config.transfer_timeout) {
			remove_send(backend, index)
		}
	}
}

poll :: proc(backend: ^Backend) -> int {
	if backend == nil || backend.connection == nil do return 0
	count := 0
	for {
		event := xcb_poll_for_event(backend.connection)
		if event == nil do break
		process_event(backend, event)
		free_c(event)
		count += 1
	}
	tick(backend)
	return count
}

process_event :: proc(backend: ^Backend, event: ^Generic_Event) {
	typ := event.response_type & 0x7f
	switch typ {
	case backend.xfixes_event:
		handle_owner_change(backend, cast(^XFixes_Selection_Notify_Event)event)
	case EVENT_SELECTION_NOTIFY:
		handle_selection_notify(backend, cast(^Selection_Notify_Event)event)
	case EVENT_PROPERTY_NOTIFY:
		handle_property_notify(backend, cast(^Property_Notify_Event)event)
	case EVENT_SELECTION_REQUEST:
		handle_selection_request(backend, cast(^Selection_Request_Event)event)
	case EVENT_SELECTION_CLEAR:
		handle_selection_clear(backend, cast(^Selection_Clear_Event)event)
	case EVENT_DESTROY_NOTIFY:
		handle_destroy_notify(backend, cast(^Destroy_Notify_Event)event)
	}
}

handle_owner_change :: proc(backend: ^Backend, event: ^XFixes_Selection_Notify_Event) {
	selection := Selection.Clipboard
	if event.selection == ATOM_PRIMARY do selection = .Primary
	if event.selection != backend.atoms.clipboard && event.selection != ATOM_PRIMARY do return
	if event.owner == backend.window {
		owned := find_owned(backend, event.selection)
		if owned != nil do owned.timestamp = event.selection_timestamp
		return
	}
	if backend.receive.selection_atom == event.selection {
		if event.owner == 0 do set_error(backend, "selection owner disappeared")
		cancel_receive(backend)
	}
	if event.owner != 0 do begin_receive(backend, selection, event.selection, event.owner, event.timestamp)
}

read_property :: proc(backend: ^Backend, delete_after: bool, max_bytes: int) -> (^Get_Property_Reply, []byte, bool) {
	error: ^Error
	reply := xcb_get_property_reply(
		backend.connection,
		xcb_get_property(backend.connection, u8(delete_after), backend.window, backend.receive.property, 0, 0, u32((max_bytes + 3) / 4)),
		&error,
	)
	if error != nil do free_c(error)
	if reply == nil do return nil, nil, false
	length := xcb_get_property_value_length(reply)
	if length < 0 || int(length) > max_bytes || reply.bytes_after != 0 {
		free_c(reply)
		return nil, nil, false
	}
	value := []byte{}
	if length > 0 {
		value = make([]byte, int(length))
		mem.copy(raw_data(value), xcb_get_property_value(reply), int(length))
	}
	return reply, value, true
}

choose_target :: proc(backend: ^Backend, data: []byte) -> u32 {
	if len(data) % 4 != 0 do return 0
	atoms := (cast([^]u32)raw_data(data))[:len(data) / 4]
	preferences := [8]u32{backend.atoms.image_png, backend.atoms.image_jpeg, backend.atoms.utf8_string, backend.atoms.text_plain_utf8, backend.atoms.text_plain, backend.atoms.text, ATOM_STRING, backend.atoms.uri_list}
	for preferred in preferences {
		for offered in atoms {
			if preferred != 0 && offered == preferred do return preferred
		}
	}
	return 0
}

target_is_image :: proc(backend: ^Backend, target: u32) -> bool {
	return target == backend.atoms.image_png || target == backend.atoms.image_jpeg
}

target_limit :: proc(backend: ^Backend, target: u32) -> int {
	if target_is_image(backend, target) do return backend.config.max_image_bytes
	return backend.config.max_text_bytes
}

handle_selection_notify :: proc(backend: ^Backend, event: ^Selection_Notify_Event) {
	if event.requestor != backend.window || event.selection != backend.receive.selection_atom do return
	if event.property != ATOM_NONE && event.property != backend.receive.property do return
	if backend.receive.phase == .Targets && event.target != backend.atoms.targets do return
	if backend.receive.phase == .Data && event.target != backend.receive.target do return
	if event.property == ATOM_NONE {
		set_error(backend, "selection conversion was rejected")
		cancel_receive(backend)
		return
	}

	#partial switch backend.receive.phase {
	case .Targets:
		reply, data, ok := read_property(backend, true, 64 * 1024)
		if !ok {
			set_error(backend, "invalid TARGETS response")
			cancel_receive(backend)
			return
		}
		target := u32(0)
		if reply.type == ATOM_ATOM && reply.format == 32 do target = choose_target(backend, data)
		free_c(reply)
		delete(data)
		if target == 0 {
			set_error(backend, "selection has no supported text target")
			cancel_receive(backend)
			return
		}
		backend.receive.phase = .Data
		backend.receive.target = target
		backend.receive.limit = target_limit(backend, target)
		backend.receive.started = time.tick_now()
		_ = xcb_convert_selection_checked(backend.connection, backend.window, event.selection, target, backend.receive.property, event.time)
		xcb_flush(backend.connection)
	case .Data:
		reply, data, ok := read_property(backend, false, backend.receive.limit)
		if !ok {
			set_error(backend, "selection payload exceeds its limit")
			cancel_receive(backend)
			return
		}
		if reply.type == backend.atoms.incr {
			valid := reply.format == 32 && len(data) == 4 && int((cast(^u32)raw_data(data))^) <= backend.receive.limit
			free_c(reply)
			delete(data)
			if !valid {
				set_error(backend, "invalid INCR announcement")
				cancel_receive(backend)
				return
			}
			backend.receive.phase = .Incremental
			backend.receive.started = time.tick_now()
			_ = xcb_delete_property_checked(backend.connection, backend.window, backend.receive.property)
			xcb_flush(backend.connection)
			return
		}
		actual_type, format := reply.type, reply.format
		free_c(reply)
		_ = xcb_delete_property_checked(backend.connection, backend.window, backend.receive.property)
		finish_capture(backend, actual_type, format, data)
	}
}

handle_property_notify :: proc(backend: ^Backend, event: ^Property_Notify_Event) {
	if event.window == backend.window && event.atom == backend.receive.property && event.state == PROPERTY_NEW_VALUE && backend.receive.phase == .Incremental {
		receive_increment(backend)
		return
	}
	if event.state != PROPERTY_DELETE do return
	for index := len(backend.sends) - 1; index >= 0; index -= 1 {
		if backend.sends[index].requestor == event.window && backend.sends[index].property == event.atom {
			send_increment(backend, index)
			return
		}
	}
}

receive_increment :: proc(backend: ^Backend) {
	reply, data, ok := read_property(backend, true, backend.receive.limit - len(backend.receive.data))
	if !ok {
		set_error(backend, "invalid INCR chunk")
		cancel_receive(backend)
		return
	}
	typ, format := reply.type, reply.format
	free_c(reply)
	if len(data) == 0 {
		delete(data)
		complete := make([]byte, len(backend.receive.data))
		copy(complete, backend.receive.data[:])
		finish_capture(backend, typ, format, complete)
		return
	}
	valid_type := typ == backend.receive.target
	if !target_is_image(backend, backend.receive.target) {
		valid_type = valid_type || typ == backend.atoms.utf8_string || typ == ATOM_STRING
	}
	if format != 8 || !valid_type || len(backend.receive.data) + len(data) > backend.receive.limit {
		delete(data)
		cancel_receive(backend)
		return
	}
	append(&backend.receive.data, ..data)
	delete(data)
	backend.receive.started = time.tick_now()
}

latin1_to_utf8 :: proc(data: []byte) -> []byte {
	result := make([dynamic]byte, 0, len(data) * 2)
	for value in data {
		if value < 0x80 {
			append(&result, value)
		} else {
			append(&result, 0xc0 | (value >> 6), 0x80 | (value & 0x3f))
		}
	}
	return result[:]
}

utf8_to_latin1 :: proc(data: []byte) -> ([]byte, bool) {
	if !utf8.valid_string(string(data)) do return nil, false
	result := make([dynamic]byte, 0, len(data))
	for value in string(data) {
		if value > 0xff {
			delete(result)
			return nil, false
		}
		append(&result, byte(value))
	}
	return result[:], true
}

finish_capture :: proc(backend: ^Backend, actual_type: u32, format: u8, data: []byte) {
	defer cancel_receive(backend)
	if format != 8 {
		set_error(backend, "selection did not use 8-bit data")
		delete(data)
		return
	}
	is_image := target_is_image(backend, backend.receive.target)
	if actual_type != backend.receive.target && (is_image || (actual_type != backend.atoms.utf8_string && actual_type != ATOM_STRING)) {
		set_error(backend, "selection returned an unexpected data type")
		delete(data)
		return
	}
	mime := "text/plain;charset=utf-8"
	converted := data
	if is_image {
		mime = "image/png" if backend.receive.target == backend.atoms.image_png else "image/jpeg"
		limits := media.default_limits()
		limits.max_bytes = backend.config.max_image_bytes
		if _, image_err := media.inspect(data, mime, limits); image_err != .None {
			set_error(backend, "clipboard image failed validation")
			delete(data)
			return
		}
	} else if backend.receive.target == backend.atoms.uri_list {
		mime = "text/uri-list"
		if !utf8.valid_string(string(data)) {
			set_error(backend, "URI selection is not valid UTF-8")
			delete(data)
			return
		}
	} else if actual_type == ATOM_STRING {
		converted = latin1_to_utf8(data)
		delete(data)
	} else if !utf8.valid_string(string(data)) {
		set_error(backend, "text selection is not valid UTF-8")
		delete(data)
		return
	}
	if len(converted) > backend.receive.limit {
		delete(converted)
		return
	}

	if len(backend.captures) > 0 {
		last := &backend.captures[len(backend.captures) - 1]
		if last.mime_type == mime && mem.compare(last.data, converted) == 0 {
			delete(converted)
			return
		}
	}
	if len(backend.captures) >= backend.config.max_pending_captures {
		destroy_capture(&backend.captures[0])
		ordered_remove(&backend.captures, 0)
	}
	append(&backend.captures, Capture{
		selection = backend.receive.selection,
		mime_type = strings.clone(mime),
		data = converted,
	})
}

take_capture :: proc(backend: ^Backend) -> (Capture, bool) {
	if len(backend.captures) == 0 do return {}, false
	result := backend.captures[0]
	ordered_remove(&backend.captures, 0)
	return result, true
}
