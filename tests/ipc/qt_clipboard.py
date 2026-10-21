#!/usr/bin/env python3
import pathlib
import sys

from PyQt6.QtCore import QMimeData, QTimer
from PyQt6.QtGui import QGuiApplication


operation, mime_type, path = sys.argv[1:4]
application = QGuiApplication([])
clipboard = application.clipboard()

if operation == "put":
    mime = QMimeData()
    mime.setData(mime_type, pathlib.Path(path).read_bytes())
    clipboard.setMimeData(mime)
    QTimer.singleShot(10000, application.quit)
    application.exec()
elif operation == "get":
    data = clipboard.mimeData().data(mime_type)
    pathlib.Path(path).write_bytes(bytes(data))
else:
    raise SystemExit(2)
