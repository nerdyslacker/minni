package main

import "core:fmt"
import "core:os"
import "core:strconv"
import storage "../../../src/storage"

main :: proc() {
	if len(os.args) < 2 || len(os.args) > 4 {
		fmt.eprintln("usage: seed STATE_DIR [MAX_ITEMS] [PNG]")
		os.exit(2)
	}
	config := storage.default_config()
	if len(os.args) == 3 {
		limit, ok := strconv.parse_int(os.args[2])
		if !ok || limit < 0 do os.exit(2)
		config.max_unpinned_items = limit
	}
	store, err := storage.open(os.args[1], config)
	if err != .None do os.exit(1)
	defer storage.close(store)
	values := [3]string{"alpha", "beta", "gamma"}
	for value in values {
		item, _, put_err := storage.put(store, {
			selection_source = "clipboard",
			mime_type = "text/plain;charset=utf-8",
			kind = "text",
			data = transmute([]byte)value,
		})
		if put_err != .None do os.exit(1)
		storage.destroy_item(&item)
	}
	if len(os.args) == 4 {
		data, read_err := os.read_entire_file(os.args[3], context.allocator)
		if read_err != nil do os.exit(1)
		defer delete(data)
		item, _, put_err := storage.put(store, {
			selection_source = "clipboard",
			mime_type = "image/png",
			kind = "image",
			data = data,
		})
		if put_err != .None do os.exit(1)
		storage.destroy_item(&item)
	}
}
