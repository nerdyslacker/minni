package daemon

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import clipboard "../clipboard"
import ipc "../ipc"
import media "../media"
import storage "../storage"
import x11 "../x11"

JOURNAL_LIMIT :: 256

valid_id :: proc(id: string) -> bool {
	if len(id) < 1 || len(id) > 64 do return false
	for character in id {
		if character < 0x21 || character > 0x7e do return false
	}
	return true
}

marshal_queue :: proc(client: ^ipc.Client, value: any) -> bool {
	payload, err := json.marshal(value, {spec = .JSON})
	if err != nil do return false
	defer delete(payload)
	return ipc.queue_frame(client, payload)
}

reply_ok :: proc(state: ^State, client: ^ipc.Client, id: string, result: $T) {
	_ = marshal_queue(client, Response(T){v = ipc.VERSION, id = id, ok = true, seq = state.sequence, result = result})
}

reply_error :: proc(state: ^State, client: ^ipc.Client, id, code, message: string) {
	problem := Protocol_Error{code = code, message = message}
	_ = marshal_queue(client, Error_Response{v = ipc.VERSION, id = id, ok = false, seq = state.sequence, error = problem})
}

storage_error :: proc(state: ^State, client: ^ipc.Client, id: string, err: storage.Error_Code) {
	#partial switch err {
	case .Not_Found: reply_error(state, client, id, "NOT_FOUND", "item does not exist")
	case .Invalid_Input: reply_error(state, client, id, "BAD_REQUEST", "invalid input")
	case .Limit_Exceeded: reply_error(state, client, id, "LIMIT_EXCEEDED", "storage limit exceeded")
	case: reply_error(state, client, id, "INTERNAL", "storage operation failed")
	}
}

emit :: proc(state: ^State, event_name: string, data: $T) {
	sequence, err := storage.advance_event_sequence(state.store)
	if err != .None do return
	state.sequence = sequence
	message := Event_Message(T){v = ipc.VERSION, event = event_name, seq = sequence, data = data}
	payload, marshal_err := json.marshal(message, {spec = .JSON})
	if marshal_err != nil do return
	if len(state.journal) >= JOURNAL_LIMIT {
		delete(state.journal[0].payload)
		ordered_remove(&state.journal, 0)
	}
	append(&state.journal, Journal_Event{seq = sequence, payload = payload})
	for client in state.clients {
		if client.subscribed && !ipc.queue_frame(client, payload) {
			_ = posix.shutdown(client.fd, .RDWR)
		}
	}
}

parse_cursor :: proc(cursor: string, sequence: i64) -> (int, bool) {
	if len(cursor) == 0 do return 0, true
	separator := strings.index_byte(cursor, ':')
	if separator <= 0 do return 0, false
	cursor_sequence, ok := strconv.parse_i64(cursor[:separator])
	if !ok || cursor_sequence != sequence do return 0, false
	offset, offset_ok := strconv.parse_int(cursor[separator + 1:])
	return offset, offset_ok && offset >= 0
}

matches_query :: proc(item: ^storage.Item, query: string) -> bool {
	if len(query) == 0 do return true
	return strings.contains(item.preview_text, query) || strings.contains(item.label, query) ||
	       strings.contains(item.mime_type, query) || strings.contains(item.source_app, query)
}

serve_list :: proc(state: ^State, client: ^ipc.Client, request: ^ipc.Request, search: bool) {
	limit := request.args.limit
	if limit == 0 do limit = 50
	if limit < 1 || limit > 200 {
		reply_error(state, client, request.id, "BAD_REQUEST", "limit must be between 1 and 200")
		return
	}
	offset, valid := parse_cursor(request.args.cursor, state.sequence)
	if !valid {
		reply_error(state, client, request.id, "CURSOR_STALE", "cursor does not match the current snapshot")
		return
	}
	items, err := storage.list(state.store, request.args.pinned)
	if err != .None {
		storage_error(state, client, request.id, err)
		return
	}
	defer storage.destroy_items(items)
	filtered := make([dynamic]Wire_Item)
	defer delete(filtered)
	skipped := 0
	more := false
	for &item in items {
		if search && !matches_query(&item, request.args.query) do continue
		if skipped < offset {
			skipped += 1
			continue
		}
		if len(filtered) >= limit {
			more = true
			break
		}
		append(&filtered, wire_item(&item))
	}
	next := ""
	if more do next = fmt.tprintf("%d:%d", state.sequence, offset + len(filtered))
	result := List_Result{items = filtered[:], next_cursor = next, snapshot_seq = state.sequence}
	reply_ok(state, client, request.id, result)
}

