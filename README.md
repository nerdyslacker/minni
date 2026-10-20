<div align="center">
<a href="https://github.com/nerdyslacker/minni"><img src="assets/minni.png" width="150"/></a>
</div>
<h1 align="center">minni</h1>
<div align="center">

[![License](https://img.shields.io/github/license/nerdyslacker/minni)](https://github.com/nerdyslacker/minni/blob/main/LICENSE)
[![GitHub release](https://img.shields.io/github/release/nerdyslacker/minni)](https://github.com/nerdyslacker/minni/releases)
<a href="https://app.commanddash.io/agent?github=https://github.com/nerdyslacker/minni"><img src="https://img.shields.io/badge/AI-Code%20Assist-EB9FDA"></a>
[![GitHub stars](https://img.shields.io/github/stars/nerdyslacker/minni)](https://github.com/nerdyslacker/minni/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/nerdyslacker/minni)](https://github.com/nerdyslacker/minni/fork)

</div>

minni is a standalone clipboard history project for Linux. The initial backend
targets X11 through XCB/XFixes.

It provides the `minnid` daemon and the `minni` CLI.

```sh
make check
make test
make
```

X11 integration tests require an isolated display:

```sh
Xephyr :101 -screen 1024x768 -ac -nolisten tcp
DISPLAY=:101 make test-x11 test-ipc-x11
```
