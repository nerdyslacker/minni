package clipboard

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

persist_capture :: proc(store: ^storage.Store, capture: x11.Capture) -> (storage.Item, storage.Put_Result, Error) {
	kind, ok := capture_kind(capture.mime_type)
	if !ok do return {}, {}, .Invalid
	if kind == "image" {
		limits := media.default_limits()
		limits.max_bytes = int(store.config.max_image_bytes)
		if _, image_err := media.inspect(capture.data, capture.mime_type, limits); image_err != .None {
			return {}, {}, .Invalid
		}
	}
	source := "clipboard"
	if capture.selection == .Primary do source = "primary"
	item, result, err := storage.put(store, {
		selection_source = source,
		mime_type = capture.mime_type,
		kind = kind,
		data = capture.data,
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