serve_request :: proc(state: ^State, client: ^ipc.Client, payload: []byte) -> bool {
	request: ipc.Request
	defer delete(request.id)
	defer delete(request.op)
	defer delete(request.args.item_id)
	defer delete(request.args.selection)
	defer delete(request.args.scope)
	defer delete(request.args.query)
	defer delete(request.args.cursor)
	if err := json.unmarshal(payload, &request, .JSON); err != nil do return false
	if !valid_id(request.id) do return false
	if !client.hello {
		if request.op != "hello" {
			reply_error(state, client, request.id, "BAD_REQUEST", "hello must be the first request")
			return true
		}
		if request.v != ipc.VERSION || request.args.min_version > ipc.VERSION || request.args.max_version < ipc.VERSION {
			reply_error(state, client, request.id, "UNSUPPORTED_VERSION", "protocol version is not supported")
			return true
		}
		client.hello = true
		capabilities := []string{"text", "image", "preview", "export", "watch"}
		if state.backend_ready do capabilities = []string{"x11", "text", "image", "preview", "export", "watch"}
		result := Hello_Result{version = ipc.VERSION, capabilities = capabilities}
		reply_ok(state, client, request.id, result)
		return true
	}
	if request.v != ipc.VERSION {
		reply_error(state, client, request.id, "UNSUPPORTED_VERSION", "protocol version is not supported")
		return true
	}

	switch request.op {
	case "status":
		items, err := storage.list(state.store)
		if err != .None {
			storage_error(state, client, request.id, err)
			return true
		}
		count: i64
		for item in items do count += item.byte_length
		result := Status_Result{backend = "unavailable", paused = state.paused, item_count = len(items), byte_count = count}
		if state.backend_ready do result.backend = "x11"
		reply_ok(state, client, request.id, result)
		storage.destroy_items(items)
	case "list": serve_list(state, client, &request, false)
	case "search": serve_list(state, client, &request, true)
	case "show":
		item, err := storage.get(state.store, request.args.item_id)
		if err != .None {
			storage_error(state, client, request.id, err)
			return true
		}
		wire := wire_item(&item)
		result := Item_Result{item = wire}
		reply_ok(state, client, request.id, result)
		storage.destroy_item(&item)
	case "preview":
		item, err := storage.get(state.store, request.args.item_id)
		if err != .None {
			storage_error(state, client, request.id, err)
			return true
		}
		is_image := item.kind == "image"
		storage.destroy_item(&item)
		if !is_image {
			reply_error(state, client, request.id, "BAD_REQUEST", "item is not an image")
			return true
		}
		preview, preview_err := clipboard.ensure_preview(state.store, request.args.item_id, state.cache_dir)
		if preview_err != .None {
			reply_error(state, client, request.id, "INTERNAL", "cannot create image preview")
			return true
		}
		result := Preview_Result{item_id = request.args.item_id, path = preview.path, width = preview.width, height = preview.height}
		reply_ok(state, client, request.id, result)
		media.destroy_preview(&preview)
	case "export":
		item, err := storage.get(state.store, request.args.item_id)
		if err != .None {
			storage_error(state, client, request.id, err)
			return true
		}
		path, path_err := storage.payload_path(state.store, request.args.item_id)
		if path_err != .None {
			storage.destroy_item(&item)
			storage_error(state, client, request.id, path_err)
			return true
		}
		result := Export_Result{item_id = item.id, path = path, mime_type = item.mime_type, byte_length = item.byte_length}
		reply_ok(state, client, request.id, result)
		delete(path)
		storage.destroy_item(&item)
	case "copy":
		if !state.backend_ready {
			reply_error(state, client, request.id, "BACKEND_UNAVAILABLE", "X11 backend is unavailable")
			return true
		}
		selection := x11.Selection.Clipboard
		if request.args.selection == "primary" do selection = .Primary
		if request.args.selection != "" && request.args.selection != "clipboard" && request.args.selection != "primary" {
			reply_error(state, client, request.id, "BAD_REQUEST", "invalid selection")
			return true
		}
		err := clipboard.restore(&state.backend, state.store, request.args.item_id, selection)
		if err != .None {
			if item, lookup := storage.get(state.store, request.args.item_id); lookup == .None {
				storage.destroy_item(&item)
				reply_error(state, client, request.id, "BACKEND_UNAVAILABLE", "clipboard restore failed")
			} else {
				storage_error(state, client, request.id, lookup)
			}
			return true
		}
		result := Item_Id_Result{item_id = request.args.item_id}
		reply_ok(state, client, request.id, result)
	case "pin", "unpin":
		item, err := storage.set_pinned(state.store, request.args.item_id, request.op == "pin")
		if err != .None {
			storage_error(state, client, request.id, err)
			return true
		}
		wire := wire_item(&item)
		emit(state, "item_updated", Item_Event_Data{item = wire})
		result := Item_Result{item = wire}
		reply_ok(state, client, request.id, result)
		storage.destroy_item(&item)
	case "remove":
		err := storage.remove(state.store, request.args.item_id)
		if err != .None {
			storage_error(state, client, request.id, err)
			return true
		}
		emit(state, "item_removed", Item_Id_Event_Data{item_id = request.args.item_id})
		result := Item_Id_Result{item_id = request.args.item_id, removed_count = 1}
		reply_ok(state, client, request.id, result)
	case "clear":
		scope := storage.Clear_Scope.Unpinned
		if request.args.scope == "all" do scope = .All
		if request.args.scope != "unpinned" && request.args.scope != "all" {
			reply_error(state, client, request.id, "BAD_REQUEST", "scope must be unpinned or all")
			return true
		}
		count, err := storage.clear(state.store, scope)
		if err != .None {
			storage_error(state, client, request.id, err)
			return true
		}
		if count > 0 do emit(state, "history_cleared", Count_Event_Data{removed_count = count})
		result := Count_Result{removed_count = count}
		reply_ok(state, client, request.id, result)
	case "pause", "resume":
		state.paused = request.op == "pause"
		emit(state, "capture_state", Capture_State_Event_Data{paused = state.paused})
		result := Capture_State_Result{paused = state.paused}
		reply_ok(state, client, request.id, result)
	case "subscribe":
		client.subscribed = true
		result := Subscribe_Result{subscribed = true, current_seq = state.sequence}
		reply_ok(state, client, request.id, result)
		if request.args.after_seq < state.sequence {
			first := state.sequence + 1
			if len(state.journal) > 0 do first = state.journal[0].seq
			if request.args.after_seq + 1 < first {
				message := Event_Message(Resync_Event_Data){v = ipc.VERSION, event = "resync_required", seq = state.sequence, data = {current_seq = state.sequence}}
				_ = marshal_queue(client, message)
			} else {
				for event in state.journal {
					if event.seq > request.args.after_seq do _ = ipc.queue_frame(client, event.payload)
				}
			}
		}
	case:
		reply_error(state, client, request.id, "BAD_REQUEST", "unknown operation")
	}
	return true
}

