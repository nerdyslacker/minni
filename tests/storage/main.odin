package main

import "core:fmt"
import "core:os"
import "core:strings"
import storage "../../src/storage"

passes: int
failures: int

ok :: proc(condition: bool, message: string) {
	if condition {
		passes += 1
	} else {
		failures += 1
		fmt.eprintln("FAIL:", message)
	}
}

eq :: proc(got, expected: $T, message: string) {
	ok(got == expected, fmt.tprintf("%s (got=%v expected=%v)", message, got, expected))
}

temporary_root :: proc() -> string {
	path, err := os.make_directory_temp("/tmp", "minni-storage-*", context.allocator)
	if err != nil {
		fmt.eprintln("cannot create test directory:", err)
		os.exit(1)
	}
	return path
}

text_input :: proc(value: string, timestamp: i64, mime := "text/plain;charset=utf-8") -> storage.Item_Input {
	return {
		selection_source = "clipboard",
		mime_type = mime,
		kind = "text",
		data = transmute([]byte)value,
		created_at = timestamp,
		last_used_at = timestamp,
	}
}

test_restart_and_deduplication :: proc() {
	root := temporary_root()
	defer { _ = os.remove_all(root); delete(root) }
	ok(storage.secure_directory(root), "secure temporary state directory")
	blob_root := fmt.aprintf("%s/blobs", root)
	blob_sha := fmt.aprintf("%s/sha256", blob_root)
	ok(storage.secure_directory(blob_root), "secure blob root")
	ok(storage.secure_directory(blob_sha), "secure hash root")
	delete(blob_sha)
	delete(blob_root)
	store, err := storage.open_default(root)
	eq(err, storage.Error_Code.None, "open new store")
	if err != .None do return

	item, result, put_err := storage.put(store, text_input("hello\nաշխարհ", 1000))
	eq(put_err, storage.Error_Code.None, "insert UTF-8 text")
	eq(result, storage.Put_Result.Inserted, "first capture is inserted")
	eq(len(item.id), 32, "stable ID is 128-bit hex")
	first_id := strings.clone(item.id)
	storage.destroy_item(&item)

	pinned, pin_err := storage.set_pinned(store, first_id, true)
	eq(pin_err, storage.Error_Code.None, "pin item")
	storage.destroy_item(&pinned)

	duplicate := text_input("hello\nաշխարհ", 2000)
	duplicate.source_app = "test-app"
	item, result, put_err = storage.put(store, duplicate)
	eq(put_err, storage.Error_Code.None, "deduplicate repeated content")
	eq(result, storage.Put_Result.Deduplicated, "repeat reports deduplication")
	eq(item.id, first_id, "deduplication preserves ID")
	ok(item.pinned, "deduplication preserves pin")
	eq(item.created_at, i64(1000), "deduplication preserves creation time")
	eq(item.last_used_at, i64(2000), "deduplication updates recency")
	storage.destroy_item(&item)
	storage.close(store)

	store, err = storage.open_default(root)
	eq(err, storage.Error_Code.None, "reopen store")
	if err == .None {
		items, list_err := storage.list(store)
		eq(list_err, storage.Error_Code.None, "list after restart")
		eq(len(items), 1, "restart keeps one deduplicated item")
		if len(items) == 1 do ok(items[0].pinned, "pin survives restart")
		storage.destroy_items(items)
		payload, payload_err := storage.read_payload(store, first_id)
		eq(payload_err, storage.Error_Code.None, "read payload after restart")
		eq(string(payload), "hello\nաշխարհ", "payload survives restart exactly")
		delete(payload)
		storage.close(store)
	}
	delete(first_id)
}

test_reference_aware_gc :: proc() {
	root := temporary_root()
	defer { _ = os.remove_all(root); delete(root) }
	store, err := storage.open_default(root)
	if err != .None { ok(false, "open GC store"); return }
	defer storage.close(store)

	plain, _, plain_err := storage.put(store, text_input("shared", 1, "text/plain"))
	html, _, html_err := storage.put(store, text_input("shared", 2, "text/html"))
	eq(plain_err, storage.Error_Code.None, "insert first MIME")
	eq(html_err, storage.Error_Code.None, "insert second MIME")
	ok(plain.id != html.id, "deduplication is MIME-aware")
	digest := strings.clone(plain.content_hash[len("sha256:"):])
	path, path_err := storage.blob_path(store, digest)
	eq(path_err, storage.Error_Code.None, "resolve shared blob")
	ok(os.exists(path), "shared blob exists")
	eq(storage.remove(store, plain.id), storage.Error_Code.None, "remove first reference")
	ok(os.exists(path), "blob remains while referenced")
	eq(storage.remove(store, html.id), storage.Error_Code.None, "remove final reference")
	ok(!os.exists(path), "blob is removed after final reference")
	delete(path)
	delete(digest)
	storage.destroy_item(&plain)
	storage.destroy_item(&html)
}

