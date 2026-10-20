package storage

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

ITEM_COLUMNS :: `id, created_at, last_used_at, selection_source, mime_type, kind,
byte_length, content_hash, pinned, label, preview_text, source_app`

now_milliseconds :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

valid_input :: proc(store: ^Store, input: Item_Input) -> Error_Code {
	if input.selection_source != "clipboard" && input.selection_source != "primary" {
		return .Invalid_Input
	}
	if input.kind != "text" && input.kind != "image" && input.kind != "uri_list" {
		return .Invalid_Input
	}
	if len(input.mime_type) == 0 || len(input.data) == 0 {
		return .Invalid_Input
	}
	if input.kind == "text" || input.kind == "uri_list" {
		if !utf8.valid_string(string(input.data)) do return .Invalid_Input
		if store.config.max_text_bytes > 0 && i64(len(input.data)) > store.config.max_text_bytes {
			return .Limit_Exceeded
		}
	} else if store.config.max_image_bytes > 0 && i64(len(input.data)) > store.config.max_image_bytes {
		return .Limit_Exceeded
	}
	return .None
}

make_preview :: proc(input: Item_Input) -> string {
	if input.kind == "image" do return ""
	count := min(len(input.data), 256)
	for count > 0 && !utf8.valid_string(string(input.data[:count])) {
		count -= 1
	}
	return strings.clone(string(input.data[:count]))
}

item_from_statement :: proc(statement: ^SQLite_Stmt) -> Item {
	item := Item{
		id = column_string(statement, 0),
		created_at = sqlite3_column_int64(statement, 1),
		last_used_at = sqlite3_column_int64(statement, 2),
		selection_source = column_string(statement, 3),
		mime_type = column_string(statement, 4),
		kind = column_string(statement, 5),
		byte_length = sqlite3_column_int64(statement, 6),
		pinned = sqlite3_column_int(statement, 8) != 0,
		label = column_string(statement, 9),
		preview_text = column_string(statement, 10),
		source_app = column_string(statement, 11),
	}
	hash := column_string(statement, 7)
	item.content_hash = fmt.aprintf("sha256:%s", hash)
	delete(hash)
	return item
}

get :: proc(store: ^Store, id: string) -> (Item, Error_Code) {
	query := fmt.tprintf("SELECT %s FROM items WHERE id=?1", ITEM_COLUMNS)
	statement, err := prepare(store, query)
	if err != .None do return {}, err
	defer sqlite3_finalize(statement)
	if err = bind_text(store, statement, 1, id); err != .None do return {}, err
	result := sqlite3_step(statement)
	if result == SQLITE_DONE do return {}, .Not_Found
	if result != SQLITE_ROW do return {}, set_database_error(store)
	return item_from_statement(statement), .None
}

list :: proc(store: ^Store, pinned_only := false) -> ([]Item, Error_Code) {
	query := fmt.tprintf(
		"SELECT %s FROM items %s ORDER BY pinned DESC, last_used_at DESC, id ASC",
		ITEM_COLUMNS,
		"WHERE pinned=1" if pinned_only else "",
	)
	statement, err := prepare(store, query)
	if err != .None do return nil, err
	defer sqlite3_finalize(statement)
	items := make([dynamic]Item)
	for {
		result := sqlite3_step(statement)
		if result == SQLITE_DONE do break
		if result != SQLITE_ROW {
			destroy_items(items[:])
			return nil, set_database_error(store)
		}
		append(&items, item_from_statement(statement))
	}
	return items[:], .None
}

item_exists :: proc(store: ^Store, id: string) -> (bool, Error_Code) {
	statement, err := prepare(store, "SELECT 1 FROM items WHERE id=?1")
	if err != .None do return false, err
	defer sqlite3_finalize(statement)
	if err = bind_text(store, statement, 1, id); err != .None do return false, err
	result := sqlite3_step(statement)
	if result == SQLITE_ROW do return true, .None
	if result == SQLITE_DONE do return false, .None
	return false, set_database_error(store)
}

delete_oldest_unpinned_image :: proc(store: ^Store) -> (bool, Error_Code) {
	statement, err := prepare(store, `DELETE FROM items WHERE id=(
SELECT id FROM items WHERE pinned=0 AND kind='image'
ORDER BY last_used_at ASC, id ASC LIMIT 1)`) 
	if err != .None do return false, err
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_DONE do return false, set_database_error(store)
	return sqlite3_changes(store.database) > 0, .None
}

