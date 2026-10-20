package ipc

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

Peer_Credentials :: struct {
	pid: i32,
	uid: u32,
	gid: u32,
}

default_socket_path :: proc() -> string {
	buffer: [512]byte
	if value := os.get_env_buf(buffer[:], "MINNI_SOCKET"); value != "" {
		return strings.clone(value)
	}
	if value := os.get_env_buf(buffer[:], "XDG_RUNTIME_DIR"); value != "" {
		return fmt.aprintf("%s/minni/minni.sock", value)
	}
	return fmt.aprintf("/tmp/minni-%d/minni.sock", posix.geteuid())
}

socket_address :: proc(path: string) -> (posix.sockaddr_un, bool) {
	address: posix.sockaddr_un
	if len(path) == 0 || len(path) >= len(address.sun_path) do return {}, false
	address.sun_family = .UNIX
	for character, index in path do address.sun_path[index] = c.char(character)
	return address, true
}

connect :: proc(path: string) -> posix.FD {
	address, ok := socket_address(path)
	if !ok do return -1
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return -1
	if posix.connect(fd, (^posix.sockaddr)(&address), posix.socklen_t(size_of(address))) == .FAIL {
		posix.close(fd)
		return -1
	}
	_ = posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	return fd
}

listen :: proc(path: string) -> posix.FD {
	address, ok := socket_address(path)
	if !ok do return -1
	if os.exists(path) {
		info, stat_err := os.lstat(path, context.temp_allocator)
		if stat_err != nil || info.type != .Socket do return -1
		probe := connect(path)
		if probe >= 0 {
			posix.close(probe)
			return -1
		}
		if os.remove(path) != nil do return -1
	}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return -1
	if posix.bind(fd, (^posix.sockaddr)(&address), posix.socklen_t(size_of(address))) == .FAIL {
		fmt.eprintln("minni: socket bind failed: ", posix.errno())
		posix.close(fd)
		return -1
	}
	if posix.listen(fd, 16) == .FAIL {
		fmt.eprintln("minni: socket listen failed: ", posix.errno())
		posix.close(fd)
		return -1
	}
	_ = os.chmod(path, os.perm(0o600))
	set_nonblocking(fd)
	return fd
}

set_nonblocking :: proc(fd: posix.FD) {
	_ = posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	flags := posix.fcntl(fd, .GETFL)
	if flags >= 0 do _ = posix.fcntl(fd, .SETFL, flags | c.int(posix.O_NONBLOCK))
}

same_user :: proc(fd: posix.FD) -> bool {
	credentials: Peer_Credentials
	length := posix.socklen_t(size_of(credentials))
	result := posix.getsockopt(fd, posix.SOL_SOCKET, posix.Sock_Option(17), &credentials, &length)
	return result == .OK && length == posix.socklen_t(size_of(credentials)) && credentials.uid == u32(posix.geteuid())
}

read_available :: proc(client: ^Client) -> bool {
	buffer: [8192]byte
	for {
		count := posix.recv(client.fd, &buffer[0], c.size_t(len(buffer)), {})
		if count > 0 {
			if len(client.reader.data) + int(count) > MAX_FRAME + 4 do return false
			append(&client.reader.data, ..buffer[:int(count)])
			continue
		}
		if count == 0 do return false
		err := posix.errno()
		if err == .EINTR do continue
		return err == .EAGAIN
	}
}

next_frame :: proc(reader: ^Reader) -> (payload: []byte, ready, valid: bool) {
	if len(reader.data) < 4 do return nil, false, true
	count := int(u32(reader.data[0]) << 24 | u32(reader.data[1]) << 16 | u32(reader.data[2]) << 8 | u32(reader.data[3]))
	if count <= 0 || count > MAX_FRAME do return nil, false, false
	if len(reader.data) < count + 4 do return nil, false, true
	payload = make([]byte, count)
	copy(payload, reader.data[4:4 + count])
	remaining := len(reader.data) - count - 4
	copy(reader.data[:remaining], reader.data[4 + count:])
	resize(&reader.data, remaining)
	return payload, true, true
}

queue_frame :: proc(client: ^Client, payload: []byte) -> bool {
	if len(payload) == 0 || len(payload) > MAX_FRAME do return false
	if client.out_offset > 0 {
		remaining := len(client.out) - client.out_offset
		copy(client.out[:remaining], client.out[client.out_offset:])
		resize(&client.out, remaining)
		client.out_offset = 0
	}
	if len(client.out) + len(payload) + 4 > MAX_FRAME do return false
	count := u32(len(payload))
	append(&client.out, byte(count >> 24), byte(count >> 16), byte(count >> 8), byte(count))
	append(&client.out, ..payload)
	return true
}

flush :: proc(client: ^Client) -> bool {
	for client.out_offset < len(client.out) {
		pending := client.out[client.out_offset:]
		count := posix.send(client.fd, raw_data(pending), c.size_t(len(pending)), {.NOSIGNAL})
		if count > 0 {
			client.out_offset += int(count)
			continue
		}
		if count < 0 && posix.errno() == .EINTR do continue
		if count < 0 && posix.errno() == .EAGAIN do return true
		return false
	}
	resize(&client.out, 0)
	client.out_offset = 0
	return true
}

send_frame :: proc(fd: posix.FD, payload: []byte) -> bool {
	if len(payload) == 0 || len(payload) > MAX_FRAME do return false
	header := [4]byte{byte(len(payload) >> 24), byte(len(payload) >> 16), byte(len(payload) >> 8), byte(len(payload))}
	return send_all(fd, header[:]) && send_all(fd, payload)
}

send_all :: proc(fd: posix.FD, data: []byte) -> bool {
	offset: int = 0
	for offset < len(data) {
		count := posix.send(fd, raw_data(data[offset:]), c.size_t(int(len(data)) - offset), {.NOSIGNAL})
		if count > 0 {
			offset += int(count)
			continue
		}
		if count < 0 && posix.errno() == .EINTR do continue
		return false
	}
	return true
}

receive_frame :: proc(fd: posix.FD) -> ([]byte, bool) {
	header: [4]byte
	if !receive_exact(fd, header[:]) do return nil, false
	count := int(u32(header[0]) << 24 | u32(header[1]) << 16 | u32(header[2]) << 8 | u32(header[3]))
	if count <= 0 || count > MAX_FRAME do return nil, false
	payload := make([]byte, count)
	if !receive_exact(fd, payload) {
		delete(payload)
		return nil, false
	}
	return payload, true
}

receive_exact :: proc(fd: posix.FD, data: []byte) -> bool {
	offset: int = 0
	for offset < len(data) {
		count := posix.recv(fd, raw_data(data[offset:]), c.size_t(int(len(data)) - offset), {})
		if count > 0 {
			offset += int(count)
			continue
		}
		if count < 0 && posix.errno() == .EINTR do continue
		return false
	}
	return true
}
