# Minni

Minni is a standalone clipboard history project for Linux. The initial backend
targets X11 through XCB/XFixes; Wayland is a later adapter.

The repository contains the tested storage engine and X11 text clipboard
backend. Daemon, IPC, CLI, and image support are later phases.

```sh
make check
make test
make probe
./build/xfixes-probe --watch
```

X11 integration tests require an isolated display:

```sh
Xephyr :101 -screen 1024x768 -ac -nolisten tcp
DISPLAY=:101 make test-x11
```
