#!/usr/bin/env python3
"""Holds a lock file for one script run, or reports who holds it (script/lib/build-folder.sh).

    hold-lock.py wait  <lock file> <owner pid> <op>   waits for the lock, then holds it
    hold-lock.py try   <lock file> <owner pid> <op>   holds the lock only if it is free
    hold-lock.py query <lock file>                    says whether it is held, and by whom

wait prints "busy <holder>" when another run holds the lock and waits for it; try prints
"busy <holder>" and exits. Once this process holds the lock it prints "held", writes the
owner into the file and keeps the lock until the kernel reports the owner's exit, so a
killed owner or a reboot leaves nothing to reclaim. query prints "free" or "held <holder>"
and takes nothing: F_GETLK asks the kernel for a conflicting lock without acquiring one,
and on macOS it reports a flock(2) lock too.
"""
import fcntl
import os
import select
import struct
import sys

mode, lock_path = sys.argv[1], sys.argv[2]


def holder(lock):
    lock.seek(0)
    return lock.read().strip() or "holder=unknown"


if mode == "query":
    try:
        lock = open(lock_path)
    except FileNotFoundError:
        print("free")
        sys.exit(0)
    # macOS struct flock: off_t l_start, off_t l_len, pid_t l_pid, short l_type, short l_whence.
    request = struct.pack("qqihh", 0, 0, 0, fcntl.F_WRLCK, os.SEEK_SET)
    l_type = struct.unpack("qqihh", fcntl.fcntl(lock, fcntl.F_GETLK, request))[3]
    print("free" if l_type == fcntl.F_UNLCK else "held " + holder(lock))
    sys.exit(0)

owner, op = int(sys.argv[3]), sys.argv[4]
lock = open(lock_path, "a+")
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print("busy " + holder(lock), flush=True)
    if mode == "try":
        sys.exit(0)
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
