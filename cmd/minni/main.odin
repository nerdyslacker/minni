package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import ipc "../../src/ipc"

Error_Value :: struct {
	code: string `json:"code"`,
}

Envelope :: struct {
	ok:    bool        `json:"ok"`,
	seq:   i64         `json:"seq"`,
	error: Error_Value `json:"error"`,
}

usage :: proc() {
	fmt.eprintln("usage: minni [--socket PATH] [--json] status|list|search|show|copy|pin|unpin|remove|clear|pause|resume|watch")
}

send_request :: proc(fd: posix.FD, request: ipc.Request) -> ([]byte, bool) {
	payload, err := json.marshal(request, {spec = .JSON})
	if err != nil do return nil, false
	defer delete(payload)
	if !ipc.send_frame(fd, payload) do return nil, false
	return ipc.receive_frame(fd)
}

handshake :: proc(fd: posix.FD) -> bool {
	response, ok := send_request(fd, ipc.Request{
		v = ipc.VERSION,
		id = "0",
		op = "hello",
		args = {min_version = ipc.VERSION, max_version = ipc.VERSION},
	})
	if !ok do return false
	defer delete(response)
	envelope: Envelope
	defer delete(envelope.error.code)
	return json.unmarshal(response, &envelope, .JSON) == nil && envelope.ok
}

exit_for_response :: proc(response: []byte) -> int {
	envelope: Envelope
	defer delete(envelope.error.code)
	if json.unmarshal(response, &envelope, .JSON) != nil do return 1
	if envelope.ok do return 0
	switch envelope.error.code {
	case "NOT_FOUND": return 4
	case "CONFLICT", "LIMIT_EXCEEDED", "CURSOR_STALE": return 5
	}
	return 1
}

parse_common_options :: proc(arguments: []string, start: int, args: ^ipc.Args) -> bool {
	for index := start; index < len(arguments); index += 1 {
		switch arguments[index] {
		case "--pinned": args.pinned = true
		case "--limit":
			if index + 1 >= len(arguments) do return false
			index += 1
			value, ok := strconv.parse_int(arguments[index])
			if !ok do return false
			args.limit = value
		case "--cursor":
			if index + 1 >= len(arguments) do return false
			index += 1
			args.cursor = arguments[index]
		case: return false
		}
	}
	return true
}

watch :: proc(socket_path: string, json_output: bool) -> ! {
	last_sequence: i64
	for {
		fd := ipc.connect(socket_path)
		if fd < 0 {
			time.sleep(250 * time.Millisecond)
			continue
		}
		if !handshake(fd) {
			posix.close(fd)
			time.sleep(250 * time.Millisecond)
			continue
		}
		response, ok := send_request(fd, ipc.Request{
			v = ipc.VERSION,
			id = "1",
			op = "subscribe",
			args = {after_seq = last_sequence},
		})
		if ok do delete(response)
		if !ok {
			posix.close(fd)
			time.sleep(250 * time.Millisecond)
			continue
		}
		for {
			frame, received := ipc.receive_frame(fd)
			if !received do break
			envelope: Envelope
			if json.unmarshal(frame, &envelope, .JSON) == nil && envelope.seq > last_sequence {
				last_sequence = envelope.seq
			}
			delete(envelope.error.code)
			fmt.println(string(frame))
			delete(frame)
			_ = json_output
		}
		posix.close(fd)
		time.sleep(250 * time.Millisecond)
	}
}

main :: proc() {
	socket_path := ipc.default_socket_path()
	json_output := false
	arguments := os.args
	index := 1
	for index < len(arguments) {
		if arguments[index] == "--json" {
			json_output = true
			index += 1
			continue
		}
		if arguments[index] == "--socket" {
			if index + 1 >= len(arguments) {
				usage()
				os.exit(2)
			}
			delete(socket_path)
			socket_path = strings.clone(arguments[index + 1])
			index += 2
			continue
		}
		break
	}
	if index >= len(arguments) {
		usage()
		os.exit(2)
	}
	command := arguments[index]
	index += 1
	if command == "watch" {
		if index != len(arguments) {
			usage()
			os.exit(2)
		}
		watch(socket_path, json_output)
	}

	request := ipc.Request{v = ipc.VERSION, id = "1", op = command}
	valid := true
	switch command {
	case "status", "pause", "resume": valid = index == len(arguments)
	case "list": valid = parse_common_options(arguments, index, &request.args)
	case "search":
		if index >= len(arguments) {
			valid = false
		} else {
			request.args.query = arguments[index]
			valid = parse_common_options(arguments, index + 1, &request.args)
		}
	case "show", "pin", "unpin", "remove":
		valid = index + 1 == len(arguments)
		if valid do request.args.item_id = arguments[index]
	case "copy":
		valid = index < len(arguments)
		if valid {
			request.args.item_id = arguments[index]
			index += 1
			if index < len(arguments) {
				valid = index + 2 == len(arguments) && arguments[index] == "--selection"
				if valid do request.args.selection = arguments[index + 1]
			}
		}
	case "clear":
		valid = index + 1 == len(arguments)
		if valid {
			switch arguments[index] {
			case "--all": request.args.scope = "all"
			case "--unpinned": request.args.scope = "unpinned"
			case: valid = false
			}
		}
	case: valid = false
	}
	if !valid {
		usage()
		os.exit(2)
	}

	fd := ipc.connect(socket_path)
	if fd < 0 {
		fmt.eprintln("minni: daemon unavailable")
		os.exit(3)
	}
	if !handshake(fd) {
		fmt.eprintln("minni: protocol handshake failed")
		os.exit(1)
	}
	response, ok := send_request(fd, request)
	if !ok {
		fmt.eprintln("minni: connection closed")
		os.exit(3)
	}
	fmt.println(string(response))
	_ = json_output
	exit_code := exit_for_response(response)
	delete(response)
	posix.close(fd)
	delete(socket_path)
	os.exit(exit_code)
}
