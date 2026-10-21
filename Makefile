ODIN ?= odin
ODIN_FLAGS ?=
PREFIX ?= /usr/local
DESTDIR ?=
BINDIR ?= $(PREFIX)/bin
MANDIR ?= $(PREFIX)/share/man
DATADIR ?= $(PREFIX)/share/minni

.PHONY: all check test test-ipc test-ipc-x11 test-hardening test-release test-rofi test-x11 install uninstall clean

all: build/minnid build/minni

check:
	$(ODIN) check src/storage -no-entry-point
	$(ODIN) check src/media -no-entry-point
	$(ODIN) check src/x11 -no-entry-point
	$(ODIN) check src/clipboard -no-entry-point
	$(ODIN) check src/ipc -no-entry-point
	$(ODIN) check src/daemon -no-entry-point
	$(ODIN) check src/config -no-entry-point

test:
	$(ODIN) run tests/storage
	$(ODIN) run tests/x11_unit
	$(ODIN) run tests/media
	$(ODIN) run tests/config

test-x11: build/x11-test
	./tests/x11/integration.sh ./build/x11-test

test-ipc: build/minnid build/minni build/ipc-seed
	python3 tests/ipc/integration.py ./build/minnid ./build/minni ./build/ipc-seed

test-ipc-x11: build/minnid build/minni
	./tests/ipc/x11_integration.sh ./build/minnid ./build/minni

test-hardening: build/minnid build/minni build/ipc-seed
	python3 tests/hardening/integration.py ./build/minnid ./build/minni ./build/ipc-seed

test-release: build/minnid build/minni
	python3 tests/release/benchmark.py ./build/minnid ./build/minni

test-rofi:
	./tests/rofi/integration.sh

build/minnid: cmd/minnid/*.odin src/config/*.odin src/daemon/*.odin src/ipc/*.odin src/storage/*.odin src/x11/*.odin src/clipboard/*.odin src/media/*.odin
	mkdir -p build
	$(ODIN) build cmd/minnid -out:$@ $(ODIN_FLAGS)

build/minni: cmd/minni/*.odin src/ipc/*.odin
	mkdir -p build
	$(ODIN) build cmd/minni -out:$@ $(ODIN_FLAGS)

build/ipc-seed: tests/ipc/seed/main.odin src/storage/*.odin
	mkdir -p build
	$(ODIN) build tests/ipc/seed -out:$@ $(ODIN_FLAGS)

build/x11-test: tests/x11/main.odin src/x11/*.odin
	mkdir -p build
	$(ODIN) build tests/x11 -out:$@ $(ODIN_FLAGS)

install: all
	install -Dm755 build/minnid $(DESTDIR)$(BINDIR)/minnid
	install -Dm755 build/minni $(DESTDIR)$(BINDIR)/minni
	install -Dm755 contrib/rofi/minni-rofi $(DESTDIR)$(BINDIR)/minni-rofi
	install -Dm644 contrib/man/minnid.1 $(DESTDIR)$(MANDIR)/man1/minnid.1
	install -Dm644 contrib/man/minni.1 $(DESTDIR)$(MANDIR)/man1/minni.1
	install -Dm644 contrib/examples/minni.conf $(DESTDIR)$(DATADIR)/examples/minni.conf
	install -Dm755 contrib/runit/minnid/run $(DESTDIR)$(DATADIR)/runit/minnid/run
	install -Dm644 contrib/runit/minnid/environment $(DESTDIR)$(DATADIR)/runit/minnid/environment
	install -Dm755 contrib/xinit/minnid.sh $(DESTDIR)$(DATADIR)/xinit/minnid.sh

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/minnid $(DESTDIR)$(BINDIR)/minni $(DESTDIR)$(BINDIR)/minni-rofi
	rm -f $(DESTDIR)$(MANDIR)/man1/minnid.1 $(DESTDIR)$(MANDIR)/man1/minni.1
	rm -rf $(DESTDIR)$(DATADIR)

clean:
	rm -f build/minnid build/minnid-asan build/minni build/minni-asan
	rm -f build/ipc-seed build/media-test build/x11-test build/x11-test-asan
