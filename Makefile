ODIN ?= odin

.PHONY: check test test-x11 probe clean

check:
	$(ODIN) check src/storage -no-entry-point
	$(ODIN) check src/media -no-entry-point
	$(ODIN) check src/x11 -no-entry-point
	$(ODIN) check src/clipboard -no-entry-point
	$(ODIN) check proof/xfixes_probe.odin -file

test:
	$(ODIN) run tests/storage
	$(ODIN) run tests/x11_unit
	$(ODIN) run tests/media

test-x11: build/x11-test
	./tests/x11/integration.sh ./build/x11-test

build/x11-test: tests/x11/main.odin src/x11/*.odin
	mkdir -p build
	$(ODIN) build tests/x11 -out:$@

probe: build/xfixes-probe
	./build/xfixes-probe

build/xfixes-probe: proof/xfixes_probe.odin
	mkdir -p build
	$(ODIN) build $< -file -out:$@

clean:
	rm -f build/xfixes-probe build/x11-test build/x11-test-asan