accept_clients :: proc(state: ^State) {
	for {
		fd := posix.accept(state.listener, nil, nil)
		if fd < 0 {
			if posix.errno() == .EINTR do continue
			return
		}
		if !ipc.same_user(fd) {
			posix.close(fd)
			continue
		}
		ipc.set_nonblocking(fd)
		client := new(ipc.Client)
		client.fd = fd
		append(&state.clients, client)
	}
}

drop_client :: proc(state: ^State, index: int) {
	client := state.clients[index]
	posix.close(client.fd)
	ipc.destroy_client(client)
	free(client)
	unordered_remove(&state.clients, index)
}

service_client :: proc(state: ^State, client: ^ipc.Client, readable, writable: bool) -> bool {
	if readable {
		if !ipc.read_available(client) do return false
		for {
			payload, ready, valid := ipc.next_frame(&client.reader)
			if !valid do return false
			if !ready do break
			ok := serve_request(state, client, payload)
			delete(payload)
			if !ok do return false
		}
	}
	if (writable || client.out_offset < len(client.out)) && !ipc.flush(client) do return false
	return true
}

capture_pending :: proc(state: ^State) {
	if !state.backend_ready do return
	_ = x11.poll(&state.backend)
	for {
		capture, ok := x11.take_capture(&state.backend)
		if !ok do break
		if !state.paused {
			item, result, err := clipboard.persist_capture(state.store, capture)
			if err == .None {
				wire := wire_item(&item)
				name := "item_added"
				if result == .Deduplicated do name = "item_updated"
				emit(state, name, Item_Event_Data{item = wire})
				storage.destroy_item(&item)
			}
		}
		x11.destroy_capture(&capture)
	}
}

