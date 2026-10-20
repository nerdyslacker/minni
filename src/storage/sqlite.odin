package storage

import "core:c"

SQLite_DB :: struct {}
SQLite_Stmt :: struct {}

SQLITE_OK   :: i32(0)
SQLITE_ROW  :: i32(100)
SQLITE_DONE :: i32(101)

SQLITE_INTEGER :: i32(1)
SQLITE_TEXT    :: i32(3)
SQLITE_NULL    :: i32(5)

SQLITE_OPEN_READWRITE :: i32(0x00000002)
SQLITE_OPEN_CREATE    :: i32(0x00000004)
SQLITE_OPEN_FULLMUTEX :: i32(0x00010000)
SQLITE_OPEN_NOFOLLOW  :: i32(0x01000000)
SQLITE_OPEN_EXRESCODE :: i32(0x02000000)

foreign import sqlite "system:sqlite3"

@(default_calling_convention = "c")
foreign sqlite {
	sqlite3_libversion_number :: proc() -> i32 ---
	sqlite3_open_v2 :: proc(filename: cstring, database: ^^SQLite_DB, flags: i32, vfs: cstring) -> i32 ---
	sqlite3_close_v2 :: proc(database: ^SQLite_DB) -> i32 ---
	sqlite3_busy_timeout :: proc(database: ^SQLite_DB, milliseconds: i32) -> i32 ---
	sqlite3_extended_errcode :: proc(database: ^SQLite_DB) -> i32 ---
	sqlite3_errmsg :: proc(database: ^SQLite_DB) -> cstring ---
	sqlite3_exec :: proc(database: ^SQLite_DB, sql: cstring, callback, ctx: rawptr, error_message: ^cstring) -> i32 ---
	sqlite3_free :: proc(pointer: rawptr) ---
	sqlite3_prepare_v2 :: proc(database: ^SQLite_DB, sql: cstring, bytes: i32, statement: ^^SQLite_Stmt, tail: ^cstring) -> i32 ---
	sqlite3_step :: proc(statement: ^SQLite_Stmt) -> i32 ---
	sqlite3_finalize :: proc(statement: ^SQLite_Stmt) -> i32 ---
	sqlite3_reset :: proc(statement: ^SQLite_Stmt) -> i32 ---
	sqlite3_clear_bindings :: proc(statement: ^SQLite_Stmt) -> i32 ---
	sqlite3_bind_text :: proc(statement: ^SQLite_Stmt, index: i32, text: cstring, bytes: i32, destructor: rawptr) -> i32 ---
	sqlite3_bind_int :: proc(statement: ^SQLite_Stmt, index, value: i32) -> i32 ---
	sqlite3_bind_int64 :: proc(statement: ^SQLite_Stmt, index: i32, value: i64) -> i32 ---
	sqlite3_bind_null :: proc(statement: ^SQLite_Stmt, index: i32) -> i32 ---
	sqlite3_column_type :: proc(statement: ^SQLite_Stmt, column: i32) -> i32 ---
	sqlite3_column_text :: proc(statement: ^SQLite_Stmt, column: i32) -> cstring ---
	sqlite3_column_bytes :: proc(statement: ^SQLite_Stmt, column: i32) -> i32 ---
	sqlite3_column_int :: proc(statement: ^SQLite_Stmt, column: i32) -> i32 ---
	sqlite3_column_int64 :: proc(statement: ^SQLite_Stmt, column: i32) -> i64 ---
	sqlite3_changes :: proc(database: ^SQLite_DB) -> i32 ---
}

sqlite_transient :: proc() -> rawptr {
	return rawptr(~uintptr(0))
}