enforce_retention :: proc(store: ^Store, protected_id: string, now: i64) -> Error_Code {
	if store.config.max_age_seconds > 0 {
		statement, err := prepare(store, "DELETE FROM items WHERE pinned=0 AND last_used_at<?1")
		if err != .None do return err
		threshold := now - store.config.max_age_seconds * 1000
		if sqlite3_bind_int64(statement, 1, threshold) != SQLITE_OK || sqlite3_step(statement) != SQLITE_DONE {
			sqlite3_finalize(statement)
			return set_database_error(store)
		}
		sqlite3_finalize(statement)
	}

	if store.config.max_unpinned_items >= 0 {
		statement, err := prepare(store, `DELETE FROM items WHERE id IN (
SELECT id FROM items WHERE pinned=0 ORDER BY last_used_at DESC, id ASC LIMIT -1 OFFSET ?1)`) 
		if err != .None do return err
		if sqlite3_bind_int(statement, 1, i32(store.config.max_unpinned_items)) != SQLITE_OK ||
			sqlite3_step(statement) != SQLITE_DONE {
			sqlite3_finalize(statement)
			return set_database_error(store)
		}
		sqlite3_finalize(statement)
	}

	if store.config.max_image_storage > 0 {
		for {
			usage, err := query_integer(store, `SELECT COALESCE(SUM(byte_length), 0) FROM blobs
WHERE hash IN (SELECT content_hash FROM items WHERE kind='image')`)
			if err != .None do return err
			if usage <= store.config.max_image_storage do break
			removed, remove_err := delete_oldest_unpinned_image(store)
			if remove_err != .None do return remove_err
			if !removed do break
		}
	}

	if len(protected_id) > 0 {
		exists, err := item_exists(store, protected_id)
		if err != .None do return err
		if !exists do return .Limit_Exceeded
	}
	return .None
}

collect_orphan_blobs :: proc(store: ^Store) -> ([]string, Error_Code) {
	statement, err := prepare(store, `DELETE FROM blobs
WHERE NOT EXISTS (SELECT 1 FROM items WHERE items.content_hash=blobs.hash)
RETURNING hash`)
	if err != .None do return nil, err
	defer sqlite3_finalize(statement)
	hashes := make([dynamic]string)
	for {
		result := sqlite3_step(statement)
		if result == SQLITE_DONE do break
		if result != SQLITE_ROW {
			for hash in hashes do delete(hash)
			delete(hashes)
			return nil, set_database_error(store)
		}
		append(&hashes, column_string(statement, 0))
	}
	return hashes[:], .None
}

remove_blob_files :: proc(store: ^Store, hashes: []string) {
	for hash in hashes {
		if path, err := blob_path(store, hash); err == .None {
			_ = os.remove(path)
			delete(path)
		}
		delete(hash)
	}
	delete(hashes)
}

