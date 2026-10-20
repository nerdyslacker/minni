package storage

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

SCHEMA_VERSION :: 1

SCHEMA_V1 :: `
CREATE TABLE metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
) STRICT;
INSERT INTO metadata(key, value) VALUES ('event_sequence', '0');
CREATE TABLE blobs (
    hash TEXT PRIMARY KEY CHECK(length(hash) = 64),
    byte_length INTEGER NOT NULL CHECK(byte_length >= 0)
) STRICT;
CREATE TABLE items (
    id TEXT PRIMARY KEY CHECK(length(id) = 32),
    schema_version INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL,
    selection_source TEXT NOT NULL CHECK(selection_source IN ('clipboard', 'primary')),
    mime_type TEXT NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN ('text', 'image', 'uri_list')),
    byte_length INTEGER NOT NULL CHECK(byte_length >= 0),
    content_hash TEXT NOT NULL REFERENCES blobs(hash),
    pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0, 1)),
    label TEXT,
    preview_text TEXT,
    thumbnail_ref TEXT,
    source_app TEXT,
    flags TEXT NOT NULL DEFAULT '[]',
    UNIQUE(mime_type, content_hash)
) STRICT;
CREATE INDEX items_order ON items(pinned DESC, last_used_at DESC, id ASC);
CREATE INDEX items_evict ON items(pinned, last_used_at ASC, id ASC);
PRAGMA user_version = 1;
`

set_error :: proc(store: ^Store, message: string) {
	delete(store.last_error)
	store.last_error = strings.clone(message)
}

set_database_error :: proc(store: ^Store) -> Error_Code {
	if store.database != nil {
		message := string(sqlite3_errmsg(store.database))
		set_error(store, fmt.tprintf("sqlite(%d): %s", sqlite3_extended_errcode(store.database), message))
	} else {
		set_error(store, "sqlite database is unavailable")
	}
	return .Database
}

exec_sql :: proc(store: ^Store, sql: string) -> Error_Code {
	temp := context.temp_allocator
	query, alloc_err := strings.clone_to_cstring(sql, temp)
	if alloc_err != nil do return .IO
	error_message: cstring
	result := sqlite3_exec(store.database, query, nil, nil, &error_message)
	if result != SQLITE_OK {
		if error_message != nil {
			set_error(store, string(error_message))
			sqlite3_free(rawptr(error_message))
			return .Database
		}
		return set_database_error(store)
	}
	return .None
}

prepare :: proc(store: ^Store, sql: string) -> (^SQLite_Stmt, Error_Code) {
	statement: ^SQLite_Stmt
	if sqlite3_prepare_v2(store.database, cstring(raw_data(sql)), i32(len(sql)), &statement, nil) != SQLITE_OK {
		return nil, set_database_error(store)
	}
	return statement, .None
}

bind_text :: proc(store: ^Store, statement: ^SQLite_Stmt, index: i32, value: string) -> Error_Code {
	pointer := cstring("")
	if len(value) > 0 {
		pointer = cstring(raw_data(value))
	}
	if sqlite3_bind_text(statement, index, pointer, i32(len(value)), sqlite_transient()) != SQLITE_OK {
		return set_database_error(store)
	}
	return .None
}

bind_optional_text :: proc(store: ^Store, statement: ^SQLite_Stmt, index: i32, value: string) -> Error_Code {
	if len(value) == 0 {
		if sqlite3_bind_null(statement, index) != SQLITE_OK {
			return set_database_error(store)
		}
		return .None
	}
	return bind_text(store, statement, index, value)
}

column_string :: proc(statement: ^SQLite_Stmt, column: i32) -> string {
	if sqlite3_column_type(statement, column) == SQLITE_NULL {
		return ""
	}
	count := int(sqlite3_column_bytes(statement, column))
	if count == 0 do return ""
	pointer := sqlite3_column_text(statement, column)
	return strings.clone(string(pointer)[:count])
}

query_integer :: proc(store: ^Store, sql: string) -> (i64, Error_Code) {
	statement, err := prepare(store, sql)
	if err != .None do return 0, err
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {
		return 0, set_database_error(store)
	}
	return sqlite3_column_int64(statement, 0), .None
}

begin :: proc(store: ^Store) -> Error_Code {
	return exec_sql(store, "BEGIN IMMEDIATE")
}

