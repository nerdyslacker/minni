package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import config "../../src/config"
import daemon "../../src/daemon"
import ipc "../../src/ipc"
import storage "../../src/storage"
import x11 "../../src/x11"

keep_running := true

stop :: proc "c" (_: posix.Signal) {
	keep_running = false
}

usage :: proc() {
	fmt.eprintln("usage: minnid [--config PATH] [--state-dir PATH] [--cache-dir PATH] [--socket PATH] [--no-x11]")
}

help :: proc() {
	fmt.println(`minnid - X11 clipboard history daemon

Usage: minnid [options]
  --config PATH     configuration file
  --state-dir PATH  durable state override
  --cache-dir PATH  disposable preview cache override
  --socket PATH     IPC socket override
  --no-x11          run storage and IPC only
  --foreground      accepted for supervisor compatibility
  --help            show this help`)
}

owned_directory :: proc(path: string) -> bool {
	buffer: [108]byte
	if len(path) >= len(buffer) do return false
	copy(buffer[:], path)
	status: posix.stat_t
	return posix.lstat(cstring(&buffer[0]), &status) == .OK && status.st_uid == posix.geteuid()
}

main :: proc() {
	state_root, state_err := os.user_state_dir(context.allocator)
	if state_err != nil {
		fmt.eprintln("minnid: cannot resolve state directory")
		os.exit(1)
	}
	state_dir, _ := filepath.join({state_root, "minni"})
	delete(state_root)
	cache_root, cache_err := os.user_cache_dir(context.allocator)
	if cache_err != nil {
		fmt.eprintln("minnid: cannot resolve cache directory")
		os.exit(1)
	}
	cache_dir, _ := filepath.join({cache_root, "minni"})
	delete(cache_root)
	socket_path := ipc.default_socket_path()
	config_path, config_path_ok := config.default_path()
	if !config_path_ok {
		fmt.eprintln("minnid: cannot resolve configuration directory")
		os.exit(1)
	}
	config_explicit := false
	no_x11 := false
	for index := 1; index < len(os.args); index += 1 {
		switch os.args[index] {
		case "--help", "-h":
			help()
			os.exit(0)
		case "--config":
			if index + 1 >= len(os.args) {
				usage()
				os.exit(2)
			}
			index += 1
			delete(config_path)
			config_path = strings.clone(os.args[index])
			config_explicit = true
		case "--state-dir":
			if index + 1 >= len(os.args) {
				usage()
				os.exit(2)
			}
			index += 1
			delete(state_dir)
			state_dir = strings.clone(os.args[index])
		case "--cache-dir":
			if index + 1 >= len(os.args) {
				usage()
				os.exit(2)
			}
			index += 1
			delete(cache_dir)
			cache_dir = strings.clone(os.args[index])
		case "--socket":
			if index + 1 >= len(os.args) {
				usage()
				os.exit(2)
			}
			index += 1
			delete(socket_path)
			socket_path = strings.clone(os.args[index])
		case "--no-x11": no_x11 = true
		case "--foreground":
		case:
			usage()
			os.exit(2)
		}
	}
	defer delete(state_dir)
	defer delete(cache_dir)
	defer delete(socket_path)
	defer delete(config_path)
	settings, config_error := config.load(config_path, config_explicit)
	if len(config_error) > 0 {
		fmt.eprintln("minnid: ", config_error)
		delete(config_error)
		os.exit(1)
	}

	socket_dir, _ := os.split_path(socket_path)
	if len(socket_dir) == 0 || (!os.exists(socket_dir) && os.make_directory_all(socket_dir, os.perm(0o700)) != nil) {
		fmt.eprintln("minnid: cannot create private socket directory")
		os.exit(1)
	}
	directory_info, directory_err := os.lstat(socket_dir, context.temp_allocator)
	if directory_err != nil || directory_info.type != .Directory ||
	   directory_info.mode & os.perm(0o077) != {} || !owned_directory(socket_dir) {
		fmt.eprintln("minnid: socket directory must be private (0700)")
		os.exit(1)
	}
	store, open_err := storage.open(state_dir, settings.storage)
	if open_err != .None {
		fmt.eprintln("minnid: cannot open storage")
		os.exit(1)
	}
	state := daemon.State{
		store = store,
		listener = -1,
		socket_path = strings.clone(socket_path),
		cache_dir = strings.clone(cache_dir),
	}
	defer daemon.destroy(&state)
	state.sequence, open_err = storage.advance_event_sequence(store)
	if open_err != .None {
		fmt.eprintln("minnid: cannot initialize event sequence")
		os.exit(1)
	}
	if !no_x11 {
		state.backend_ready = x11.init(&state.backend, settings.x11)
		if !state.backend_ready {
			fmt.eprintln("minnid: X11 unavailable; history IPC remains active")
			x11.deinit(&state.backend)
		}
	}
	state.listener = ipc.listen(socket_path)
	if state.listener < 0 {
		fmt.eprintln("minnid: cannot listen on ", socket_path)
		os.exit(1)
	}
	_ = posix.signal(.SIGINT, stop)
	_ = posix.signal(.SIGTERM, stop)
	daemon.run(&state, &keep_running)
}
