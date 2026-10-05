#!/usr/bin/env python3
"""Restore symlinks encoded as XSym text files in the extracted Ingenic SDK."""

import sys
from pathlib import Path

for path in Path(sys.argv[1]).iterdir():
	if not path.is_file():
		continue
	data = path.read_bytes()
	if not data.startswith(b"XSym\n"):
		continue
	lines = data.splitlines()
	if len(lines) < 4:
		raise SystemExit(f"invalid XSym link record: {path}")
	target = lines[3].decode("utf-8").strip()
	if not target or "/" in target or target in (".", ".."):
		raise SystemExit(f"invalid XSym link target in {path}: {target!r}")
	path.unlink()
	path.symlink_to(target)