commit :: proc(store: ^Store) -> Error_Code {
	return exec_sql(store, "COMMIT")
}

rollback :: proc(store: ^Store) {
	_ = exec_sql(store, "ROLLBACK")
}

secure_directory :: proc(path: string) -> bool {
	if !os.exists(path) && os.make_directory(path, os.perm(0o700)) != nil do return false
	info, err := os.lstat(path, context.temp_allocator)
	if err != nil || info.type != .Directory do return false
	return os.chmod(path, os.perm(0o700)) == nil
}

open_default :: proc(state_dir: string) -> (^Store, Error_Code) {
	return open(state_dir, default_config())
}

open :: proc(state_dir: string, config: Config) -> (^Store, Error_Code) {
	if len(state_dir) == 0 {
		return nil, .Invalid_Input
	}
	if !secure_directory(state_dir) {
		return nil, .IO
	}

	store := new(Store)
	store.state_dir = strings.clone(state_dir)
	alloc_err: runtime.Allocator_Error
	store.database_path, alloc_err = filepath.join({state_dir, "minni.db"})
	if alloc_err != nil {
		close(store)
		return nil, .IO
	}
	blob_root, root_err := filepath.join({state_dir, "blobs"})
	if root_err != nil || !secure_directory(blob_root) {
		delete(blob_root)
		close(store)
		return nil, .IO
	}
	store.blob_dir, alloc_err = filepath.join({blob_root, "sha256"})
	delete(blob_root)
	if alloc_err != nil {
		close(store)
		return nil, .IO
	}
	store.config = config
	if !secure_directory(store.blob_dir) {
		close(store)
		return nil, .IO
	}

	temp := context.temp_allocator
	path, path_err := strings.clone_to_cstring(store.database_path, temp)
	if path_err != nil {
		close(store)
		return nil, .IO
	}
	flags := SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX |
		SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_EXRESCODE
	if sqlite3_open_v2(path, &store.database, flags, nil) != SQLITE_OK {
		set_database_error(store)
		close(store)
		return nil, .Database
	}
	_ = os.chmod(store.database_path, os.perm(0o600))

	if sqlite3_libversion_number() < 3037000 {
		set_error(store, "SQLite 3.37 or newer is required")
		close(store)
		return nil, .Unsupported_Schema
	}
	if sqlite3_busy_timeout(store.database, 5000) != SQLITE_OK {
		close(store)
		return nil, .Database
	}
	pragmas := [4]string{
		"PRAGMA foreign_keys=ON",
		"PRAGMA journal_mode=WAL",
		"PRAGMA synchronous=FULL",
		"PRAGMA trusted_schema=OFF",
	}
	for pragma in pragmas {
		if err := exec_sql(store, pragma); err != .None {
			close(store)
			return nil, err
		}
	}

	version, err := query_integer(store, "PRAGMA user_version")
	if err != .None {
		close(store)
		return nil, err
	}
	if version > SCHEMA_VERSION {
		set_error(store, "database schema is newer than this minni build")
		close(store)
		return nil, .Unsupported_Schema
	}
	if version == 0 {
		if err = begin(store); err == .None {
			err = exec_sql(store, SCHEMA_V1)
		}
		if err == .None {
			err = commit(store)
		} else {
			rollback(store)
		}
		if err != .None {
			close(store)
			return nil, err
		}
	}
	secure_database_files(store)
	if err = integrity_check(store); err != .None {
		close(store)
		return nil, err
	}
	if err = cleanup_orphan_files(store); err != .None {
		close(store)
		return nil, err
	}
	return store, .None
}

secure_database_files :: proc(store: ^Store) {
	_ = os.chmod(store.database_path, os.perm(0o600))
	suffixes := [2]string{"-wal", "-shm"}
	for suffix in suffixes {
		path := fmt.tprintf("%s%s", store.database_path, suffix)
		if os.exists(path) {
			_ = os.chmod(path, os.perm(0o600))
		}
	}
}

close :: proc(store: ^Store) {
	if store == nil do return
	if store.database != nil {
		sqlite3_close_v2(store.database)
	}
	delete(store.state_dir)
	delete(store.database_path)
	delete(store.blob_dir)
	delete(store.last_error)
	free(store)
}
