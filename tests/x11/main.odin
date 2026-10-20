package main

import "core:fmt"
import "core:os"
import "core:time"
import clipboard "../../src/clipboard"
import storage "../../src/storage"
import x11 "../../src/x11"

fail :: proc(message: string) {
	fmt.eprintln(message)
	os.exit(1)
}

ready :: proc(path: string) {
	if err := os.write_entire_file(path, "ready"); err != nil do fail("cannot write ready file")
}

capture :: proc(output, ready_path: string, expected_mime := "") {
	backend: x11.Backend
	if !x11.init(&backend) do fail(backend.last_error)
	ready(ready_path)
	start := time.tick_now()
	for time.tick_since(start) < 15 * time.Second {
		x11.poll(&backend)
		item, ok := x11.take_capture(&backend)
		if ok {
			if len(expected_mime) > 0 && item.mime_type != expected_mime {
				x11.destroy_capture(&item)
				continue
			}
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

serve :: proc(input, ready_path: string, mime_type := "text/plain;charset=utf-8") {
	data, err := os.read_entire_file(input, context.allocator)
	if err != nil do fail("cannot read input")
	defer delete(data)
	backend: x11.Backend
	if !x11.init(&backend) do fail(backend.last_error)
	defer x11.deinit(&backend)
	if !x11.claim(&backend, .Clipboard, mime_type, data) do fail(backend.last_error)
	ready(ready_path)
	start := time.tick_now()
	for time.tick_since(start) < 15 * time.Second {
		x11.poll(&backend)
		time.sleep(2 * time.Millisecond)
	}
}

serve_stored_image :: proc(input, ready_path, mime_type: string) {
	data, err := os.read_entire_file(input, context.allocator)
	if err != nil do fail("cannot read image input")
	defer delete(data)
	root, root_err := os.make_directory_temp("/tmp", "minni-x11-store-*", context.allocator)
	if root_err != nil do fail("cannot create image store")
	defer { _ = os.remove_all(root); delete(root) }
	store, store_err := storage.open_default(root)
	if store_err != .None do fail("cannot open image store")
	defer storage.close(store)
	item, _, persist_err := clipboard.persist_capture(store, x11.Capture{mime_type = mime_type, data = data})
	if persist_err != .None do fail("cannot persist image")
	defer storage.destroy_item(&item)
	backend: x11.Backend
	if !x11.init(&backend) do fail(backend.last_error)
	defer x11.deinit(&backend)
	if clipboard.restore(&backend, store, item.id) != .None do fail("cannot restore stored image")
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
	if len(os.args) < 4 do fail("usage: x11-test capture|serve FILE READY")
	switch os.args[1] {
	case "capture":
		if len(os.args) != 4 do fail("usage: x11-test capture FILE READY")
		capture(os.args[2], os.args[3])
	case "capture-image":
		if len(os.args) != 5 do fail("usage: x11-test capture-image MIME FILE READY")
		capture(os.args[3], os.args[4], os.args[2])
	case "serve":
		if len(os.args) != 4 do fail("usage: x11-test serve FILE READY")
		serve(os.args[2], os.args[3])
	case "serve-image":
		if len(os.args) != 5 do fail("usage: x11-test serve-image MIME FILE READY")
		serve_stored_image(os.args[3], os.args[4], os.args[2])
	case "self":
		if len(os.args) != 4 do fail("usage: x11-test self FILE READY")
		self_capture(os.args[2], os.args[3])
	case: fail("unknown mode")
	}
}
