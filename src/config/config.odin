package config

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import storage "../storage"
import x11 "../x11"

Settings :: struct {
	storage: storage.Config,
	x11:     x11.Config,
}

defaults :: proc() -> Settings {
	return {storage = storage.default_config(), x11 = x11.default_config()}
}

default_path :: proc() -> (string, bool) {
	root, err := os.user_config_dir(context.allocator)
	if err != nil do return "", false
	defer delete(root)
	path, join_err := filepath.join({root, "minni", "config"})
	return path, join_err == nil
}

parse_nonnegative :: proc(value: string) -> (i64, bool) {
	number, ok := strconv.parse_i64(value)
	return number, ok && number >= 0
}

load :: proc(path: string, required := false) -> (Settings, string) {
	settings := defaults()
	if !os.exists(path) {
		if required do return settings, fmt.aprintf("configuration does not exist: %s", path)
		return settings, ""
	}
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil do return settings, fmt.aprintf("cannot read configuration: %s", path)
	defer delete(data)
	text := string(data)
	line_number := 0
	for raw_line in strings.split_lines_iterator(&text) {
		line_number += 1
		line := strings.trim_space(raw_line)
		if len(line) == 0 || line[0] == '#' do continue
		separator := strings.index_byte(line, '=')
		if separator <= 0 {
			return settings, fmt.aprintf("invalid configuration line %d", line_number)
		}
		key := strings.trim_space(line[:separator])
		value := strings.trim_space(line[separator + 1:])
		switch key {
		case "max_unpinned_items":
			number, ok := strconv.parse_int(value)
			if !ok || number < -1 do return settings, fmt.aprintf("invalid %s on line %d", key, line_number)
			settings.storage.max_unpinned_items = number
		case "max_text_bytes":
			number, ok := parse_nonnegative(value)
			if !ok do return settings, fmt.aprintf("invalid %s on line %d", key, line_number)
			settings.storage.max_text_bytes = number
			settings.x11.max_text_bytes = int(number)
		case "max_image_bytes":
			number, ok := parse_nonnegative(value)
			if !ok do return settings, fmt.aprintf("invalid %s on line %d", key, line_number)
			settings.storage.max_image_bytes = number
			settings.x11.max_image_bytes = int(number)
		case "max_image_storage":
			number, ok := parse_nonnegative(value)
			if !ok do return settings, fmt.aprintf("invalid %s on line %d", key, line_number)
			settings.storage.max_image_storage = number
		case "max_age_seconds":
			number, ok := parse_nonnegative(value)
			if !ok do return settings, fmt.aprintf("invalid %s on line %d", key, line_number)
			settings.storage.max_age_seconds = number
		case "watch_primary":
			if value == "true" {
				settings.x11.watch_primary = true
			} else if value == "false" {
				settings.x11.watch_primary = false
			} else {
				return settings, fmt.aprintf("invalid %s on line %d", key, line_number)
			}
		case:
			return settings, fmt.aprintf("unknown configuration key on line %d: %s", line_number, key)
		}
	}
	return settings, ""
}
