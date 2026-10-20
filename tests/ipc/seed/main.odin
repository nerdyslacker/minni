package main

import "core:fmt"
import "core:os"
import storage "../../../src/storage"

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: seed STATE_DIR")
		os.exit(2)
	}
	store, err := storage.open_default(os.args[1])
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
}
