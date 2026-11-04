#!/usr/bin/env python3
"""Write a layout manifest: relative path, type, size, allocated size, link count, link target.

The script reads no file contents. Usage: manifest.py <out.jsonl> <root> [<root> ...]
It walks each root to MAX_DEPTH levels, with at most MAX_ENTRIES entries.
It replaces the home folder with `~` and each email address with `<email>`.
`rules.py audit --manifest <out.jsonl>` lists the paths in the manifest that no rule covers.
"""
import json, os, re, stat, sys

MAX_DEPTH = 5
MAX_ENTRIES = 3000
HOME = os.path.expanduser("~")
EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")


def clean(text):
    return EMAIL.sub("<email>", text.replace(HOME, "~"))


def entry(path, root):
    st = os.lstat(path)
    kind = "link" if stat.S_ISLNK(st.st_mode) else "dir" if stat.S_ISDIR(st.st_mode) else "file"
    row = {
        "root": clean(root),
        "path": clean(os.path.relpath(path, root)),
        "type": kind,
        "bytes": st.st_size if kind == "file" else 0,
        "allocated": st.st_blocks * 512,
        "links": st.st_nlink,
        "mode": oct(st.st_mode & 0o777),
    }
    if kind == "link":
        row["target"] = clean(os.readlink(path))
    return row


with open(sys.argv[1], "w") as out:
    for root in sys.argv[2:]:
        root = os.path.expanduser(root)
        if not os.path.lexists(root):
            out.write(json.dumps({"root": clean(root), "missing": True}) + "\n")
            continue
        count, truncated = 0, False
        base_depth = root.rstrip("/").count("/")
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            depth = dirpath.rstrip("/").count("/") - base_depth
            if depth >= MAX_DEPTH:
                dirnames[:] = []
            for name in sorted(dirnames) + sorted(filenames):
                if count >= MAX_ENTRIES:
                    truncated = True
                    break
                try:
                    out.write(json.dumps(entry(os.path.join(dirpath, name), root)) + "\n")
                    count += 1
                except OSError:
                    pass
            if truncated:
                dirnames[:] = []
                break
        total = 0
        for dirpath, _, filenames in os.walk(root, followlinks=False):
            for name in filenames:
                try:
                    total += os.lstat(os.path.join(dirpath, name)).st_blocks * 512
                except OSError:
                    pass
        out.write(json.dumps({"root": clean(root), "summary": True, "entries": count, "truncated": truncated, "allocated_total": total}) + "\n")
