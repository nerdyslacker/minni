ODIN ?= odin

.PHONY: all check test test-ipc test-ipc-x11 test-x11 probe clean

all: build/minnid build/minni

check:
	$(ODIN) check src/storage -no-entry-point
	$(ODIN) check src/media -no-entry-point
	$(ODIN) check src/x11 -no-entry-point
	$(ODIN) check src/clipboard -no-entry-point
	$(ODIN) check src/ipc -no-entry-point
	$(ODIN) check src/daemon -no-entry-point
	$(ODIN) check proof/xfixes_probe.odin -file

test:
	$(ODIN) run tests/storage
	$(ODIN) run tests/x11_unit
	$(ODIN) run tests/media

test-x11: build/x11-test
	./tests/x11/integration.sh ./build/x11-test

test-ipc: build/minnid build/minni build/ipc-seed
	python3 tests/ipc/integration.py ./build/minnid ./build/minni ./build/ipc-seed

test-ipc-x11: build/minnid build/minni
	./tests/ipc/x11_integration.sh ./build/minnid ./build/minni

build/minnid: cmd/minnid/*.odin src/daemon/*.odin src/ipc/*.odin src/storage/*.odin src/x11/*.odin src/clipboard/*.odin
	mkdir -p build
	$(ODIN) build cmd/minnid -out:$@

build/minni: cmd/minni/*.odin src/ipc/*.odin
	mkdir -p build
	$(ODIN) build cmd/minni -out:$@

build/ipc-seed: tests/ipc/seed/main.odin src/storage/*.odin
	mkdir -p build
	$(ODIN) build tests/ipc/seed -out:$@

build/x11-test: tests/x11/main.odin src/x11/*.odin
	mkdir -p build
	$(ODIN) build tests/x11 -out:$@

probe: build/xfixes-probe
	./build/xfixes-probe

build/xfixes-probe: proof/xfixes_probe.odin
	mkdir -p build
	$(ODIN) build $< -file -out:$@

clean:
	rm -f build/minnid build/minni build/ipc-seed build/xfixes-probe build/x11-test build/x11-test-asan
