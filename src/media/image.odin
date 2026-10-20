package media

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import stbi "vendor:stb/image"

Error :: enum {
	None,
	Unsupported,
	Invalid,
	Limit_Exceeded,
	IO,
}

Limits :: struct {
	max_bytes:     int,
	max_dimension: int,
	max_pixels:    i64,
	thumbnail_edge: int,
}

default_limits :: proc() -> Limits {
	return {
		max_bytes = 20 * 1024 * 1024,
		max_dimension = 8192,
		max_pixels = 16 * 1024 * 1024,
		thumbnail_edge = 256,
	}
}

Info :: struct {
	mime_type: string,
	width, height, channels: int,
}

Preview :: struct {
	ref, path: string,
	width, height: int,
}

destroy_preview :: proc(preview: ^Preview) {
	if preview == nil do return
	delete(preview.ref)
	delete(preview.path)
	preview^ = {}
}

supported_mime :: proc(mime_type: string) -> bool {
	return mime_type == "image/png" || mime_type == "image/jpeg"
}

signature_matches :: proc(data: []byte, mime_type: string) -> bool {
	if mime_type == "image/png" {
		return len(data) >= 8 && data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G' &&
			data[4] == 0x0d && data[5] == 0x0a && data[6] == 0x1a && data[7] == 0x0a
	}
	if mime_type == "image/jpeg" {
		return len(data) >= 4 && data[0] == 0xff && data[1] == 0xd8 && data[len(data) - 2] == 0xff && data[len(data) - 1] == 0xd9
	}
	return false
}

normalized_limits :: proc(limits: Limits) -> Limits {
	defaults := default_limits()
	result := limits
	if result.max_bytes <= 0 do result.max_bytes = defaults.max_bytes
	if result.max_dimension <= 0 do result.max_dimension = defaults.max_dimension
	if result.max_pixels <= 0 do result.max_pixels = defaults.max_pixels
	if result.thumbnail_edge <= 0 do result.thumbnail_edge = defaults.thumbnail_edge
	return result
}

probe :: proc(data: []byte, mime_type: string, limits := Limits{}) -> (Info, Error) {
	limits_ := normalized_limits(limits)
	if !supported_mime(mime_type) do return {}, .Unsupported
	if len(data) == 0 || len(data) > limits_.max_bytes do return {}, .Limit_Exceeded
	if !signature_matches(data, mime_type) do return {}, .Invalid
	width, height, channels: c.int
	if stbi.info_from_memory(raw_data(data), c.int(len(data)), &width, &height, &channels) == 0 {
		return {}, .Invalid
	}
	if width <= 0 || height <= 0 || int(width) > limits_.max_dimension || int(height) > limits_.max_dimension ||
		i64(width) * i64(height) > limits_.max_pixels {
		return {}, .Limit_Exceeded
	}
	return {
		mime_type = mime_type,
		width = int(width),
		height = int(height),
		channels = int(channels),
	}, .None
}

inspect :: proc(data: []byte, mime_type: string, limits := Limits{}) -> (Info, Error) {
	info, err := probe(data, mime_type, limits)
	if err != .None do return {}, err
	width, height, channels: c.int
	pixels := stbi.load_from_memory(raw_data(data), c.int(len(data)), &width, &height, &channels, 4)
	if pixels == nil do return {}, .Invalid
	stbi.image_free(pixels)
	if int(width) != info.width || int(height) != info.height do return {}, .Invalid
	return info, .None
}

secure_directory :: proc(path: string) -> bool {
	if !os.exists(path) && os.make_directory(path, os.perm(0o700)) != nil do return false
	info, err := os.lstat(path, context.temp_allocator)
	if err != nil || info.type != .Directory do return false
	return os.chmod(path, os.perm(0o700)) == nil
}

valid_key :: proc(key: string) -> bool {
	if len(key) != 64 do return false
	for value in key {
		if !('0' <= value && value <= '9') && !('a' <= value && value <= 'f') do return false
	}
	return true
}

thumbnail_size :: proc(width, height, edge: int) -> (int, int) {
	if width <= edge && height <= edge do return width, height
	if width >= height do return edge, max(1, height * edge / width)
	return max(1, width * edge / height), edge
}

ensure_thumbnail :: proc(cache_dir, key: string, data: []byte, mime_type: string, limits := Limits{}) -> (Preview, Error) {
	if !valid_key(key) do return {}, .Invalid
	limits_ := normalized_limits(limits)
	info, err := inspect(data, mime_type, limits_)
	if err != .None do return {}, err
	if !secure_directory(cache_dir) do return {}, .IO
	thumbnail_dir, path_err := filepath.join({cache_dir, "thumbnails"})
	if path_err != nil do return {}, .IO
	defer delete(thumbnail_dir)
	if !secure_directory(thumbnail_dir) do return {}, .IO

	reference := fmt.aprintf("%s.png", key)
	path, path_join_err := filepath.join({thumbnail_dir, reference})
	if path_join_err != nil {
		delete(reference)
		return {}, .IO
	}
	output_width, output_height := thumbnail_size(info.width, info.height, limits_.thumbnail_edge)
	if os.exists(path) {
		file_info, stat_err := os.lstat(path, context.temp_allocator)
		if stat_err != nil || file_info.type != .Regular || os.chmod(path, os.perm(0o600)) != nil {
			delete(reference)
			delete(path)
			return {}, .IO
		}
		return {ref = reference, path = path, width = output_width, height = output_height}, .None
	}

	width, height, channels: c.int
	pixels := stbi.load_from_memory(raw_data(data), c.int(len(data)), &width, &height, &channels, 4)
	if pixels == nil {
		delete(reference)
		delete(path)
		return {}, .Invalid
	}
	defer stbi.image_free(pixels)
	resized := make([]byte, output_width * output_height * 4)
	defer delete(resized)
	if stbi.resize_uint8_srgb(
		pixels, width, height, 0, raw_data(resized), c.int(output_width), c.int(output_height), 0, 4, 3, 0,
	) == 0 {
		delete(reference)
		delete(path)
		return {}, .Invalid
	}

	file, file_err := os.create_temp_file(thumbnail_dir, ".tmp-*.png")
	if file_err != nil {
		delete(reference)
		delete(path)
		return {}, .IO
	}
	temporary := strings.clone(os.name(file))
	_ = os.close(file)
	committed := false
	defer {
		if !committed do _ = os.remove(temporary)
		delete(temporary)
	}
	cpath, alloc_err := strings.clone_to_cstring(temporary, context.temp_allocator)
	if alloc_err != nil || stbi.write_png(cpath, c.int(output_width), c.int(output_height), 4, raw_data(resized), c.int(output_width * 4)) == 0 ||
		os.chmod(temporary, os.perm(0o600)) != nil {
		delete(reference)
		delete(path)
		return {}, .IO
	}
	if written, open_err := os.open(temporary); open_err == nil {
		if os.sync(written) != nil {
			_ = os.close(written)
			delete(reference)
			delete(path)
			return {}, .IO
		}
		_ = os.close(written)
	} else {
		delete(reference)
		delete(path)
		return {}, .IO
	}
	if os.rename(temporary, path) != nil {
		delete(reference)
		delete(path)
		return {}, .IO
	}
	committed = true
	return {ref = reference, path = path, width = output_width, height = output_height}, .None
}
