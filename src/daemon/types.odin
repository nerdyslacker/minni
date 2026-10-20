package daemon

import ipc "../ipc"
import storage "../storage"
import x11 "../x11"
import "core:sys/posix"

Wire_Item :: struct {
	id:               string `json:"id"`,
	schema_version:   int    `json:"schema_version"`,
	created_at:       i64    `json:"created_at"`,
	last_used_at:     i64    `json:"last_used_at"`,
	selection_source: string `json:"selection_source"`,
	mime_type:        string `json:"mime_type"`,
	kind:             string `json:"kind"`,
	byte_length:      i64    `json:"byte_length"`,
	content_hash:     string `json:"content_hash"`,
	pinned:           bool   `json:"pinned"`,
	label:            string `json:"label,omitempty"`,
	preview_text:     string `json:"preview_text,omitempty"`,
	thumbnail_ref:    string `json:"thumbnail_ref,omitempty"`,
	source_app:       string `json:"source_app,omitempty"`,
}

Hello_Result :: struct {
	version:      int      `json:"version"`,
	capabilities: []string `json:"capabilities"`,
}

Status_Result :: struct {
	backend:    string `json:"backend"`,
	paused:     bool   `json:"paused"`,
	item_count: int    `json:"item_count"`,
	byte_count: i64    `json:"byte_count"`,
}

List_Result :: struct {
	items:        []Wire_Item `json:"items"`,
	next_cursor:  string      `json:"next_cursor,omitempty"`,
	snapshot_seq: i64         `json:"snapshot_seq"`,
}

Item_Result :: struct {
	item: Wire_Item `json:"item"`,
}

Item_Id_Result :: struct {
	item_id:       string `json:"item_id"`,
	removed_count: int    `json:"removed_count,omitempty"`,
}

Count_Result :: struct {
	removed_count: int `json:"removed_count"`,
}

Capture_State_Result :: struct {
	paused: bool `json:"paused"`,
}

Subscribe_Result :: struct {
	subscribed:  bool `json:"subscribed"`,
	current_seq: i64  `json:"current_seq"`,
}

Protocol_Error :: struct {
	code:    string `json:"code"`,
	message: string `json:"message"`,
}

Response :: struct($T: typeid) {
	v:      int    `json:"v"`,
	id:     string `json:"id"`,
	ok:     bool   `json:"ok"`,
	seq:    i64    `json:"seq"`,
	result: T      `json:"result"`,
}

Error_Response :: struct {
	v:     int            `json:"v"`,
	id:    string         `json:"id"`,
	ok:    bool           `json:"ok"`,
	seq:   i64            `json:"seq"`,
	error: Protocol_Error `json:"error"`,
}

Item_Event_Data :: struct {
	item: Wire_Item `json:"item"`,
}

Item_Id_Event_Data :: struct {
	item_id: string `json:"item_id"`,
}

Count_Event_Data :: struct {
	removed_count: int `json:"removed_count"`,
}

Capture_State_Event_Data :: struct {
	paused: bool `json:"paused"`,
}

Resync_Event_Data :: struct {
	current_seq: i64 `json:"current_seq"`,
}

Event_Message :: struct($T: typeid) {
	v:     int    `json:"v"`,
	event: string `json:"event"`,
	seq:   i64    `json:"seq"`,
	data:  T      `json:"data"`,
}

Journal_Event :: struct {
	seq:     i64,
	payload: []byte,
}

State :: struct {
	store:         ^storage.Store,
	backend:       x11.Backend,
	backend_ready: bool,
	paused:        bool,
	sequence:      i64,
	listener:      posix.FD,
	socket_path:   string,
	clients:       [dynamic]^ipc.Client,
	journal:       [dynamic]Journal_Event,
}

wire_item :: proc(item: ^storage.Item) -> Wire_Item {
	return {
		id = item.id,
		schema_version = 1,
		created_at = item.created_at,
		last_used_at = item.last_used_at,
		selection_source = item.selection_source,
		mime_type = item.mime_type,
		kind = item.kind,
		byte_length = item.byte_length,
		content_hash = item.content_hash,
		pinned = item.pinned,
		label = item.label,
		preview_text = item.preview_text,
		thumbnail_ref = item.thumbnail_ref,
		source_app = item.source_app,
	}
}