test_retention_and_clear :: proc() {
	root := temporary_root()
	defer { _ = os.remove_all(root); delete(root) }
	config := storage.default_config()
	config.max_unpinned_items = 2
	store, err := storage.open(root, config)
	if err != .None { ok(false, "open retention store"); return }
	defer storage.close(store)

	a, _, _ := storage.put(store, text_input("a", 1))
	pinned, _ := storage.set_pinned(store, a.id, true)
	storage.destroy_item(&pinned)
	b, _, _ := storage.put(store, text_input("b", 2))
	c, _, _ := storage.put(store, text_input("c", 3))
	d, _, _ := storage.put(store, text_input("d", 4))
	_, b_err := storage.get(store, b.id)
	eq(b_err, storage.Error_Code.Not_Found, "oldest unpinned item is evicted")
	items, list_err := storage.list(store)
	eq(list_err, storage.Error_Code.None, "list retained items")
	eq(len(items), 3, "pins do not count toward unpinned limit")
	storage.destroy_items(items)
	removed, clear_err := storage.clear(store, .Unpinned)
	eq(clear_err, storage.Error_Code.None, "clear unpinned")
	eq(removed, 2, "clear removes only unpinned items")
	_, a_err := storage.get(store, a.id)
	eq(a_err, storage.Error_Code.None, "clear preserves pin")
	removed, clear_err = storage.clear(store, .All)
	eq(clear_err, storage.Error_Code.None, "clear all")
	eq(removed, 1, "clear all removes pin explicitly")
	e, _, _ := storage.put(store, text_input("same-a", 5))
	f, _, _ := storage.put(store, text_input("same-b", 5))
	g, _, g_err := storage.put(store, text_input("same-c", 5))
	eq(g_err, storage.Error_Code.None, "same-time capture survives retention")
	newest, newest_err := storage.get(store, g.id)
	eq(newest_err, storage.Error_Code.None, "protected capture is retained")
	storage.destroy_item(&newest)
	storage.destroy_item(&a)
	storage.destroy_item(&b)
	storage.destroy_item(&c)
	storage.destroy_item(&d)
	storage.destroy_item(&e)
	storage.destroy_item(&f)
	storage.destroy_item(&g)
}

test_pin_budget_policy :: proc() {
	root := temporary_root()
	defer { _ = os.remove_all(root); delete(root) }
	config := storage.default_config()
	config.max_image_storage = 5
	config.max_image_bytes = 10
	store, err := storage.open(root, config)
	if err != .None { ok(false, "open image budget store"); return }
	defer storage.close(store)

	first_input := storage.Item_Input{
		selection_source = "clipboard", mime_type = "image/png", kind = "image",
		data = []byte{1, 2, 3, 4}, created_at = 1, last_used_at = 1,
	}
	first, _, first_err := storage.put(store, first_input)
	eq(first_err, storage.Error_Code.None, "insert image within budget")
	pinned, pin_err := storage.set_pinned(store, first.id, true)
	eq(pin_err, storage.Error_Code.None, "pin image")
	storage.destroy_item(&pinned)
	second_input := storage.Item_Input{
		selection_source = "clipboard", mime_type = "image/jpeg", kind = "image",
		data = []byte{5, 6, 7}, created_at = 2, last_used_at = 2,
	}
	second, _, second_err := storage.put(store, second_input)
	eq(second_err, storage.Error_Code.Limit_Exceeded, "pinned budget rejects new image")
	storage.destroy_item(&second)
	rejected_hash := storage.content_digest(second_input.data)
	rejected_path, _ := storage.blob_path(store, rejected_hash)
	ok(!os.exists(rejected_path), "rejected capture leaves no orphan blob")
	delete(rejected_path)
	delete(rejected_hash)
	items, _ := storage.list(store)
	eq(len(items), 1, "rejected image does not alter history")
	if len(items) == 1 do eq(items[0].id, first.id, "pinned image remains")
	storage.destroy_items(items)
	storage.destroy_item(&first)
}

