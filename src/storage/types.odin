package storage

Error_Code :: enum {
	None,
	Invalid_Input,
	Not_Found,
	Limit_Exceeded,
	IO,
	Database,
	Unsupported_Schema,
	Integrity,
}

Put_Result :: enum {
	Inserted,
	Deduplicated,
}

Clear_Scope :: enum {
	Unpinned,
	All,
}

Config :: struct {
	max_unpinned_items:  int,
	max_text_bytes:      i64,
	max_image_bytes:     i64,
	max_image_storage:   i64,
	max_age_seconds:     i64,
}

default_config :: proc() -> Config {
	return {
		max_unpinned_items = 100,
		max_text_bytes = 1024 * 1024,
		max_image_bytes = 20 * 1024 * 1024,
		max_image_storage = 200 * 1024 * 1024,
	}
}

Item_Input :: struct {
	selection_source: string,
	mime_type:        string,
	kind:             string,
	data:             []byte,
	created_at:       i64,
	last_used_at:     i64,
	label:            string,
	source_app:       string,
}

Item :: struct {
	id:               string,
	created_at:       i64,
	last_used_at:     i64,
	selection_source: string,
	mime_type:        string,
	kind:             string,
	byte_length:      i64,
	content_hash:     string,
	pinned:           bool,
	label:            string,
	preview_text:     string,
	thumbnail_ref:    string,
	source_app:       string,
}

Store :: struct {
	database:   ^SQLite_DB,
	state_dir:  string,
	database_path: string,
	blob_dir:   string,
	config:     Config,
	last_error: string,
}

destroy_item :: proc(item: ^Item) {
	if item == nil do return
	delete(item.id)
	delete(item.selection_source)
	delete(item.mime_type)
	delete(item.kind)
	delete(item.content_hash)
	delete(item.label)
	delete(item.preview_text)
	delete(item.thumbnail_ref)
	delete(item.source_app)
	item^ = {}
}

destroy_items :: proc(items: []Item) {
	for &item in items {
		destroy_item(&item)
	}
	delete(items)
}
