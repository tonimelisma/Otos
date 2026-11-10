#!/usr/bin/env python3
"""Holds a build folder's lock for one script run (script/lib/build-folder.sh).

Arguments: the lock file, the owning script's pid, the owner's op name. Prints
"busy <holder>" when another run holds the lock, "held" once this one does, and then
keeps the lock until the kernel reports the owner's exit.
"""
import fcntl
import select
import sys

lock_path, owner, op = sys.argv[1], int(sys.argv[2]), sys.argv[3]
lock = open(lock_path, "a+")
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    lock.seek(0)
    print("busy " + (lock.read().strip() or "holder=unknown"), flush=True)
    fcntl.flock(lock, fcntl.LOCK_EX)
lock.seek(0)
lock.truncate()
lock.write(f"holder={owner} op={op}\n")
lock.flush()
print("held", flush=True)
sys.stdout.close()
queue = select.kqueue()
try:
    queue.control([select.kevent(owner, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)], 1, None)
except ProcessLookupError:
    pass  # The owner already exited; the lock goes with this process.
