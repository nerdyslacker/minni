package ipc

import "core:sys/posix"

MAX_FRAME :: 1024 * 1024
VERSION :: 1

Args :: struct {
	min_version: i64     `json:"min_version"`,
	max_version: i64     `json:"max_version"`,
	item_id:     string  `json:"item_id"`,
	selection:   string  `json:"selection"`,
	scope:       string  `json:"scope"`,
	query:       string  `json:"query"`,
	limit:       int     `json:"limit"`,
	cursor:      string  `json:"cursor"`,
	pinned:      bool    `json:"pinned"`,
	after_seq:   i64     `json:"after_seq"`,
}

Request :: struct {
	v:    int     `json:"v"`,
	id:   string  `json:"id"`,
	op:   string  `json:"op"`,
	args: Args    `json:"args"`,
}

Reader :: struct {
	data: [dynamic]byte,
}

Client :: struct {
	fd:         posix.FD,
	reader:     Reader,
	out:        [dynamic]byte,
	out_offset: int,
	hello:      bool,
	subscribed: bool,
}

destroy_reader :: proc(reader: ^Reader) {
	delete(reader.data)
	reader^ = {}
}

destroy_client :: proc(client: ^Client) {
	if client == nil do return
	destroy_reader(&client.reader)
	delete(client.out)
	client^ = {}
}
