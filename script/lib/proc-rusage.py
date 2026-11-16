#!/usr/bin/env python3
"""Per-process resource counters from proc_pid_rusage(RUSAGE_INFO_V4), without root.

Usage:
  proc-rusage.py <pid> [<pid>...]   one JSON object per readable pid
  proc-rusage.py --all              every process this user may read (others are skipped
                                    and counted in one {"unreadable": n} line)

Each object: pid, command, cpu_user_ns, cpu_system_ns, diskio_read_bytes,
diskio_written_bytes, logical_written_bytes, resident_bytes, phys_footprint_bytes,
lifetime_max_phys_footprint_bytes, pageins, billed_energy_nj, interrupt_wakeups,
pkg_idle_wakeups. The counters are cumulative since the process started, so a survey
takes the difference between two readings. CPU times arrive in Mach absolute time units
and are converted with mach_timebase_info. The kernel reads another user's process only
for root, so root daemons (mds, fileproviderd's root half, kernel_task) are unreadable
here and reported as a count, never guessed.
"""

import ctypes
import ctypes.util
import json
import sys

RUSAGE_INFO_V4 = 4
PROC_ALL_PIDS = 1


class RusageInfoV4(ctypes.Structure):
    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
        ("ri_cpu_time_qos_default", ctypes.c_uint64),
        ("ri_cpu_time_qos_maintenance", ctypes.c_uint64),
        ("ri_cpu_time_qos_background", ctypes.c_uint64),
        ("ri_cpu_time_qos_utility", ctypes.c_uint64),
        ("ri_cpu_time_qos_legacy", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_initiated", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_interactive", ctypes.c_uint64),
        ("ri_billed_system_time", ctypes.c_uint64),
        ("ri_serviced_system_time", ctypes.c_uint64),
        ("ri_logical_writes", ctypes.c_uint64),
        ("ri_lifetime_max_phys_footprint", ctypes.c_uint64),
        ("ri_instructions", ctypes.c_uint64),
        ("ri_cycles", ctypes.c_uint64),
        ("ri_billed_energy", ctypes.c_uint64),
        ("ri_serviced_energy", ctypes.c_uint64),
        ("ri_interval_max_phys_footprint", ctypes.c_uint64),
        ("ri_runnable_time", ctypes.c_uint64),
    ]


class MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
libc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(RusageInfoV4)]
libc.proc_name.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
libc.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]

timebase = MachTimebase()
libc.mach_timebase_info(ctypes.byref(timebase))


def ns(ticks):
    return ticks * timebase.numer // timebase.denom


def reading(pid):
    info = RusageInfoV4()
    if libc.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(info)) != 0:
        return None
    name = ctypes.create_string_buffer(256)
    libc.proc_name(pid, name, 256)
    return {
        "pid": pid,
        "command": name.value.decode("utf-8", "replace"),
        "cpu_user_ns": ns(info.ri_user_time),
        "cpu_system_ns": ns(info.ri_system_time),
        "diskio_read_bytes": info.ri_diskio_bytesread,
        "diskio_written_bytes": info.ri_diskio_byteswritten,
        "logical_written_bytes": info.ri_logical_writes,
        "resident_bytes": info.ri_resident_size,
        "phys_footprint_bytes": info.ri_phys_footprint,
        "lifetime_max_phys_footprint_bytes": info.ri_lifetime_max_phys_footprint,
        "pageins": info.ri_pageins,
        "billed_energy_nj": info.ri_billed_energy,
        "interrupt_wakeups": info.ri_interrupt_wkups,
        "pkg_idle_wakeups": info.ri_pkg_idle_wkups,
    }


def all_pids():
    count = libc.proc_listpids(PROC_ALL_PIDS, 0, None, 0)
    buffer = (ctypes.c_int * (count * 2))()
    filled = libc.proc_listpids(PROC_ALL_PIDS, 0, buffer, ctypes.sizeof(buffer))
    return [pid for pid in buffer[: filled // ctypes.sizeof(ctypes.c_int)] if pid > 0]


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    if argv == ["--all"]:
        unreadable = 0
        for pid in all_pids():
            row = reading(pid)
            if row is None:
                unreadable += 1
            else:
                print(json.dumps(row))
        print(json.dumps({"unreadable": unreadable}))
        return 0
    status = 0
    for value in argv:
        row = reading(int(value))
        if row is None:
            print(f"op=proc-rusage phase=unreadable pid={value} errno={ctypes.get_errno()}", file=sys.stderr)
            status = 1
        else:
            print(json.dumps(row))
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
