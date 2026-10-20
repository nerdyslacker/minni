#!/bin/sh
if ! pgrep -x minnid >/dev/null 2>&1; then
	minnid >/dev/null 2>&1 &
fi
