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

Export_Result :: struct {
	item_id:     string `json:"item_id"`,
	path:        string `json:"path"`,
	byte_length: i64    `json:"byte_length"`,
}

Export_Envelope :: struct {
	ok:     bool          `json:"ok"`,
	result: Export_Result `json:"result"`,
	error:  Error_Value   `json:"error"`,
}

Export_Report :: struct {
	item_id:     string `json:"item_id"`,
	output:      string `json:"output"`,
	byte_length: i64    `json:"byte_length"`,
}

usage :: proc() {
	fmt.eprintln("usage: minni [--socket PATH] [--json] COMMAND [ARGS]")
}

help :: proc() {
	fmt.println(`minni - control the minni clipboard daemon

Usage: minni [--socket PATH] [--json] COMMAND [ARGS]

Commands:
  capabilities
  status
  list [--limit N] [--cursor CURSOR] [--pinned]
  search QUERY [list options]
  show ID
  preview ID
  export ID --output PATH
  copy ID [--selection clipboard|primary]
  pin ID | unpin ID | remove ID
  clear --unpinned|--all
  pause | resume
  watch [--no-reconnect]

Exit codes: 0 success, 2 usage, 3 daemon unavailable,
4 not found, 5 limit or stale cursor, 1 other failure.`)
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

run_capabilities :: proc(socket_path: string) -> int {
	fd := ipc.connect(socket_path)
	if fd < 0 {
		fmt.eprintln("minni: daemon unavailable")
		return 3
	}
	defer posix.close(fd)
	response, ok := send_request(fd, ipc.Request{
		v = ipc.VERSION,
		id = "0",
		op = "hello",
		args = {min_version = ipc.VERSION, max_version = ipc.VERSION},
	})
	if !ok {
		fmt.eprintln("minni: connection closed")
		return 3
	}
	defer delete(response)
	fmt.println(string(response))
	return exit_for_response(response)
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

watch :: proc(socket_path: string, json_output, reconnect: bool) -> int {
	last_sequence: i64
	for {
		fd := ipc.connect(socket_path)
		if fd < 0 {
			if !reconnect do return 3
			time.sleep(250 * time.Millisecond)
			continue
		}
		if !handshake(fd) {
			posix.close(fd)
			if !reconnect do return 1
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
			if !reconnect do return 3
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
		if !reconnect do return 3
		time.sleep(250 * time.Millisecond)
	}
	return 0
}

run_export :: proc(socket_path, item_id, output: string, json_output: bool) -> int {
	fd := ipc.connect(socket_path)
	if fd < 0 {
		fmt.eprintln("minni: daemon unavailable")
		return 3
	}
	defer posix.close(fd)
	if !handshake(fd) {
		fmt.eprintln("minni: protocol handshake failed")
		return 1
	}
	response, ok := send_request(fd, ipc.Request{
		v = ipc.VERSION,
		id = "1",
		op = "export",
		args = {item_id = item_id},
	})
	if !ok {
		fmt.eprintln("minni: connection closed")
		return 3
	}
	defer delete(response)
	exit_code := exit_for_response(response)
	if exit_code != 0 {
		fmt.println(string(response))
		return exit_code
	}
	envelope: Export_Envelope
	defer {
		delete(envelope.result.item_id)
		delete(envelope.result.path)
		delete(envelope.error.code)
	}
	if json.unmarshal(response, &envelope, .JSON) != nil do return 1
	data, read_err := os.read_entire_file(envelope.result.path, context.allocator)
	if read_err != nil {
		fmt.eprintln("minni: cannot read exported payload")
		return 1
	}
	defer delete(data)
	file, open_err := os.open(output, {.Write, .Create, .Excl}, os.perm(0o600))
	if open_err != nil {
		fmt.eprintln("minni: output exists or cannot be created")
		return 1
	}
	complete := false
	defer {
		_ = os.close(file)
		if !complete do _ = os.remove(output)
	}
	written := 0
	for written < len(data) {
		count, write_err := os.write(file, data[written:])
		if write_err != nil || count <= 0 {
			fmt.eprintln("minni: cannot write output")
			return 1
		}
		written += count
	}
	if os.sync(file) != nil {
		fmt.eprintln("minni: cannot sync output")
		return 1
	}
	complete = true
	report := Export_Report{item_id = envelope.result.item_id, output = output, byte_length = i64(len(data))}
	if json_output {
		encoded, marshal_err := json.marshal(report, {spec = .JSON})
		if marshal_err != nil do return 1
		fmt.println(string(encoded))
		delete(encoded)
	}
	return 0
}

main :: proc() {
	socket_path := ipc.default_socket_path()
	json_output := false
	arguments := os.args
	index := 1
	for index < len(arguments) {
		if arguments[index] == "--help" || arguments[index] == "-h" {
			help()
			delete(socket_path)
			os.exit(0)
		}
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
	if command == "capabilities" {
		if index != len(arguments) {
			usage()
			os.exit(2)
		}
		exit_code := run_capabilities(socket_path)
		delete(socket_path)
		os.exit(exit_code)
	}
	if command == "export" {
		if index + 3 != len(arguments) || arguments[index + 1] != "--output" {
			usage()
			os.exit(2)
		}
		exit_code := run_export(socket_path, arguments[index], arguments[index + 2], json_output)
		delete(socket_path)
		os.exit(exit_code)
	}
	if command == "watch" {
		reconnect := true
		if index < len(arguments) && arguments[index] == "--no-reconnect" {
			reconnect = false
			index += 1
		}
		if index != len(arguments) {
			usage()
			os.exit(2)
		}
		exit_code := watch(socket_path, json_output, reconnect)
		delete(socket_path)
		os.exit(exit_code)
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
	case "show", "preview", "pin", "unpin", "remove":
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
