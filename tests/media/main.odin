package main

import "core:fmt"
import "core:os"
import "core:strings"
import clipboard "../../src/clipboard"
import media "../../src/media"
import storage "../../src/storage"
import x11 "../../src/x11"
import stbi "vendor:stb/image"

passes, failures: int

ok :: proc(condition: bool, message: string) {
	if condition {
		passes += 1
	} else {
		failures += 1
		fmt.eprintln("FAIL:", message)
	}
}

write_fixture :: proc(path, mime_type: string, width, height: int) -> bool {
	pixels := make([]byte, width * height * 4)
	defer delete(pixels)
	for y in 0 ..< height {
		for x in 0 ..< width {
			offset := (y * width + x) * 4
			pixels[offset] = byte(x * 255 / max(1, width - 1))
			pixels[offset + 1] = byte(y * 255 / max(1, height - 1))
			pixels[offset + 2] = byte((x + y) & 0xff)
			pixels[offset + 3] = 0xff
		}
	}
	cpath, path_err := strings.clone_to_cstring(path, context.temp_allocator)
	if path_err != nil do return false
	if mime_type == "image/png" {
		return stbi.write_png(cpath, i32(width), i32(height), 4, raw_data(pixels), i32(width * 4)) != 0
	}
	return stbi.write_jpg(cpath, i32(width), i32(height), 4, raw_data(pixels), 90) != 0
}

main :: proc() {
	root, root_err := os.make_directory_temp("/tmp", "minni-media-*", context.allocator)
	if root_err != nil {
		fmt.eprintln("cannot create media test directory")
		os.exit(1)
	}
	defer { _ = os.remove_all(root); delete(root) }
	png_path := fmt.aprintf("%s/input.png", root)
	jpeg_path := fmt.aprintf("%s/input image.jpg", root)
	defer { delete(png_path); delete(jpeg_path) }
	ok(write_fixture(png_path, "image/png", 96, 48), "create PNG fixture")
	ok(write_fixture(jpeg_path, "image/jpeg", 80, 40), "create JPEG fixture")
	png, png_err := os.read_entire_file(png_path, context.allocator)
	jpeg, jpeg_err := os.read_entire_file(jpeg_path, context.allocator)
	defer { delete(png); delete(jpeg) }
	ok(png_err == nil && jpeg_err == nil, "read image fixtures")

	png_info, err := media.inspect(png, "image/png")
	ok(err == .None && png_info.width == 96 && png_info.height == 48, "validate PNG dimensions")
	jpeg_info: media.Info
	jpeg_info, err = media.inspect(jpeg, "image/jpeg")
	ok(err == .None && jpeg_info.width == 80 && jpeg_info.height == 40, "validate JPEG dimensions")
	_, err = media.inspect(png, "image/jpeg")
	ok(err == .Invalid, "reject MIME mismatch")
	_, err = media.inspect(png[:len(png) / 2], "image/png")
	ok(err == .Invalid, "reject truncated PNG")
	limits := media.default_limits()
	limits.max_dimension = 64
	_, err = media.inspect(png, "image/png", limits)
	ok(err == .Limit_Exceeded, "reject excessive dimensions")

	cache_path := fmt.aprintf("%s/cache", root)
	defer delete(cache_path)
	key := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	limits = media.default_limits()
	limits.thumbnail_edge = 32
	preview, preview_err := media.ensure_thumbnail(cache_path, key, png, "image/png", limits)
	ok(preview_err == .None && preview.width == 32 && preview.height == 16 && os.exists(preview.path), "create bounded thumbnail")
	media.destroy_preview(&preview)
	_, preview_err = media.ensure_thumbnail(cache_path, "../escape", png, "image/png", limits)
	ok(preview_err == .Invalid, "reject unsafe preview key")

	state_path := fmt.aprintf("%s/state", root)
	defer delete(state_path)
	store, store_err := storage.open_default(state_path)
	ok(store_err == .None, "open image store")
	if store_err == .None {
		capture := x11.Capture{mime_type = "image/png", data = png}
		item, result, persist_err := clipboard.persist_capture(store, capture)
		ok(persist_err == .None && result == .Inserted && item.kind == "image", "persist captured image")
		expected_ref := fmt.tprintf("%s.png", item.content_hash[len("sha256:"):])
		ok(item.thumbnail_ref == expected_ref, "persist deterministic preview reference")
		stored_preview, ensure_err := clipboard.ensure_preview(store, item.id, cache_path, limits)
		ok(ensure_err == .None && os.exists(stored_preview.path), "generate stored image preview")
		media.destroy_preview(&stored_preview)
		storage.destroy_item(&item)

		jpeg_uri := fmt.aprintf("file://%s/input%%20image.jpg\r\n", root)
		defer delete(jpeg_uri)
		uri_item, _, uri_err := clipboard.persist_capture(store, x11.Capture{
			mime_type = "text/uri-list",
			data = transmute([]byte)jpeg_uri,
		})
		ok(uri_err == .None && uri_item.kind == "image" &&
			uri_item.mime_type == "image/jpeg", "import copied image file")
		storage.destroy_item(&uri_item)

		path_item, _, path_err := clipboard.persist_capture(store, x11.Capture{
			selection = .Clipboard,
			mime_type = "text/plain;charset=utf-8",
			data = transmute([]byte)png_path,
		})
		ok(path_err == .None && path_item.kind == "image" &&
			path_item.mime_type == "image/png", "import copied image path")
		storage.destroy_item(&path_item)

		text_uri := fmt.aprintf("file://%s/input%%20image.jpg", root)
		defer delete(text_uri)
		text_uri_item, _, text_uri_err := clipboard.persist_capture(store, x11.Capture{
			selection = .Clipboard,
			mime_type = "text/plain;charset=utf-8",
			data = transmute([]byte)text_uri,
		})
		ok(text_uri_err == .None && text_uri_item.kind == "image" &&
			text_uri_item.mime_type == "image/jpeg", "import copied image text URI")
		storage.destroy_item(&text_uri_item)
		storage.close(store)
	}

	fmt.printf("Media: %d passed, %d failed\n", passes, failures)
	if failures != 0 do os.exit(1)
}
