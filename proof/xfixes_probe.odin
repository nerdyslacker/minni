package main

import "core:fmt"
import "core:os"

Connection :: struct {}
Setup :: struct {}
Error :: struct {}
Cookie :: u32

Screen :: struct {
	root:                   u32,
	default_colormap:       u32,
	white_pixel:            u32,
	black_pixel:            u32,
	current_input_masks:    u32,
	width_in_pixels:        u16,
	height_in_pixels:       u16,
	width_in_millimeters:   u16,
	height_in_millimeters:  u16,
	min_installed_maps:     u16,
	max_installed_maps:     u16,
	root_visual:            u32,
	backing_stores:         u8,
	save_unders:            u8,
	root_depth:             u8,
	allowed_depths_len:     u8,
}

Screen_Iterator :: struct {
	data:  ^Screen,
	rem:   i32,
	index: i32,
}

Query_Extension_Reply :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	length:        u32,
	present:       u8,
	major_opcode:  u8,
	first_event:   u8,
	first_error:   u8,
}

Intern_Atom_Reply :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	length:        u32,
	atom:          u32,
}

XFixes_Query_Version_Reply :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	length:        u32,
	major_version: u32,
	minor_version: u32,
	pad1:          [16]u8,
}

Generic_Event :: struct {
	response_type: u8,
	pad0:          u8,
	sequence:      u16,
	pad:           [7]u32,
}

XFixes_Selection_Notify_Event :: struct {
	response_type:      u8,
	subtype:            u8,
	sequence:           u16,
	window:             u32,
	owner:              u32,
	selection:          u32,
	timestamp:          u32,
	selection_timestamp: u32,
	pad0:               [8]u8,
}

#assert(size_of(Screen) == 40)
#assert(size_of(Query_Extension_Reply) == 12)
#assert(size_of(Intern_Atom_Reply) == 12)
#assert(size_of(XFixes_Query_Version_Reply) == 32)
#assert(size_of(Generic_Event) == 32)
#assert(size_of(XFixes_Selection_Notify_Event) == 32)

XFIXES_SELECTION_MASK :: u32(1 | 2 | 4)

foreign import xcb "system:xcb"
foreign import xfixes "system:xcb-xfixes"
foreign import libc "system:c"

@(default_calling_convention = "c")
foreign xcb {
	xcb_connect :: proc(display: cstring, screen: ^i32) -> ^Connection ---
	xcb_connection_has_error :: proc(connection: ^Connection) -> i32 ---
	xcb_disconnect :: proc(connection: ^Connection) ---
	xcb_get_setup :: proc(connection: ^Connection) -> ^Setup ---
	xcb_setup_roots_iterator :: proc(setup: ^Setup) -> Screen_Iterator ---
	xcb_screen_next :: proc(iterator: ^Screen_Iterator) ---
	xcb_query_extension :: proc(connection: ^Connection, name_len: u16, name: cstring) -> Cookie ---
	xcb_query_extension_reply :: proc(connection: ^Connection, cookie: Cookie, error: ^^Error) -> ^Query_Extension_Reply ---
	xcb_intern_atom :: proc(connection: ^Connection, only_if_exists: u8, name_len: u16, name: cstring) -> Cookie ---
	xcb_intern_atom_reply :: proc(connection: ^Connection, cookie: Cookie, error: ^^Error) -> ^Intern_Atom_Reply ---
	xcb_request_check :: proc(connection: ^Connection, cookie: Cookie) -> ^Error ---
	xcb_flush :: proc(connection: ^Connection) -> i32 ---
	xcb_wait_for_event :: proc(connection: ^Connection) -> ^Generic_Event ---
}

@(default_calling_convention = "c")
foreign xfixes {
	xcb_xfixes_query_version :: proc(connection: ^Connection, major, minor: u32) -> Cookie ---
	xcb_xfixes_query_version_reply :: proc(connection: ^Connection, cookie: Cookie, error: ^^Error) -> ^XFixes_Query_Version_Reply ---
	xcb_xfixes_select_selection_input_checked :: proc(connection: ^Connection, window, selection, event_mask: u32) -> Cookie ---
}

@(default_calling_convention = "c")
foreign libc {
	@(link_name = "free")
	free_c :: proc(pointer: rawptr) ---
}

atom :: proc(connection: ^Connection, name: string) -> (u32, bool) {
	error: ^Error
	reply := xcb_intern_atom_reply(
		connection,
		xcb_intern_atom(connection, 0, u16(len(name)), cstring(raw_data(name))),
		&error,
	)
	if error != nil {
		free_c(error)
	}
	if reply == nil {
		return 0, false
	}
	defer free_c(reply)
	return reply.atom, reply.atom != 0
}

main :: proc() {
	screen_number: i32
	connection := xcb_connect(nil, &screen_number)
	if connection == nil || xcb_connection_has_error(connection) != 0 {
		fmt.eprintln("cannot connect to DISPLAY")
		os.exit(1)
	}
	defer xcb_disconnect(connection)

	name := "XFIXES"
	error: ^Error
	extension := xcb_query_extension_reply(
		connection,
		xcb_query_extension(connection, u16(len(name)), cstring(raw_data(name))),
		&error,
	)
	if error != nil {
		free_c(error)
		fmt.eprintln("XFixes extension query failed")
		os.exit(1)
	}
	if extension == nil || extension.present == 0 {
		if extension != nil {
			free_c(extension)
		}
		fmt.eprintln("XFixes is unavailable")
		os.exit(1)
	}
	event_type := extension.first_event
	free_c(extension)

	error = nil
	version := xcb_xfixes_query_version_reply(
		connection,
		xcb_xfixes_query_version(connection, 6, 0),
		&error,
	)
	if error != nil {
		free_c(error)
		fmt.eprintln("XFixes version query failed")
		os.exit(1)
	}
	if version == nil {
		fmt.eprintln("XFixes version query failed")
		os.exit(1)
	}
	fmt.printf("XFixes %d.%d\n", version.major_version, version.minor_version)
	free_c(version)

	screens := xcb_setup_roots_iterator(xcb_get_setup(connection))
	for _ in 0 ..< screen_number {
		xcb_screen_next(&screens)
	}
	if screens.rem == 0 || screens.data == nil {
		fmt.eprintln("X screen is unavailable")
		os.exit(1)
	}

	clipboard, ok := atom(connection, "CLIPBOARD")
	if !ok {
		fmt.eprintln("cannot intern CLIPBOARD")
		os.exit(1)
	}
	request := xcb_xfixes_select_selection_input_checked(
		connection, screens.data.root, clipboard, XFIXES_SELECTION_MASK,
	)
	if request_error := xcb_request_check(connection, request); request_error != nil {
		free_c(request_error)
		fmt.eprintln("cannot subscribe to CLIPBOARD owner changes")
		os.exit(1)
	}
	xcb_flush(connection)
	fmt.printf("subscribed to CLIPBOARD on root 0x%x\n", screens.data.root)

	if len(os.args) < 2 || os.args[1] != "--watch" {
		return
	}
	fmt.println("watching; interrupt to stop")
	for {
		event := xcb_wait_for_event(connection)
		if event == nil {
			fmt.eprintln("X connection closed")
			os.exit(1)
		}
		if event.response_type & 0x7f == event_type {
			selection_event := (^XFixes_Selection_Notify_Event)(event)
			fmt.printf(
				"owner=0x%x subtype=%d timestamp=%d\n",
				selection_event.owner,
				selection_event.subtype,
				selection_event.timestamp,
			)
		}
		free_c(event)
	}
}
