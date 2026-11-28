# An Immich sync stream read as slowly as the Store applies it times out

Date: 2026-11-13. Context: the test Immich server's account (about 95,000 assets) showed Connecting for
its whole first sync, then Offline, while its server was answering throughout.

## Evidence from the installed app

`script/logs.sh show` for the installed Otos during the first sync:

- `catalog.source.changes` applied 500 lines per batch; `execMs` grew from about 500 ms at the
  start to 7 s at 60,000 rows, with two batches of 54 s and 81 s.
- `catalog.immich.sync phase=failed` came twice in 15 minutes, both `NSURLErrorDomain -1001`
  ("The request timed out.") with `NSErrorFailingURLStringKey=https://<server>/api/sync/stream`;
  each set the account Offline.
- After PR #681 made each batch's folder lookups an index seek (and the status online while the
  pass runs), batches took 1.5–3.8 s and the stream still timed out after about two minutes,
  at 10:29:53 and 10:32:16. No single batch came near the 60 s request timeout.

## Reproduction

A local server writes JSON Lines as fast as the socket takes them (about 8 MB, chunked). A client
reads `URLSession.bytes(for:).lines` with `timeoutIntervalForRequest = 5` and pauses 2 s after
every 500 lines, as a batch apply does. No pause is longer than the timeout.

Result (macOS 27, Xcode 27.2):

```
client: 12000 lines at 50.76 seconds
client: failed after 12490 lines at 50.80 seconds: -1001
server: ended BrokenPipeError after 8033760 bytes
```

The server was still connected and blocked writing when the client's request timed out. So a
reader slower than the server makes URLSession stop reading the socket once its buffer is full,
and the request's idle timer then fires though the server is sending. The timeout is caused by
the reader's pace, not by any one pause or by the server.

Server (`server.py`, run as `python3 server.py <port>`):

```python
import http.server, sys, time
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type","application/jsonlines+json"); self.send_header("Transfer-Encoding","chunked"); self.end_headers()
        line = (b'{"type":"AssetV2","data":{"id":"' + b'x'*300 + b'"}}\n')
        sent=0
        try:
            for i in range(200000):
                chunk=line*10
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk)); sent+=len(chunk)
            self.wfile.write(b"0\r\n\r\n")
            print("server: finished", sent, flush=True)
        except Exception as e:
            print("server: ended", type(e).__name__, "after", sent, "bytes", flush=True)
    def log_message(self,*a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
```

Client (`client.swift`, built with `swiftc -O client.swift -o client`):

```swift
import Foundation
let config = URLSessionConfiguration.ephemeral
config.timeoutIntervalForRequest = 5
let session = URLSession(configuration: config)
let start = ContinuousClock.now
var count = 0
do {
    let (bytes, _) = try await session.bytes(from: URL(string: "http://127.0.0.1:\(CommandLine.arguments[1])/")!)
    for try await _ in bytes.lines {
        count += 1
        if count % 500 == 0 {
            // A slow batch apply: the consumer stops reading for 2 s, well under the 5 s timeout.
            try await Task.sleep(for: .seconds(2))
            print("client: \(count) lines at \(ContinuousClock.now - start)")
        }
    }
    print("client: finished \(count)")
} catch {
    print("client: failed after \(count) lines at \(ContinuousClock.now - start): \((error as NSError).code)")
}
```

## Conclusion

The stream's transfer must not wait on the Store. `ImmichClient.syncEvents` receives the stream
whole with `URLSession.download(for:)` into a temporary file at the network's pace, then parses
it from the file one line at a time; the sync applies and acknowledges batches as before, so a
crash or a failed pass still replays from the last acknowledged batch. A longer timeout was
rejected: it hides the cause and still fails once the backlog is large enough. An in-memory
buffer drained by a reader task was rejected: a first sync's stream is tens of megabytes.

Sources: Apple's `URLSessionConfiguration.timeoutIntervalForRequest` documentation (the timer
measures the wait for additional data); the experiment above.
