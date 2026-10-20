package main

import "core:fmt"
import "core:os"
import "core:time"
import x11 "../../src/x11"

fail :: proc(message: string) {
	fmt.eprintln(message)
	os.exit(1)
}

ready :: proc(path: string) {
	if err := os.write_entire_file(path, "ready"); err != nil do fail("cannot write ready file")
}

capture :: proc(output, ready_path: string) {
	backend: x11.Backend
	if !x11.init(&backend) do fail(backend.last_error)
	ready(ready_path)
	start := time.tick_now()
	for time.tick_since(start) < 15 * time.Second {
		x11.poll(&backend)
		item, ok := x11.take_capture(&backend)
		if ok {
			err := os.write_entire_file(output, item.data)
			x11.destroy_capture(&item)
			x11.deinit(&backend)
			if err != nil do fail("cannot write capture")
			return
		}
		time.sleep(2 * time.Millisecond)
	}
	if len(backend.last_error) > 0 {
		fmt.eprintln("capture timed out:", backend.last_error)
	} else {
		fmt.eprintln("capture timed out")
	}
	x11.deinit(&backend)
	os.exit(1)
}

serve :: proc(input, ready_path: string) {
	data, err := os.read_entire_file(input, context.allocator)
	if err != nil do fail("cannot read input")
	defer delete(data)
	backend: x11.Backend
	if !x11.init(&backend) do fail(backend.last_error)
	defer x11.deinit(&backend)
	if !x11.claim(&backend, .Clipboard, "text/plain;charset=utf-8", data) do fail(backend.last_error)
	ready(ready_path)
	start := time.tick_now()
	for time.tick_since(start) < 15 * time.Second {
		x11.poll(&backend)
		time.sleep(2 * time.Millisecond)
	}
}

self_capture :: proc(input, ready_path: string) {
	data, err := os.read_entire_file(input, context.allocator)
	if err != nil do fail("cannot read input")
	defer delete(data)
	backend: x11.Backend
	if !x11.init(&backend) do fail(backend.last_error)
	defer x11.deinit(&backend)
	if !x11.claim(&backend, .Clipboard, "text/plain;charset=utf-8", data) do fail(backend.last_error)
	ready(ready_path)
	start := time.tick_now()
	for time.tick_since(start) < 500 * time.Millisecond {
		x11.poll(&backend)
		item, ok := x11.take_capture(&backend)
		if ok {
			x11.destroy_capture(&item)
			fail("backend captured its own selection")
			return
		}
		time.sleep(2 * time.Millisecond)
	}
}

main :: proc() {
	if len(os.args) != 4 do fail("usage: x11-test capture|serve FILE READY")
	switch os.args[1] {
	case "capture": capture(os.args[2], os.args[3])
	case "serve": serve(os.args[2], os.args[3])
	case "self": self_capture(os.args[2], os.args[3])
	case: fail("unknown mode")
	}
}
