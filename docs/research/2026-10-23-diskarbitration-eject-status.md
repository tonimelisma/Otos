# How DiskArbitration reports a refused eject

Date: 2026-10-23. Before Otos ejects through DiskArbitration instead of
`NSWorkspace.unmountAndEjectDevice`, establish what a refusal looks like, so the outcome
is read from a typed status rather than from an error message.

## Question

`NSWorkspace.unmountAndEjectDevice` reports a held volume as `NSOSStatusErrorDomain -47`
(`fBsyErr`, observed 2026-09-13), and the code that read it fell back to matching
"in use" / "busy" in the localized description, which stops working in any other
language. What does DiskArbitration itself report?

## Measured

macOS 27.0.1 (Xcode 27.1 SDK). A 40 MB ExFAT scratch image (`hdiutil create -fs ExFAT`,
attached `-nobrowse`) with a file held open by the probe. The probe made one
`DASession` on a dispatch queue, took `DADiskCopyWholeDisk` of the volume's disk,
called `DADiskUnmount(whole, kDADiskUnmountOptionWhole)`, released the file, and called
it again, then `DADiskEject(whole, kDADiskEjectOptionDefault)`:

```text
unmount while held: status=0x0000C010 (49168) string=nil
unmount after release: success
eject: success
```

- A busy volume refuses with `0xC010`. `<mach/error.h>` defines
  `unix_err(errno)` as `err_kern | err_sub(3) | errno`, which is `0xC000 | EBUSY`: the
  dissenter carries the BSD error, as `DADissenterGetStatus`'s header comment says
  ("A BSD return code, if applicable, is encoded with unix_err()").
- `DADissenterGetStatusString` is `nil`, so there is no text to show; the alert's
  wording is Otos's, and a non-busy BSD error is named with `strerror`.
- DiskArbitration's own codes are `err_local | err_local_diskarbitration | n`
  (`DADissenter.h`, `0xF8DA0001`…`0xF8DA000C`); `kDAReturnBusy` (`0xF8DA0002`) is the
  arbitration-level busy and is treated the same.
- There is no user-cancel outcome: DiskArbitration shows no UI of its own.

## Conclusions

- `DiskEjector` unmounts the whole disk and then ejects it, and maps a dissenter's
  status: `unix_err(EBUSY)` or `kDAReturnBusy` is busy; anything else is a refusal
  carrying its status. No error text is read.
- `RemovableEjectOutcome.cancelled` goes: nothing produces it.
