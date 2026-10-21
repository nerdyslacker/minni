package clipboard

import "core:net"
import "core:os"
import "core:strings"
import media "../media"
import storage "../storage"
import x11 "../x11"

Error :: enum {
	None,
	Invalid,
	Storage,
	Clipboard,
	Preview,
}

capture_kind :: proc(mime_type: string) -> (string, bool) {
	switch mime_type {
	case "image/png", "image/jpeg": return "image", true
	case "text/uri-list": return "uri_list", true
	case "text/plain", "text/plain;charset=utf-8": return "text", true
	}
	return "", false
}

load_local_image :: proc(path: string, max_bytes: i64) -> ([]byte, string, bool) {
	if len(path) == 0 || path[0] != '/' || strings.index_byte(path, 0) >= 0 {
		return nil, "", false
	}

	file, open_err := os.open(path)
	if open_err != nil do return nil, "", false
	defer os.close(file)
	info, stat_err := os.fstat(file, context.temp_allocator)
	if stat_err != nil || info.type != .Regular || info.size <= 0 ||
	   (max_bytes > 0 && info.size > max_bytes) {
		return nil, "", false
	}
	contents := make([]byte, int(info.size))
	count, read_err := os.read_full(file, contents)
	if read_err != nil || count != len(contents) {
		delete(contents)
		return nil, "", false
	}
	mime_type := ""
	if media.signature_matches(contents, "image/png") {
		mime_type = "image/png"
	} else if media.signature_matches(contents, "image/jpeg") {
		mime_type = "image/jpeg"
	} else {
		delete(contents)
		return nil, "", false
	}
	return contents, mime_type, true
}

local_image_from_uri_list :: proc(data: []byte, max_bytes: i64) -> ([]byte, string, bool) {
	text := string(data)
	uri := ""
	for raw_line in strings.split_lines_iterator(&text) {
		line := strings.trim_space(raw_line)
		if len(line) == 0 || line[0] == '#' do continue
		if uri != "" do return nil, "", false
		uri = line
	}
	if uri == "" do return nil, "", false

	encoded_path := ""
	if strings.has_prefix(uri, "file://localhost/") {
		encoded_path = uri[len("file://localhost"):]
	} else if strings.has_prefix(uri, "file:///") {
		encoded_path = uri[len("file://"):]
	} else {
		return nil, "", false
	}
	path, decoded := net.percent_decode(encoded_path)
	if !decoded do return nil, "", false
	defer delete(path)
	return load_local_image(path, max_bytes)
}

local_image_from_text :: proc(data: []byte, max_bytes: i64) -> ([]byte, string, bool) {
	path := strings.trim_space(string(data))
	if strings.index_byte(path, '\n') >= 0 || strings.index_byte(path, '\r') >= 0 {
		return nil, "", false
	}
	if strings.has_prefix(path, "file://") {
		return local_image_from_uri_list(data, max_bytes)
	}
	return load_local_image(path, max_bytes)
}

persist_capture :: proc(store: ^storage.Store, capture: x11.Capture) -> (storage.Item, storage.Put_Result, Error) {
	kind, ok := capture_kind(capture.mime_type)
	if !ok do return {}, {}, .Invalid
	mime_type := capture.mime_type
	data := capture.data
	local_image: []byte
	if kind == "uri_list" {
		image_data, image_mime, image_ok := local_image_from_uri_list(
			capture.data, store.config.max_image_bytes,
		)
		if image_ok {
			local_image = image_data
			data = local_image
			mime_type = image_mime
			kind = "image"
		}
	} else if kind == "text" && capture.selection == .Clipboard {
		image_data, image_mime, image_ok := local_image_from_text(
			capture.data, store.config.max_image_bytes,
		)
		if image_ok {
			local_image = image_data
			data = local_image
			mime_type = image_mime
			kind = "image"
		}
	}
	defer delete(local_image)
	if kind == "image" {
		limits := media.default_limits()
		limits.max_bytes = int(store.config.max_image_bytes)
		if _, image_err := media.inspect(data, mime_type, limits); image_err != .None {
			return {}, {}, .Invalid
		}
	}
	source := "clipboard"
	if capture.selection == .Primary do source = "primary"
	item, result, err := storage.put(store, {
		selection_source = source,
		mime_type = mime_type,
		kind = kind,
		data = data,
	})
	if err != .None do return {}, {}, .Storage
	return item, result, .None
}

restore :: proc(backend: ^x11.Backend, store: ^storage.Store, id: string, selection := x11.Selection.Clipboard) -> Error {
	item, err := storage.get(store, id)
	if err != .None do return .Storage
	defer storage.destroy_item(&item)
	data, read_err := storage.read_payload(store, id)
	if read_err != .None do return .Storage
	defer delete(data)
	if !x11.claim(backend, selection, item.mime_type, data) do return .Clipboard
	return .None
}

ensure_preview :: proc(store: ^storage.Store, id, cache_dir: string, limits := media.Limits{}) -> (media.Preview, Error) {
	item, err := storage.get(store, id)
	if err != .None do return {}, .Storage
	defer storage.destroy_item(&item)
	if item.kind != "image" || len(item.content_hash) != len("sha256:") + 64 do return {}, .Invalid
	data, read_err := storage.read_payload(store, id)
	if read_err != .None do return {}, .Storage
	defer delete(data)
	preview, preview_err := media.ensure_thumbnail(cache_dir, item.content_hash[len("sha256:"):], data, item.mime_type, limits)
	if preview_err != .None do return {}, .Preview
	return preview, .None
}
