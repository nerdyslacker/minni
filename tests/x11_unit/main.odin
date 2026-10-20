package main

import "core:fmt"
import "core:os"
import "core:time"
import x11 "../../src/x11"

main :: proc() {
	latin1 := []byte{0x41, 0xe9, 0xff}
	utf8_data := x11.latin1_to_utf8(latin1)
	defer delete(utf8_data)
	if string(utf8_data) != "Aéÿ" {
		fmt.eprintln("FAIL: STRING to UTF-8")
		os.exit(1)
	}

	encoded, ok := x11.utf8_to_latin1(utf8_data)
	defer delete(encoded)
	if !ok || len(encoded) != len(latin1) {
		fmt.eprintln("FAIL: UTF-8 to STRING")
		os.exit(1)
	}
	for value, index in latin1 {
		if encoded[index] != value {
			fmt.eprintln("FAIL: STRING round-trip")
			os.exit(1)
		}
	}

	non_latin := "աշխարհ"
	invalid, supported := x11.utf8_to_latin1(transmute([]byte)non_latin)
	if invalid != nil do delete(invalid)
	if supported {
		fmt.eprintln("FAIL: unrepresentable STRING accepted")
		os.exit(1)
	}

	backend := x11.Backend{}
	backend.config.transfer_timeout = time.Millisecond
	backend.receive.phase = .Data
	backend.receive.started = time.tick_now()
	time.sleep(2 * time.Millisecond)
	x11.tick(&backend)
	if backend.receive.phase != .Idle || backend.last_error != "clipboard transfer timed out" {
		fmt.eprintln("FAIL: stalled receive timeout")
		os.exit(1)
	}
	x11.deinit(&backend)
	fmt.println("X11 unit: 4 passed")
}
