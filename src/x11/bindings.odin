package x11

Connection :: struct {}
Setup :: struct {}
Error :: struct {}
Cookie :: struct { sequence: u32 }

Screen :: struct {
	root, default_colormap, white_pixel, black_pixel, current_input_masks: u32,
	width_in_pixels, height_in_pixels, width_in_millimeters, height_in_millimeters: u16,
	min_installed_maps, max_installed_maps: u16,
	root_visual: u32,
	backing_stores, save_unders, root_depth, allowed_depths_len: u8,
}

Screen_Iterator :: struct { data: ^Screen, rem, index: i32 }
Generic_Event :: struct { response_type, pad0: u8, sequence: u16, pad: [7]u32 }
Query_Extension_Reply :: struct {
	response_type, pad0: u8,
	sequence: u16,
	length: u32,
	present, major_opcode, first_event, first_error: u8,
}
Intern_Atom_Reply :: struct {
	response_type, pad0: u8,
	sequence: u16,
	length, atom: u32,
}
Get_Property_Reply :: struct {
	response_type, format: u8,
	sequence: u16,
	length, type, bytes_after, value_len: u32,
	pad0: [12]u8,
}
Get_Selection_Owner_Reply :: struct {
	response_type, pad0: u8,
	sequence: u16,
	length, owner: u32,
}
Selection_Clear_Event :: struct {
	response_type, pad0: u8,
	sequence: u16,
	time, owner, selection: u32,
}
Selection_Request_Event :: struct {
	response_type, pad0: u8,
	sequence: u16,
	time, owner, requestor, selection, target, property: u32,
}
Selection_Notify_Event :: struct {
	response_type, pad0: u8,
	sequence: u16,
	time, requestor, selection, target, property: u32,
}
Property_Notify_Event :: struct {
	response_type, pad0: u8,
	sequence: u16,
	window, atom, time: u32,
	state: u8,
	pad1: [3]u8,
}
Destroy_Notify_Event :: struct {
	response_type, pad0: u8,
	sequence: u16,
	event, window: u32,
}
XFixes_Query_Version_Reply :: struct {
	response_type, pad0: u8,
	sequence: u16,
	length, major_version, minor_version: u32,
	pad1: [16]u8,
}
XFixes_Selection_Notify_Event :: struct {
	response_type, subtype: u8,
	sequence: u16,
	window, owner, selection, timestamp, selection_timestamp: u32,
	pad0: [8]u8,
}

#assert(size_of(Screen) == 40)
#assert(size_of(Generic_Event) == 32)
#assert(size_of(Query_Extension_Reply) == 12)
#assert(size_of(Intern_Atom_Reply) == 12)
#assert(size_of(Get_Property_Reply) == 32)
#assert(size_of(Get_Selection_Owner_Reply) == 12)
#assert(size_of(Selection_Clear_Event) == 16)
#assert(size_of(Selection_Request_Event) == 28)
#assert(size_of(Selection_Notify_Event) == 24)
#assert(size_of(Property_Notify_Event) == 20)
#assert(size_of(Destroy_Notify_Event) == 12)
#assert(size_of(XFixes_Query_Version_Reply) == 32)
#assert(size_of(XFixes_Selection_Notify_Event) == 32)