test_validation_corruption_and_permissions :: proc() {
	root := temporary_root()
	defer { _ = os.remove_all(root); delete(root) }
	config := storage.default_config()
	config.max_text_bytes = 4
	store, err := storage.open(root, config)
	if err != .None { ok(false, "open validation store"); return }

	oversized, _, oversized_err := storage.put(store, text_input("12345", 1))
	eq(oversized_err, storage.Error_Code.Limit_Exceeded, "reject oversized text")
	storage.destroy_item(&oversized)
	bad := text_input("x", 1)
	bad.data = []byte{0xff}
	invalid, _, invalid_err := storage.put(store, bad)
	eq(invalid_err, storage.Error_Code.Invalid_Input, "reject invalid UTF-8")
	storage.destroy_item(&invalid)

	root_info, _ := os.stat(root, context.temp_allocator)
	db_info, _ := os.stat(store.database_path, context.temp_allocator)
	eq(root_info.mode, os.perm(0o700), "state directory is private")
	eq(db_info.mode, os.perm(0o600), "database is private")

	item, _, put_err := storage.put(store, text_input("1234", 2))
	eq(put_err, storage.Error_Code.None, "insert item for corruption test")
	digest := strings.clone(item.content_hash[len("sha256:"):])
	path, _ := storage.blob_path(store, digest)
	blob_info, _ := os.stat(path, context.temp_allocator)
	eq(blob_info.mode, os.perm(0o600), "blob is private")
	_ = os.write_entire_file(path, "broken", os.perm(0o600))
	eq(storage.integrity_check(store), storage.Error_Code.Integrity, "detect corrupted blob")
	storage.close(store)
	store, err = storage.open(root, config)
	eq(err, storage.Error_Code.Integrity, "reject corrupted store on restart")
	if store != nil do storage.close(store)
	delete(path)
	delete(digest)
	storage.destroy_item(&item)
}

test_age_and_schema_constraints :: proc() {
	root := temporary_root()
	defer { _ = os.remove_all(root); delete(root) }
	config := storage.default_config()
	config.max_age_seconds = 2
	store, err := storage.open(root, config)
	if err != .None { ok(false, "open age store"); return }
	defer storage.close(store)

	old, _, old_err := storage.put(store, text_input("old", 1000))
	eq(old_err, storage.Error_Code.None, "insert old item")
	newer, _, new_err := storage.put(store, text_input("new", 4001))
	eq(new_err, storage.Error_Code.None, "insert item after age window")
	_, missing_err := storage.get(store, old.id)
	eq(missing_err, storage.Error_Code.Not_Found, "age retention expires old unpinned item")

	malformed_err := storage.exec_sql(store, `INSERT INTO items(
id, created_at, last_used_at, selection_source, mime_type, kind, byte_length, content_hash)
VALUES('bad', 1, 1, 'invalid', 'text/plain', 'text', 0, 'missing')`)
	eq(malformed_err, storage.Error_Code.Database, "schema rejects malformed records")
	eq(storage.integrity_check(store), storage.Error_Code.None, "constraint failure leaves store valid")
	storage.destroy_item(&old)
	storage.destroy_item(&newer)
}

test_orphans_schema_and_write_failure :: proc() {
	root := temporary_root()
	defer { _ = os.remove_all(root); delete(root) }
	store, err := storage.open_default(root)
	if err != .None { ok(false, "open orphan store"); return }
	orphan_hash := strings.repeat("a", 64)
	orphan_path, _ := storage.blob_path(store, orphan_hash)
	orphan_dir := filepath_dir(orphan_path)
	_ = os.make_directory_all(orphan_dir, os.perm(0o700))
	_ = os.write_entire_file(orphan_path, "orphan", os.perm(0o600))
	storage.close(store)
	store, err = storage.open_default(root)
	eq(err, storage.Error_Code.None, "reopen with orphan")
	ok(!os.exists(orphan_path), "startup removes orphan blob")
	if err == .None {
		_ = storage.exec_sql(store, "PRAGMA user_version=999")
		storage.close(store)
	}
	store, err = storage.open_default(root)
	eq(err, storage.Error_Code.Unsupported_Schema, "reject newer schema")
	if store != nil do storage.close(store)
	delete(orphan_hash)
	delete(orphan_path)
	delete(orphan_dir)

	broken_root := temporary_root()
	defer { _ = os.remove_all(broken_root); delete(broken_root) }
	broken, broken_err := storage.open_default(broken_root)
	if broken_err != .None { ok(false, "open write-failure store"); return }
	_ = os.remove_all(broken.blob_dir)
	_ = os.write_entire_file(broken.blob_dir, "not a directory", os.perm(0o600))
	item, _, write_err := storage.put(broken, text_input("safe", 1))
	eq(write_err, storage.Error_Code.IO, "surface blob write failure")
	items, list_err := storage.list(broken)
	eq(list_err, storage.Error_Code.None, "database remains readable after write failure")
	eq(len(items), 0, "write failure commits no metadata")
	storage.destroy_items(items)
	storage.destroy_item(&item)
	storage.close(broken)
}

filepath_dir :: proc(path: string) -> string {
	last := -1
	for byte, index in transmute([]byte)path {
		if byte == '/' do last = index
	}
	if last <= 0 do return strings.clone(".")
	return strings.clone(path[:last])
}

main :: proc() {
	test_restart_and_deduplication()
	test_reference_aware_gc()
	test_retention_and_clear()
	test_pin_budget_policy()
	test_validation_corruption_and_permissions()
	test_age_and_schema_constraints()
	test_orphans_schema_and_write_failure()
	fmt.printfln("%d passed, %d failed", passes, failures)
	if failures > 0 do os.exit(1)
}
