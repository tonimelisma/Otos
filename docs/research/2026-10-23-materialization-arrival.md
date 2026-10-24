# What reports a dataless file becoming local

Date: 2026-10-23. Plan 0106, increment 6. `FileMaterialization` requested a download
and then read `SF_DATALESS` every 250 ms until it cleared. The research note it cited
(2026-07-14) found that the provider exposes no transfer handle. The question here is
narrower: does anything report the moment the kernel clears the flag?

## Probe

A command-line probe, run against three dataless files in the owner's OneDrive
(`~/Library/CloudStorage/OneDrive-Personal`; two PNG QR codes and a 93,527-byte JPEG),
did four things at once:

1. `open(path, O_EVTONLY)` and a `DispatchSource` file-system-object source on that
   descriptor with every event (`attrib`, `write`, `extend`, `delete`, `rename`,
   `revoke`).
2. An FSEvents stream on the parent folder with file-level events and no latency.
3. A measurement-only sampler reading `SF_DATALESS` every 20 ms.
4. After one second, `FileManager.startDownloadingUbiquitousItem(at:)` — the request
   `FileMaterialization` makes.

The probe only requested downloads; it wrote nothing. The three files are now local
copies, as Otos's own enrichment would have made them.

## Results

```text
file 1 (PNG):  0.002 open O_EVTONLY  dataless after open=true
               1.275 requested
               3.327 vnode attrib  dataless=true
               3.327 vnode attrib  dataless=false
file 2 (PNG):  0.000 open O_EVTONLY  dataless after open=true
               1.254 requested
               2.975 vnode attrib ×3  dataless=true
               2.976 vnode attrib ×5  dataless=false
               2.984 sampler: SF_DATALESS cleared
file 3 (JPEG): 0.001 open O_EVTONLY  dataless after open=true
               1.724 requested
              19.087 vnode attrib  dataless=false
              19.090 vnode attrib  dataless=false
              19.091 sampler: SF_DATALESS cleared
              19.121 fsevent flags=0x1d400  dataless=false
```

(The first two runs ended early in a probe bug — a force-cast of FSEvents' C path
array — after the vnode events above were logged; the third run used CF types.)

- Opening the file with `O_EVTONLY` does not materialize it.
- The kernel clearing `SF_DATALESS` is delivered as a vnode attribute change, at the
  transition, ahead of the 20 ms sampler and ahead of FSEvents (by ~34 ms on file 3).
- Attribute events can also arrive just before the flag clears, so each event is a
  reason to read the flag, not proof of arrival.

## Decision

`FileMaterialization` waits on one doorbell, rung by the file's attribute changes
(`attributeChanges(of:)`, an `O_EVTONLY` vnode source) and by the re-request schedule;
each ring reads `SF_DATALESS`. It looks once after the watch is installed, so a flag
that cleared between the request and the watch is not missed. The re-request interval
(1 s background, 500 ms interactive) and the 120 s background deadline stay: the
provider acknowledges no request and reports no refusal, so asking again is the only
way to notice a dropped request. A file that cannot be opened for events is woken by
that schedule alone.
