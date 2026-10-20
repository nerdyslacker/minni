package storage

import "core:crypto"
import crypto_hash "core:crypto/hash"
import "core:os"
import "core:path/filepath"
import "core:strings"

hex_string :: proc(bytes: []byte) -> string {
	digits := "0123456789abcdef"
	result := make([]byte, len(bytes) * 2)
	for byte, index in bytes {
		result[index * 2] = digits[byte >> 4]
		result[index * 2 + 1] = digits[byte & 0x0f]
	}
	return string(result)
}

content_digest :: proc(data: []byte) -> string {
	digest: [32]byte
	crypto_hash.hash_bytes_to_buffer(.SHA256, data, digest[:])
	return hex_string(digest[:])
}

new_id :: proc() -> string {
	bytes: [16]byte
	crypto.rand_bytes(bytes[:])
	return hex_string(bytes[:])
}

blob_path :: proc(store: ^Store, digest: string) -> (string, Error_Code) {
	if len(digest) != 64 do return "", .Invalid_Input
	path, err := filepath.join({store.blob_dir, digest[:2], digest})
	if err != nil do return "", .IO
	return path, .None
}

write_all :: proc(file: ^os.File, data: []byte) -> bool {
	written := 0
	for written < len(data) {
		count, err := os.write(file, data[written:])
		if err != nil || count <= 0 do return false
		written += count
	}
	return true
}

write_blob :: proc(store: ^Store, digest: string, data: []byte) -> Error_Code {
	path, err := blob_path(store, digest)
	if err != .None do return err
	defer delete(path)

	if os.exists(path) {
		existing, read_err := os.read_entire_file(path, context.temp_allocator)
		existing_digest := ""
		if read_err == nil {
			existing_digest = content_digest(existing)
		}
		valid := read_err == nil && len(existing) == len(data) && existing_digest == digest
		delete(existing_digest)
		if !valid {
			set_error(store, "existing content-addressed blob failed verification")
			return .Integrity
		}
		return .None
	}

	prefix, alloc_err := filepath.join({store.blob_dir, digest[:2]})
	if alloc_err != nil do return .IO
	defer delete(prefix)
	if !secure_directory(prefix) {
		return .IO
	}

	file, file_err := os.create_temp_file(prefix, ".tmp-*")
	if file_err != nil do return .IO
	temporary := strings.clone(os.name(file))
	defer delete(temporary)
	committed := false
	defer {
		if file != nil do _ = os.close(file)
		if !committed do _ = os.remove(temporary)
	}
	if os.chmod(temporary, os.perm(0o600)) != nil do return .IO
	if !write_all(file, data) || os.sync(file) != nil do return .IO
	if os.close(file) != nil do return .IO
	file = nil
	if os.rename(temporary, path) != nil {
		return .IO
	}
	committed = true
	if directory, open_err := os.open(prefix); open_err == nil {
		_ = os.sync(directory)
		_ = os.close(directory)
	}
	return .None
}

blob_referenced :: proc(store: ^Store, digest: string) -> (bool, Error_Code) {
	statement, err := prepare(store, "SELECT 1 FROM blobs WHERE hash=?1")
	if err != .None do return false, err
	defer sqlite3_finalize(statement)
	if err = bind_text(store, statement, 1, digest); err != .None do return false, err
	result := sqlite3_step(statement)
	if result == SQLITE_ROW do return true, .None
	if result == SQLITE_DONE do return false, .None
	return false, set_database_error(store)
}

cleanup_orphan_files :: proc(store: ^Store) -> Error_Code {
	walker := os.walker_create(store.blob_dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Regular do continue
		if strings.has_prefix(info.name, ".tmp-") {
			_ = os.remove(info.fullpath)
			continue
		}
		if len(info.name) != 64 do continue
		referenced, err := blob_referenced(store, info.name)
		if err != .None do return err
		if !referenced {
			_ = os.remove(info.fullpath)
		}
	}
	if _, walk_err := os.walker_error(&walker); walk_err != nil {
		return .IO
	}
	return .None
}