put :: proc(store: ^Store, input: Item_Input) -> (Item, Put_Result, Error_Code) {
	if err := valid_input(store, input); err != .None do return {}, {}, err
	digest := content_digest(input.data)
	defer delete(digest)
	if err := write_blob(store, digest, input.data); err != .None do return {}, {}, err

	created_at := input.created_at
	if created_at <= 0 do created_at = now_milliseconds()
	last_used_at := input.last_used_at
	if last_used_at <= 0 do last_used_at = created_at

	if err := begin(store); err != .None {
		_ = cleanup_orphan_files(store)
		return {}, {}, err
	}
	finished := false
	defer if !finished {
		rollback(store)
		_ = cleanup_orphan_files(store)
	}

	statement, err := prepare(store, "SELECT id FROM items WHERE mime_type=?1 AND content_hash=?2")
	if err != .None do return {}, {}, err
	if err = bind_text(store, statement, 1, input.mime_type); err == .None {
		err = bind_text(store, statement, 2, digest)
	}
	if err != .None {
		sqlite3_finalize(statement)
		return {}, {}, err
	}
	step := sqlite3_step(statement)
	if step == SQLITE_ROW {
		id := column_string(statement, 0)
		sqlite3_finalize(statement)
		update, update_err := prepare(store, `UPDATE items SET last_used_at=?1,
selection_source=?2, source_app=COALESCE(?3, source_app) WHERE id=?4`)
		if update_err != .None {
			delete(id)
			return {}, {}, update_err
		}
		sqlite3_bind_int64(update, 1, last_used_at)
		update_err = bind_text(store, update, 2, input.selection_source)
		if update_err == .None do update_err = bind_optional_text(store, update, 3, input.source_app)
		if update_err == .None do update_err = bind_text(store, update, 4, id)
		if update_err == .None && sqlite3_step(update) != SQLITE_DONE do update_err = set_database_error(store)
		sqlite3_finalize(update)
		if update_err != .None {
			delete(id)
			return {}, {}, update_err
		}
		if update_err = enforce_retention(store, id, last_used_at); update_err != .None {
			delete(id)
			return {}, {}, update_err
		}
		orphans, orphan_err := collect_orphan_blobs(store)
		if orphan_err != .None {
			delete(id)
			return {}, {}, orphan_err
		}
		if err = commit(store); err != .None {
			for hash in orphans do delete(hash)
			delete(orphans)
			delete(id)
			return {}, {}, err
		}
		finished = true
		remove_blob_files(store, orphans)
		item, get_err := get(store, id)
		delete(id)
		secure_database_files(store)
		return item, .Deduplicated, get_err
	}
	if step != SQLITE_DONE {
		sqlite3_finalize(statement)
		return {}, {}, set_database_error(store)
	}
	sqlite3_finalize(statement)

	insert_blob, insert_err := prepare(store, "INSERT OR IGNORE INTO blobs(hash, byte_length) VALUES(?1, ?2)")
	if insert_err != .None do return {}, {}, insert_err
	insert_err = bind_text(store, insert_blob, 1, digest)
	if insert_err == .None && sqlite3_bind_int64(insert_blob, 2, i64(len(input.data))) != SQLITE_OK {
		insert_err = set_database_error(store)
	}
	if insert_err == .None && sqlite3_step(insert_blob) != SQLITE_DONE do insert_err = set_database_error(store)
	sqlite3_finalize(insert_blob)
	if insert_err != .None do return {}, {}, insert_err

	id := new_id()
	defer delete(id)
	preview := make_preview(input)
	defer delete(preview)
	insert, item_err := prepare(store, `INSERT INTO items(
id, created_at, last_used_at, selection_source, mime_type, kind, byte_length,
content_hash, label, preview_text, source_app)
VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)`)
	if item_err != .None do return {}, {}, item_err
	item_err = bind_text(store, insert, 1, id)
	sqlite3_bind_int64(insert, 2, created_at)
	sqlite3_bind_int64(insert, 3, last_used_at)
	if item_err == .None do item_err = bind_text(store, insert, 4, input.selection_source)
	if item_err == .None do item_err = bind_text(store, insert, 5, input.mime_type)
	if item_err == .None do item_err = bind_text(store, insert, 6, input.kind)
	sqlite3_bind_int64(insert, 7, i64(len(input.data)))
	if item_err == .None do item_err = bind_text(store, insert, 8, digest)
	if item_err == .None do item_err = bind_optional_text(store, insert, 9, input.label)
	if item_err == .None do item_err = bind_optional_text(store, insert, 10, preview)
	if item_err == .None do item_err = bind_optional_text(store, insert, 11, input.source_app)
	if item_err == .None && sqlite3_step(insert) != SQLITE_DONE do item_err = set_database_error(store)
	sqlite3_finalize(insert)
	if item_err != .None do return {}, {}, item_err

	if err = enforce_retention(store, id, last_used_at); err != .None do return {}, {}, err
	orphans, orphan_err := collect_orphan_blobs(store)
	if orphan_err != .None do return {}, {}, orphan_err
	if err = commit(store); err != .None {
		for hash in orphans do delete(hash)
		delete(orphans)
		return {}, {}, err
	}
	finished = true
	remove_blob_files(store, orphans)
	item, get_err := get(store, id)
	secure_database_files(store)
	return item, .Inserted, get_err
}

set_pinned :: proc(store: ^Store, id: string, pinned: bool) -> (Item, Error_Code) {
	statement, err := prepare(store, "UPDATE items SET pinned=?1 WHERE id=?2")
	if err != .None do return {}, err
	sqlite3_bind_int(statement, 1, 1 if pinned else 0)
	if err = bind_text(store, statement, 2, id); err != .None {
		sqlite3_finalize(statement)
		return {}, err
	}
	if sqlite3_step(statement) != SQLITE_DONE {
		sqlite3_finalize(statement)
		return {}, set_database_error(store)
	}
	sqlite3_finalize(statement)
	if sqlite3_changes(store.database) == 0 do return {}, .Not_Found
	return get(store, id)
}