EVENT_DESTROY_NOTIFY   :: u8(17)
EVENT_PROPERTY_NOTIFY  :: u8(28)
EVENT_SELECTION_CLEAR  :: u8(29)
EVENT_SELECTION_REQUEST :: u8(30)
EVENT_SELECTION_NOTIFY :: u8(31)
PROPERTY_NEW_VALUE :: u8(0)
PROPERTY_DELETE    :: u8(1)
ATOM_NONE    :: u32(0)
ATOM_PRIMARY :: u32(1)
ATOM_ATOM    :: u32(4)
ATOM_INTEGER :: u32(19)
ATOM_STRING  :: u32(31)
CURRENT_TIME :: u32(0)
COPY_FROM_PARENT :: u32(0)
WINDOW_CLASS_INPUT_OUTPUT :: u16(1)
CW_EVENT_MASK :: u32(1 << 11)
EVENT_MASK_STRUCTURE_NOTIFY :: u32(1 << 17)
EVENT_MASK_PROPERTY_CHANGE :: u32(1 << 22)
PROP_MODE_REPLACE :: u8(0)
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
	xcb_generate_id :: proc(connection: ^Connection) -> u32 ---
	xcb_get_file_descriptor :: proc(connection: ^Connection) -> i32 ---
	xcb_get_maximum_request_length :: proc(connection: ^Connection) -> u32 ---
	xcb_create_window_checked :: proc(connection: ^Connection, depth: u8, window, parent: u32, x, y: i16, width, height, border_width, class: u16, visual, value_mask: u32, value_list: rawptr) -> Cookie ---
	xcb_destroy_window_checked :: proc(connection: ^Connection, window: u32) -> Cookie ---
	xcb_change_window_attributes_checked :: proc(connection: ^Connection, window, value_mask: u32, value_list: rawptr) -> Cookie ---
	xcb_query_extension :: proc(connection: ^Connection, name_len: u16, name: cstring) -> Cookie ---
	xcb_query_extension_reply :: proc(connection: ^Connection, cookie: Cookie, error: ^^Error) -> ^Query_Extension_Reply ---
	xcb_intern_atom :: proc(connection: ^Connection, only_if_exists: u8, name_len: u16, name: cstring) -> Cookie ---
	xcb_intern_atom_reply :: proc(connection: ^Connection, cookie: Cookie, error: ^^Error) -> ^Intern_Atom_Reply ---
	xcb_change_property_checked :: proc(connection: ^Connection, mode: u8, window, property, typ: u32, format: u8, data_len: u32, data: rawptr) -> Cookie ---
	xcb_delete_property_checked :: proc(connection: ^Connection, window, property: u32) -> Cookie ---
	xcb_get_property :: proc(connection: ^Connection, delete_property: u8, window, property, typ, long_offset, long_length: u32) -> Cookie ---
	xcb_get_property_reply :: proc(connection: ^Connection, cookie: Cookie, error: ^^Error) -> ^Get_Property_Reply ---
	xcb_get_property_value :: proc(reply: ^Get_Property_Reply) -> rawptr ---
	xcb_get_property_value_length :: proc(reply: ^Get_Property_Reply) -> i32 ---
	xcb_set_selection_owner_checked :: proc(connection: ^Connection, owner, selection, timestamp: u32) -> Cookie ---
	xcb_get_selection_owner :: proc(connection: ^Connection, selection: u32) -> Cookie ---
	xcb_get_selection_owner_reply :: proc(connection: ^Connection, cookie: Cookie, error: ^^Error) -> ^Get_Selection_Owner_Reply ---
	xcb_convert_selection_checked :: proc(connection: ^Connection, requestor, selection, target, property, timestamp: u32) -> Cookie ---
	xcb_send_event_checked :: proc(connection: ^Connection, propagate: u8, destination, event_mask: u32, event: rawptr) -> Cookie ---
	xcb_request_check :: proc(connection: ^Connection, cookie: Cookie) -> ^Error ---
	xcb_flush :: proc(connection: ^Connection) -> i32 ---
	xcb_poll_for_event :: proc(connection: ^Connection) -> ^Generic_Event ---
}

@(default_calling_convention = "c")
foreign xfixes {
	xcb_xfixes_query_version :: proc(connection: ^Connection, major, minor: u32) -> Cookie ---
	xcb_xfixes_query_version_reply :: proc(connection: ^Connection, cookie: Cookie, error: ^^Error) -> ^XFixes_Query_Version_Reply ---
	xcb_xfixes_select_selection_input_checked :: proc(connection: ^Connection, window, selection, event_mask: u32) -> Cookie ---
}

@(default_calling_convention = "c")
foreign libc {
	@(link_name = "free") free_c :: proc(pointer: rawptr) ---
}
