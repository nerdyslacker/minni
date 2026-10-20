package main

import "core:fmt"
import "core:os"
import config "../../src/config"

failed := 0
passed := 0

expect :: proc(condition: bool, name: string) {
	if condition {
		passed += 1
	} else {
		failed += 1
		fmt.eprintln("FAIL: ", name)
	}
}

main :: proc() {
	path := "/tmp/minni-config-test.conf"
	defer os.remove(path)
	err := os.write_entire_file(path, string(`max_unpinned_items=7
max_text_bytes=512
max_image_bytes=1024
max_image_storage=2048
max_age_seconds=60
watch_primary=true
`))
	expect(err == nil, "write fixture")
	settings, message := config.load(path, true)
	expect(message == "", "valid configuration")
	delete(message)
	expect(settings.storage.max_unpinned_items == 7, "item limit")
	expect(settings.storage.max_text_bytes == 512 && settings.x11.max_text_bytes == 512, "text limit")
	expect(settings.storage.max_image_bytes == 1024 && settings.x11.max_image_bytes == 1024, "image limit")
	expect(settings.storage.max_image_storage == 2048, "storage limit")
	expect(settings.storage.max_age_seconds == 60, "age limit")
	expect(settings.x11.watch_primary, "primary setting")

	_ = os.write_entire_file(path, string("unknown=true\n"))
	_, message = config.load(path, true)
	expect(len(message) > 0, "unknown key rejected")
	delete(message)

	fmt.printf("Config: %d passed, %d failed\n", passed, failed)
	if failed > 0 do os.exit(1)
}