remove :: proc(store: ^Store, id: string) -> Error_Code {
	if err := begin(store); err != .None do return err
	finished := false
	defer if !finished do rollback(store)
	statement, err := prepare(store, "DELETE FROM items WHERE id=?1")
	if err != .None do return err
	if err = bind_text(store, statement, 1, id); err != .None {
		sqlite3_finalize(statement)
		return err
	}
	if sqlite3_step(statement) != SQLITE_DONE {
		sqlite3_finalize(statement)
		return set_database_error(store)
	}
	sqlite3_finalize(statement)
	if sqlite3_changes(store.database) == 0 do return .Not_Found
	orphans, orphan_err := collect_orphan_blobs(store)
	if orphan_err != .None do return orphan_err
	if orphan_err = commit(store); orphan_err != .None {
		for hash in orphans do delete(hash)
		delete(orphans)
		return orphan_err
	}
	finished = true
	remove_blob_files(store, orphans)
	return .None
}

clear :: proc(store: ^Store, scope: Clear_Scope) -> (int, Error_Code) {
	if err := begin(store); err != .None do return 0, err
	finished := false
	defer if !finished do rollback(store)
	sql := "DELETE FROM items WHERE pinned=0"
	if scope == .All do sql = "DELETE FROM items"
	if err := exec_sql(store, sql); err != .None do return 0, err
	count := int(sqlite3_changes(store.database))
	orphans, err := collect_orphan_blobs(store)
	if err != .None do return 0, err
	if err = commit(store); err != .None {
		for hash in orphans do delete(hash)
		delete(orphans)
		return 0, err
	}
	finished = true
	remove_blob_files(store, orphans)
	return count, .None
}

read_payload :: proc(store: ^Store, id: string) -> ([]byte, Error_Code) {
	statement, err := prepare(store, "SELECT content_hash FROM items WHERE id=?1")
	if err != .None do return nil, err
	defer sqlite3_finalize(statement)
	if err = bind_text(store, statement, 1, id); err != .None do return nil, err
	result := sqlite3_step(statement)
	if result == SQLITE_DONE do return nil, .Not_Found
	if result != SQLITE_ROW do return nil, set_database_error(store)
	hash := column_string(statement, 0)
	defer delete(hash)
	path, path_err := blob_path(store, hash)
	if path_err != .None do return nil, path_err
	defer delete(path)
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		set_error(store, "referenced blob is missing")
		return nil, .Integrity
	}
	actual := content_digest(data)
	defer delete(actual)
	if actual != hash {
		delete(data)
		set_error(store, "referenced blob hash mismatch")
		return nil, .Integrity
	}
	return data, .None
}

integrity_check :: proc(store: ^Store) -> Error_Code {
	statement, err := prepare(store, "PRAGMA integrity_check")
	if err != .None do return err
	result := sqlite3_step(statement)
	check_result := ""
	if result == SQLITE_ROW {
		check_result = column_string(statement, 0)
	}
	check_ok := result == SQLITE_ROW && check_result == "ok"
	delete(check_result)
	if !check_ok {
		sqlite3_finalize(statement)
		set_error(store, "SQLite integrity check failed")
		return .Integrity
	}
	sqlite3_finalize(statement)

	statement, err = prepare(store, "PRAGMA foreign_key_check")
	if err != .None do return err
	result = sqlite3_step(statement)
	sqlite3_finalize(statement)
	if result != SQLITE_DONE {
		set_error(store, "SQLite foreign key check failed")
		return .Integrity
	}

	statement, err = prepare(store, "SELECT hash, byte_length FROM blobs")
	if err != .None do return err
	defer sqlite3_finalize(statement)
	for {
		result = sqlite3_step(statement)
		if result == SQLITE_DONE do break
		if result != SQLITE_ROW do return set_database_error(store)
		hash := column_string(statement, 0)
		path, path_err := blob_path(store, hash)
		if path_err != .None {
			delete(hash)
			return path_err
		}
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		delete(path)
		actual := ""
		if read_err == nil {
			actual = content_digest(data)
		}
		valid := read_err == nil && i64(len(data)) == sqlite3_column_int64(statement, 1) && actual == hash
		delete(actual)
		delete(hash)
		if !valid {
			set_error(store, "blob integrity check failed")
			return .Integrity
		}
	}
	return .None
}