run :: proc(state: ^State, running: ^bool) {
	for running^ {
		fds := make([dynamic]posix.pollfd, 0, len(state.clients) + 2)
		append(&fds, posix.pollfd{fd = state.listener, events = {.IN}})
		x_index := -1
		if state.backend_ready {
			x_index = len(fds)
			append(&fds, posix.pollfd{fd = posix.FD(x11.file_descriptor(&state.backend)), events = {.IN}})
		}
		clients := make([dynamic]^ipc.Client, 0, len(state.clients))
		for client in state.clients {
			events: posix.Poll_Event = {.IN}
			if client.out_offset < len(client.out) do events += {.OUT}
			append(&fds, posix.pollfd{fd = client.fd, events = events})
			append(&clients, client)
		}
		timeout := -1
		if state.backend_ready && x11.has_pending(&state.backend) do timeout = 100
		result := posix.poll(raw_data(fds), posix.nfds_t(len(fds)), i32(timeout))
		if result < 0 && posix.errno() != .EINTR {
			delete(fds)
			delete(clients)
			break
		}
		if .IN in fds[0].revents do accept_clients(state)
		if x_index >= 0 {
			x_events := fds[x_index].revents
			if .ERR in x_events || .HUP in x_events || .NVAL in x_events {
				x11.deinit(&state.backend)
				state.backend_ready = false
				running^ = false
			} else if result == 0 || .IN in x_events {
				capture_pending(state)
			}
		}
		base := 1
		if x_index >= 0 do base += 1
		for index := len(clients) - 1; index >= 0; index -= 1 {
			pollfd := fds[base + index]
			alive := !(.ERR in pollfd.revents || .HUP in pollfd.revents || .NVAL in pollfd.revents)
			if alive do alive = service_client(state, clients[index], .IN in pollfd.revents, .OUT in pollfd.revents)
			if !alive {
				for state_index in 0 ..< len(state.clients) {
					if state.clients[state_index] == clients[index] {
						drop_client(state, state_index)
						break
					}
				}
			}
		}
		delete(fds)
		delete(clients)
		capture_pending(state)
	}
}

destroy :: proc(state: ^State) {
	for len(state.clients) > 0 do drop_client(state, len(state.clients) - 1)
	delete(state.clients)
	for event in state.journal do delete(event.payload)
	delete(state.journal)
	if state.listener >= 0 do posix.close(state.listener)
	if len(state.socket_path) > 0 do _ = os.remove(state.socket_path)
	delete(state.socket_path)
	delete(state.cache_dir)
	if state.backend_ready do x11.deinit(&state.backend)
	storage.close(state.store)
	state^ = {}
}
