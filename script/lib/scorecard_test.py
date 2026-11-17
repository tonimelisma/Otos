#!/usr/bin/env python3
"""Pins script/lib/scorecard.py against synthetic log lines written in the app's real format.

Every line here is made up: no path, name or number comes from anyone's library. Run by
script/check.sh's fast gates; prints `op=scorecard-test phase=pass` when every case holds.
"""

import io
import json
import os
import sys
import tempfile
import unittest

# No __pycache__ under script/: every file there is a script (script/ci-repo-shape.sh).
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scorecard  # noqa: E402

TARGETS = {
    "launch.firstGridMs": {"metric": "launch.firstGridMs", "maxMs": None},
    "click.smallScopeMs": {"metric": "click.smallScopeMs", "maxMs": 1000},
    "click.allMedia.firstMs": {"metric": "click.allMedia.firstMs", "maxMs": None},
    "click.returnMs": {"metric": "click.returnMs", "maxMs": 300},
    "query.resultMs": {"metric": "query.resultMs", "maxMs": 1000},
    "search.firstResultsMs": {"metric": "search.firstResultsMs", "maxMs": 1000},
    "search.completeMs": {"metric": "search.completeMs", "maxMs": None},
    "photo.stepMs": {"metric": "photo.stepMs", "maxMs": 1000},
    "act.resultMs": {"metric": "act.resultMs", "maxMs": 100},
    "stalls.count": {"metric": "stalls.count", "max": 0},
    "stalls.per10Min": {"metric": "stalls.per10Min", "max": 0},
    "mainThreadStalls.worstMs": {"metric": "mainThreadStalls.worstMs", "maxMs": 250},
}


def line(second, message, pid=100, image="/Applications/Otos.app/Contents/MacOS/Otos"):
    return json.dumps({
        "timestamp": f"2026-01-01 10:00:{second:06.3f}-0800",
        "eventMessage": message,
        "processID": pid,
        "processImagePath": image,
    })


SESSION = [
    line(0.0, "op=sessionStart session=S1 kind=prod"),
    line(0.4, "op=window.attached"),
    line(0.5, "op=catalog.database.open phase=finish migrations=0 ms=20"),
    line(1.0, "op=catalog.start phase=finish migrations=0 migrationsMs=0 ms=900"),
    line(1.2, "op=launch.firstGrid phase=applied applyMs=0 catalogMs=1000 emptyState=none items=40 ms=1200 scope=importBatch:7"),
    line(1.3, "op=process.memory phase=sample event=firstGrid footprintMB=300 peakFootprintMB=320 residentMB=400 freeMB=900 compressorMB=10 swapUsedMB=0 sqliteMB=20"),
    line(1.3, "op=process.usage phase=sample event=firstGrid cpuMs=1500 diskReadMB=50 diskWrittenMB=5"),
    line(2.0, "op=ui.sidebarSelectionToPaint phase=start scope=allMedia"),
    line(2.1, "op=projection.publish phase=start generation=1 projection=P scope=allMedia"),
    line(3.0, "op=catalog.store.stall phase=waited connection=main.reader.2 connectionMs=2500 endedDuringWait=1 idle=none "
              "lastResumed=none lastResumedAgoMs=none lockMs=0 operation=orderedAssetIDs running=1 snapshotMs=0 stallID=1 storeMs=0 waitMs=2500"),
    line(3.0, "op=catalog.store.stall.holders phase=waited holders=main.reader.1:txn9000ms:readSearchEmbeddings:SELECT_e.x kind=running part=1 parts=1 stallID=1"),
    line(3.0, "op=catalog.store.stall.holders phase=waited holders=main.reader.3:held4000ms-endedAgo10ms:samePhotoCandidates:SELECT_a.x,"
              "main.reader.4:held1200ms-endedAgo5ms:samePhotoCandidates:SELECT_a.x kind=ended part=1 parts=1 stallID=1"),
    line(4.0, "op=catalog.store.query.order phase=finish descriptor=scope=allMedia sort=bestDate:descending kinds=all rootCount=2 "
              "count=5000 stacks=read stackSpan=roots stackCandidates=10 stackReadMs=30 stackRuleMs=5 orderSqlMs=400 mapMs=60 "
              "waitMs=2500 execMs=500 lockMs=0 resumeMs=0 priority=userInitiated queryMs=3000"),
    line(4.1, "op=catalog.projection.window phase=finish assetCount=4900 assetOrderQueryMs=3000 collapseMs=4 equalityUs=90 "
              "filterOptionsMs=0 resolvedSidebarSelection=allMedia totalMs=3100"),
    line(4.1, "op=ui.state.apply phase=finish applyMs=2 delta=4860 intentScope=allMedia items=4900 scope=allMedia"),
    line(4.3, "op=ui.sidebarSelectionToPaint phase=finish ms=2300 scope=allMedia surface=grid"),
    line(4.3, "op=ui.mediaGrid.structuralApply phase=finish commitMs=12 items=4900 scope=allMedia totalMs=40"),
    line(5.0, "op=catalog.store.query.filterOptions phase=finish row=allMedia waitMs=10 execMs=700 queryMs=710"),
    line(5.5, "op=search.index phase=loaded count=900 from=file mappedMB=241 openMs=273 ms=280 slots=910 stateMs=1"),
    line(6.0, "op=ui.sidebarSelectionToPaint phase=start scope=places"),
    line(6.2, "op=ui.sidebarSelectionToPaint phase=abandoned ms=200 scope=places supersededBy=importBatch:7"),
    line(6.2, "op=ui.sidebarSelectionToPaint phase=start scope=importBatch:7"),
    line(6.6, "op=ui.sidebarSelectionToPaint phase=finish ms=400 scope=importBatch:7 surface=grid"),
    line(7.0, "op=mainThreadStall bracketedOp=applyStructure stallMs=250 stallID=1"),
    line(7.5, "op=catalog.store.writeWait phase=waited operation=applyEnrichmentBatch waitMs=900 execMs=40 priority=utility"),
    line(8.0, "op=process.memory phase=sample event=memoryPressure level=warning footprintMB=900 peakFootprintMB=950 freeMB=40"),
    line(9.0, "op=tour phase=config steps=full ablated=none idleSeconds=60 deadlineSeconds=120"),
    line(9.5, "op=tour phase=step index=1 kind=scope label=allMedia outcome=reported ms=2300 paintMs=2300 scope=allMedia first=true"),
    line(10.0, "op=process.usage phase=sample event=idleStart cpuMs=4000 diskReadMB=100 diskWrittenMB=10"),
    line(10.0, "op=catalog.store.use phase=sample event=idleStart busyMs=main.reader:5000,main.writer:300 "
               "holds=main.reader:readSearchEmbeddings:4000:2:3000,main.writer:applyEnrichmentBatch:300:6:90 transactions=8 changes=10 changeFacts=detail:9,images:3"),
    line(40.0, "op=process.usage phase=sample event=idleEnd cpuMs=7000 diskReadMB=160 diskWrittenMB=12"),
    line(40.0, "op=catalog.store.use phase=sample event=idleEnd busyMs=main.reader:9000,main.writer:400 "
               "holds=main.reader:readSearchEmbeddings:8000:3:4000,main.writer:applyEnrichmentBatch:400:8:90 transactions=11 changes=13 changeFacts=detail:12,images:3"),
    line(41.0, "op=tour phase=finish outcome=finished"),
]


def usage(second, event, cpu, read, page_ins, scope):
    return line(second, f"op=process.usage phase=sample event={event} cpuMs={cpu} diskReadMB={read} diskWrittenMB=5 "
                        f"pageIns={page_ins} scope={scope}")


# SESSION with the paint checkpoints of a build that logs page-ins, and the tour's restore
# of All Media after its idle window, paged back in: 1,480 page-ins across a 6.3 s paint.
PAGED_SESSION = SESSION[:7] + [
    SESSION[7], usage(2.0, "paintStart", 1500, 50, 100, "allMedia"),
] + SESSION[8:16] + [usage(4.3, "paint", 2400, 52, 112, "allMedia")] + SESSION[16:20] + [
    SESSION[20], usage(6.0, "paintStart", 2500, 52, 112, "places"),
    SESSION[21], SESSION[22], usage(6.2, "paintStart", 2510, 52, 112, "importBatch:7"),
    SESSION[23], usage(6.6, "paint", 2600, 52, 115, "importBatch:7"),
] + SESSION[24:-1] + [
    line(40.2, "op=ui.sidebarSelectionToPaint phase=start scope=allMedia"),
    usage(40.2, "paintStart", 7000, 160, 500, "allMedia"),
    line(46.5, "op=ui.sidebarSelectionToPaint phase=finish ms=6300 scope=allMedia surface=grid"),
    usage(46.5, "paint", 7451, 183, 1980, "allMedia"),
    line(46.6, "op=tour phase=finish outcome=finished"),
]


def run(lines, *extra):
    out = io.StringIO()
    events = scorecard.read_events(lines)
    start, body = scorecard.pick_session(events, installed=True)
    report = scorecard.analyse(body, start)
    rows = scorecard.verdicts(report, TARGETS)
    scorecard.print_report(report, rows, out)
    return report, rows, out.getvalue()


class ScorecardTests(unittest.TestCase):
    def test_fields_keep_values_that_hold_spaces(self):
        fields = scorecard.parse_fields("op=ui.state.apply phase=finish intentScope=importBatch(OtosKit.ImportBatchID(unixMilliseconds: 7)) items=3")
        self.assertEqual(fields["intentScope"], "importBatch(OtosKit.ImportBatchID(unixMilliseconds: 7))")
        self.assertEqual(fields["items"], "3")

    def test_launch_reads_each_milestone(self):
        report, _, _ = run(SESSION)
        launch = report["launch"]
        self.assertEqual(launch["windowAttachedMs"], 400)
        self.assertEqual(launch["firstGridMs"], 1200)
        self.assertEqual(launch["scopeKind"], "import")
        self.assertEqual(launch["items"], 40)

    def test_a_click_carries_its_breakdown(self):
        report, _, _ = run(SESSION)
        click = report["clicks"][0]
        self.assertEqual((click["kind"], click["first"], click["outcome"], click["ms"]), ("all media", True, "painted", 2300))
        self.assertEqual(click["beforeBuildMs"], 100)
        self.assertEqual(click["order"]["waitMs"], 2500)
        self.assertEqual(click["order"]["orderSqlMs"], 400)
        self.assertEqual(click["order"]["mapMs"], 60)
        self.assertEqual(click["order"]["stacks"], "read")
        self.assertEqual(click["windowReadStalls"], 1)
        self.assertEqual(click["worstWindowReadConnectionMs"], 2500)
        self.assertEqual(click["publish"]["totalMs"], 3100)
        self.assertEqual(click["stateApplyMs"], 2)
        self.assertEqual(click["gridApply"]["commitMs"], 12)
        self.assertTrue(click["filterOptions"]["afterPaint"])

    def test_an_abandoned_click_is_listed_and_a_return_is_not_first(self):
        report, _, text = run(SESSION)
        abandoned = report["clicks"][1]
        self.assertEqual((abandoned["outcome"], abandoned["supersededBy"]), ("abandoned", "importBatch:7"))
        self.assertFalse(report["clicks"][2]["first"])
        self.assertIn("supersededBy=importBatch:7", text)

    def test_stalls_name_their_holders_and_the_window_reads_they_held(self):
        report, _, _ = run(SESSION)
        stalls = report["stalls"]
        self.assertEqual(stalls["count"], 1)
        self.assertEqual(stalls["worstConnectionMs"], 2500)
        self.assertEqual(stalls["windowReadStalls"], 1)
        self.assertEqual(stalls["holders"]["readSearchEmbeddings"], (9000, 1))
        self.assertEqual(stalls["holders"]["samePhotoCandidates"], (4000, 2))
        self.assertEqual(stalls["mainThread"]["byOp"]["applyStructure"], (250, 1))
        self.assertEqual(stalls["writeWaits"]["byOp"]["applyEnrichmentBatch"], (900, 1))

    def test_a_holder_the_log_cut_short_is_not_counted(self):
        cut = [SESSION[0], line(3.0, "op=catalog.store.stall phase=waited connection=main.reader.2 connectionMs=1500 "
                                     "endedDuringWait=main.reader.1:held3000ms-endedAgo1ms:samePhotoCandidates:SELECT,main.reader.3:held9ms-endedAgo1ms:render<…>")]
        report, _, _ = run(cut)
        self.assertEqual(list(report["stalls"]["holders"]), ["samePhotoCandidates"])

    def test_memory_and_the_pressure_event_name_what_was_running(self):
        report, _, _ = run(SESSION)
        memory = report["memory"]
        self.assertEqual(memory["peakFootprintMB"], 950)
        self.assertEqual(memory["milestones"]["firstGrid"]["footprintMB"], 300)
        self.assertEqual((memory["searchMappedMB"], memory["searchLoadedFrom"], memory["searchOpenMs"]), (241, "file", 273))
        self.assertEqual(memory["searchIndexLoadedAtMs"], 5500)
        pressure = memory["pressure"][0]
        self.assertEqual((pressure["level"], pressure["lastClick"]), ("warning", "importBatch:7"))

    def test_the_idle_window_is_the_difference_between_its_checkpoints(self):
        report, _, _ = run(SESSION)
        idle = report["tour"]["idle"]
        self.assertEqual(idle["cpuMs"], 3000)
        self.assertEqual(idle["diskReadMB"], 60)
        self.assertEqual(idle["changesPerMinute"], 6.0)
        self.assertEqual(idle["changeFacts"], {"detail": 3})
        self.assertEqual(idle["busyMs"], {"main.reader": 4000, "main.writer": 100})
        self.assertFalse(idle["quiet"])
        self.assertEqual(report["resources"]["writer"], [["main.writer:applyEnrichmentBatch", 400, 8, 90]])

    def test_disk_read_is_split_by_the_owner_that_asked_for_it(self):
        mib = 1048576
        lines = [l for l in SESSION if "event=idleStart" not in l and "event=idleEnd" not in l] + [
            line(10.0, "op=process.usage phase=sample event=idleStart cpuMs=4000 diskReadMB=100 diskWrittenMB=10 pageIns=1000"),
            line(10.0, "op=catalog.store.reads phase=sample event=idleStart readKB=main.reader:10240,main.writer:1024 "
                       "top=main.reader:photoDescriptionCandidates:8192:4,main.reader:mediaAssets:2048:30"),
            line(12.0, f"op=contentHash phase=finish bytes={300 * mib} elapsedMs=300 owner=enrichment relativePath=a.mov rootPath=/r"),
            line(13.0, f"op=contentHash phase=finish bytes={100 * mib} elapsedMs=90 owner=enrichment relativePath=b.mov rootPath=/r"),
            line(14.0, f"op=contentHash phase=finish bytes={20 * mib} elapsedMs=20 owner=import relativePath=c.jpg rootPath=/r"),
            line(40.0, "op=process.usage phase=sample event=idleEnd cpuMs=7000 diskReadMB=600 diskWrittenMB=12 pageIns=1640"),
            line(40.0, "op=catalog.store.reads phase=sample event=idleEnd readKB=main.reader:61440,main.writer:2048 "
                       "top=main.reader:photoDescriptionCandidates:49152:9,main.reader:mediaAssets:4096:80"),
        ]
        report, _, text = run(lines)
        idle = report["resources"]["diskByOwner"]["idle"]
        by_owner = {row["owner"]: row["mb"] for row in idle["rows"]}
        self.assertEqual(idle["totalMB"], 500)
        self.assertEqual(by_owner["originals hashed: enrichment"], 400)
        self.assertEqual(by_owner["originals hashed: import"], 20)
        self.assertEqual(by_owner["catalog pages: main.reader"], 50)
        self.assertEqual(by_owner["catalog pages: main.writer"], 1)
        # 640 page-ins of 16 KiB.
        self.assertEqual(by_owner["page-ins: mapped files, models, frameworks"], 10)
        self.assertEqual(idle["notAttributedMB"], 500 - 400 - 20 - 50 - 1 - 10)
        self.assertEqual(idle["catalogTop"][0], ["main.reader:photoDescriptionCandidates", 40, 5])
        self.assertIn("DISK READ BY OWNER", text)
        self.assertIn("originals hashed: enrichment", text)

    def test_disk_read_by_owner_says_when_a_build_logs_no_catalog_reads(self):
        report, _, text = run(SESSION)
        idle = report["resources"]["diskByOwner"]["idle"]
        self.assertFalse(idle["catalogMeasured"])
        self.assertIn("no op=catalog.store.reads line", text)

    def test_verdicts_compare_each_number_with_its_target(self):
        _, rows, _ = run(SESSION)
        by_label = {r["label"]: r["verdict"] for r in rows}
        self.assertEqual(by_label["first all media"], "NO-TARGET")
        # A return to any view is held to the return target, not the first visit's.
        self.assertEqual(by_label["return import"], "FAIL")
        self.assertEqual(by_label["store stall lines"], "FAIL")
        self.assertEqual(by_label["worst main-thread stall ms"], "PASS")

    def test_stalls_are_counted_per_ten_minutes_of_session(self):
        report, rows, text = run(SESSION)
        # One stall line in a 41 s session.
        self.assertEqual(report["stalls"]["per10Min"], round(600 / 41.0, 1))
        self.assertIn("per 10 minutes", text)
        self.assertEqual({r["label"]: r["verdict"] for r in rows}["store stall lines per 10 minutes"], "FAIL")

    def test_query_and_photo_steps_are_held_to_their_targets(self):
        steps = SESSION[:-1] + [
            line(40.5, "op=tour phase=step index=20 kind=photo label=open outcome=reported ms=300 local=0 storedPreview=4"),
            line(40.6, "op=tour phase=step index=25 kind=search label=searchMany outcome=reported ms=1500 resultMs=1400 items=9"),
            line(40.7, "op=tour phase=step index=28 kind=filter label=video outcome=reported ms=2500 resultMs=800 optionsWaitMs=1700"),
            line(40.8, "op=tour phase=step index=29 kind=act label=liked outcome=skipped ms=0 reason=notSandboxHome"),
            SESSION[-1],
        ]
        _, rows, _ = run(steps)
        by_label = {r["label"]: (r["value"], r["verdict"]) for r in rows}
        self.assertEqual(by_label["photo open"], (300, "PASS"))
        # A build older than the first-results number: the complete answer is still reported,
        # and the first results are no data, never the complete time renamed.
        self.assertEqual(by_label["search first searchMany complete"], (1400, "NO-TARGET"))
        self.assertEqual(by_label["search first searchMany first results"], (None, "NO-DATA"))
        # The filter is timed from its intent, not from the wait for the options it chose from.
        self.assertEqual(by_label["filter video"], (800, "PASS"))
        self.assertNotIn("act liked", by_label)

    def test_a_search_reports_its_first_results_against_the_target_and_its_complete_time_apart(self):
        steps = SESSION[:-1] + [
            line(40.6, "op=tour phase=step index=25 kind=search label=searchMany outcome=reported ms=2600 "
                       "firstMs=420 firstItems=11 resultMs=2582 items=433"),
            line(40.7, "op=tour phase=step index=26 kind=search label=searchFew outcome=reported ms=300 "
                       "firstMs=1200 firstItems=3 resultMs=1200 items=3"),
            line(40.8, "op=tour phase=step index=28 kind=sort label=name outcome=reported ms=500 "
                       "firstMs=500 resultMs=500 items=900"),
            SESSION[-1],
        ]
        _, rows, text = run(steps)
        by_label = {r["label"]: (r["value"], r["target"], r["verdict"]) for r in rows}
        self.assertEqual(by_label["search first searchMany first results"], (420, "1000", "PASS"))
        self.assertEqual(by_label["search first searchMany complete"], (2582, "none", "NO-TARGET"))
        # A later search's first results are its answer when nothing came before it.
        self.assertEqual(by_label["search again searchFew first results"], (1200, "1000", "FAIL"))
        self.assertEqual(by_label["search again searchFew complete"], (1200, "none", "NO-TARGET"))
        # A sort has one number, held to the query target.
        self.assertEqual(by_label["sort name"], (500, "1000", "PASS"))
        self.assertIn("search first searchMany first resu", text)

    def test_a_step_that_reached_its_deadline_fails_and_a_scroll_counts_tiles_without_thumbnails(self):
        steps = SESSION[:-1] + [
            line(40.5, "op=tour phase=step index=10 kind=scroll label=down outcome=deadline ms=120060 position=300"),
            line(40.6, "op=tour phase=step index=11 kind=scroll label=down outcome=reported ms=225 position=600 visible=22 withoutThumbnail=4 thumbnailsMs=92"),
            SESSION[-1],
        ]
        _, rows, _ = run(steps)
        by_label = {r["label"]: (r["value"], r["verdict"]) for r in rows}
        self.assertEqual(by_label["step 10 scroll down deadline"], (120060, "FAIL"))
        self.assertEqual(by_label["scroll down 600 tiles without thumbnail"], (4, "NO-TARGET"))

    def test_an_act_is_timed_from_its_intent_to_the_grid(self):
        acted = SESSION[:-1] + [
            line(40.1, "op=ui.actToResult phase=start act=liked count=1"),
            line(40.2, "op=ui.actToResult phase=finish act=liked count=1 surface=grid ms=40"),
            line(40.3, "op=ui.actToResult phase=start act=moveToTrash count=1"),
            line(40.4, "op=ui.actToResult phase=abandoned act=moveToTrash ms=90 supersededBy=disliked"),
            line(40.5, "op=ui.actToResult phase=start act=disliked count=1"),
            line(40.7, "op=ui.actToResult phase=finish act=disliked count=1 surface=grid ms=180"),
            SESSION[-1],
        ]
        report, rows, text = run(acted)
        self.assertEqual([(a["act"], a["outcome"], a["ms"]) for a in report["acts"]],
                         [("liked", "shown", 40), ("moveToTrash", "abandoned", 90), ("disliked", "shown", 180)])
        by_label = {r["label"]: r["verdict"] for r in rows}
        self.assertEqual((by_label["act liked"], by_label["act disliked"]), ("PASS", "FAIL"))
        self.assertIn("ACT TO RESULT", text)
        self.assertFalse(any("act to result" in item for item in report["notMeasured"]))
        report, _, _ = run(SESSION)
        self.assertTrue(any("act to result" in item for item in report["notMeasured"]))

    def test_trash_and_put_back_report_the_visible_result_and_the_file_work_apart(self):
        acted = SESSION[:-1] + [
            line(40.00, "op=trash.move phase=start batch=11 count=1"),
            line(40.00, "op=ui.actToResult phase=start act=moveToTrash count=1"),
            line(40.05, "op=ui.actToResult phase=finish act=moveToTrash count=1 surface=grid ms=50"),
            line(40.30, "op=mediaTrash.queue phase=trashed path=a.jpg members=1 batch=11"),
            line(40.40, "op=trash.undo phase=start count=1 batch=11"),
            line(40.40, "op=ui.actToResult phase=start act=putBack count=1"),
            line(40.60, "op=mediaTrash.undo phase=finish batch=11 restored=1 failed=0"),
            line(40.65, "op=ui.actToResult phase=finish act=putBack count=1 surface=grid ms=250"),
            SESSION[-1],
        ]
        report, rows, text = run(acted)
        trash, put_back = report["acts"]
        self.assertEqual((trash["ms"], trash["completedMs"]), (50, 300))
        self.assertEqual((put_back["ms"], put_back["completedMs"]), (250, 200))
        by_label = {r["label"]: (r["value"], r["verdict"]) for r in rows}
        self.assertEqual(by_label["act moveToTrash"], (50, "PASS"))
        self.assertEqual(by_label["act moveToTrash file work done"], (300, "NO-TARGET"))
        self.assertEqual(by_label["act putBack"], (250, "FAIL"))
        self.assertIn("fileWorkDoneMs=300", text)

    def test_the_newest_session_of_the_asked_build_is_read(self):
        dev = "/Users/someone/build/DerivedData/Build/Products/Debug/Otos.app/Contents/MacOS/Otos"
        lines = SESSION + [line(50.0, "op=sessionStart session=D1 kind=prod", pid=200, image=dev)]
        events = scorecard.read_events(lines)
        self.assertEqual(scorecard.pick_session(events, installed=True)[0].fields["session"], "S1")
        self.assertEqual(scorecard.pick_session(events, installed=False)[0].fields["session"], "D1")

    def test_an_old_build_says_what_it_cannot_measure(self):
        report, _, _ = run(SESSION[:5])
        self.assertTrue(any("process.memory" in item for item in report["notMeasured"]))

    def test_the_derived_folder_counters_are_the_sessions_disk(self):
        counted = ("files=7 bytes=10485760 thumbnailFiles=4 thumbnailBytes=1048576 previewFiles=3 previewBytes=9437184 "
                   "faceFramesFiles=0 faceFramesBytes=0 otherFiles=0 otherBytes=0")
        lines = SESSION[:-1] + [line(40.2, f"op=derived.folder phase=counted source=counters {counted}"), SESSION[-1]]
        report, rows, text = run(lines)
        self.assertEqual(report["disk"]["folderMB"], 10)
        self.assertEqual(report["disk"]["files"]["preview"], 3)
        self.assertIsNone(report["disk"]["reconciled"])
        self.assertEqual({r["label"]: r["value"] for r in rows}["derived folder MB"], 10)
        self.assertIn("no reconciliation was owed", text)
        reconciled = SESSION[:-1] + [
            line(40.1, "op=derived.reconcile phase=finish reason=uncleanExit removedFiles=3 removedBytes=3145728 rows=7 ms=40"),
            line(40.2, f"op=derived.folder phase=counted source=census {counted}"),
            SESSION[-1],
        ]
        report, _, text = run(reconciled)
        self.assertEqual((report["disk"]["reconciled"], report["disk"]["removedFiles"], report["disk"]["removedMB"]),
                         ("uncleanExit", 3, 3))
        self.assertIn("reconciled (uncleanExit)", text)
        report, _, _ = run(SESSION)
        self.assertIsNone(report["disk"])

    def test_each_paint_carries_what_the_process_paid_between_its_checkpoints(self):
        report, rows, text = run(PAGED_SESSION)
        warm = report["clicks"][0]
        self.assertEqual(warm["usage"], {"cpuMs": 900, "diskReadMB": 2, "diskWrittenMB": 0, "pageIns": 12})
        self.assertNotIn("pagedIn", warm)
        # The abandoned click has no paint, so no cost of its own; the next paint pairs with
        # its own start, not the abandoned one's.
        self.assertIsNone(report["clicks"][1]["usage"])
        self.assertEqual(report["clicks"][2]["usage"]["pageIns"], 3)
        paged = report["clicks"][3]
        self.assertEqual((paged["usage"]["pageIns"], paged["pagedIn"]), (1480, 1480))
        self.assertIn("pagedIn=1480", text)
        self.assertIn("pageIns=12]", text)

    def test_a_paged_in_mark_never_changes_a_verdict(self):
        _, rows, _ = run(PAGED_SESSION)
        after_idle = [r for r in rows if r["label"] == "return after idle all media"][0]
        self.assertEqual((after_idle["value"], after_idle["pagedIn"]), (6300, 1480))
        # No target is set for a return after idle; the mark does not make it a PASS or excuse a FAIL.
        self.assertEqual(after_idle["verdict"], "NO-TARGET")
        targets = dict(TARGETS, **{"click.returnAfterIdleMs": {"metric": "click.returnAfterIdleMs", "maxMs": 300}})
        report = scorecard.analyse(*reversed(scorecard.pick_session(scorecard.read_events(PAGED_SESSION))))
        failed = [r for r in scorecard.verdicts(report, targets) if r["label"] == "return after idle all media"][0]
        self.assertEqual(failed["verdict"], "FAIL")

    def test_the_return_after_the_idle_window_is_reported_apart_from_warm_returns(self):
        report, rows, text = run(PAGED_SESSION)
        self.assertEqual([c["visit"] for c in report["clicks"]], ["first", "first", "return", "returnAfterIdle"])
        by_metric = {}
        for row in rows:
            by_metric.setdefault(row["metric"], []).append(row["label"])
        self.assertEqual(by_metric["click.returnMs"], ["return import"])
        self.assertEqual(by_metric["click.returnAfterIdleMs"], ["return after idle all media"])
        self.assertIn("return after idle", text)
        # Without an idle window every return is a warm one.
        report, rows, _ = run([l for l in PAGED_SESSION if "idleEnd" not in l])
        self.assertEqual(report["clicks"][3]["visit"], "return")

    def test_a_build_without_the_paint_checkpoints_reads_unknown_never_zero(self):
        report, _, text = run(SESSION)
        self.assertTrue(all(c["usage"] is None for c in report["clicks"]))
        self.assertIn("pageIns=-]", text)
        self.assertTrue(any("page-ins" in item for item in report["notMeasured"]))
        # A usage line without pageIns: the other counters still differ, page-ins stay unknown.
        idle = report["tour"]["idle"]
        self.assertEqual((idle["cpuMs"], idle["pageIns"]), (3000, None))

    def test_the_script_compares_with_a_saved_scorecard_older_than_its_fields(self):
        directory = tempfile.mkdtemp()
        log = os.path.join(directory, "session.ndjson")
        targets = os.path.join(directory, "targets.json")
        saved = os.path.join(directory, "saved.json")
        with open(log, "w", encoding="utf-8") as handle:
            handle.write("\n".join(PAGED_SESSION) + "\n")
        with open(targets, "w", encoding="utf-8") as handle:
            json.dump({"targets": list(TARGETS.values())}, handle)
        # An older scorecard: its rows carry no pagedIn, and it called the restore a plain return.
        with open(saved, "w", encoding="utf-8") as handle:
            json.dump({"report": {"session": "OLD"}, "verdicts": [
                {"metric": "click.returnMs", "label": "return import", "value": 500, "target": "300", "verdict": "FAIL"},
                {"metric": "click.returnMs", "label": "return all media", "value": 6000, "target": "300", "verdict": "FAIL"},
            ]}, handle)
        out = io.StringIO()
        stdout, sys.stdout = sys.stdout, out
        try:
            scorecard.main(["--input", log, "--targets", targets, "--compare", saved])
        finally:
            sys.stdout = stdout
        compared = out.getvalue().split("COMPARED WITH OLD")[1]
        self.assertIn("return import", compared)
        self.assertRegex(compared, r"return after idle all media\s+- →\s+6300  -  pagedIn - → 1480")
        for path in (log, targets, saved):
            os.remove(path)
        os.rmdir(directory)

    def test_a_matrix_puts_each_configuration_on_one_row(self):
        report, rows, _ = run(SESSION)
        out = io.StringIO()
        scorecard.print_matrix([{"report": report, "verdicts": rows}] * 2, ["floor(all off)", "none off"], out)
        lines = out.getvalue().splitlines()
        self.assertEqual(len(lines), 3)
        self.assertIn("allMedia#1", lines[0])
        self.assertIn("2300", lines[1])

    def test_a_long_idle_is_waited_out_and_the_limit_follows_the_configuration(self):
        # A 420 s idle with a 600 s step deadline: the step's wait is the longest silence.
        self.assertEqual(scorecard.tour_silence_limit(420, 600), 600 + scorecard.TOUR_SILENCE_MARGIN_SECONDS)
        # A 420 s idle with the default deadline: the idle is, and it is never cut.
        self.assertGreater(scorecard.tour_silence_limit(420, 120), 420)
        self.assertGreater(scorecard.tour_silence_limit(0, 120), 120)
        out = io.StringIO()
        stdout, sys.stdout = sys.stdout, out
        try:
            scorecard.main(["--tour-silence-limit", "420", "600"])
        finally:
            sys.stdout = stdout
        self.assertEqual(out.getvalue().strip(), str(600 + scorecard.TOUR_SILENCE_MARGIN_SECONDS))

    def test_memory_says_when_the_peak_came_and_which_step_ran_then(self):
        def memory_sample(second, peak, event="tourStep"):
            return line(second, f"op=process.memory phase=sample event={event} footprintMB={peak - 10} peakFootprintMB={peak} freeMB=500")

        tour = SESSION[:-1] + [
            line(42.0, "op=tour phase=step index=2 kind=search label=searchMany outcome=reported ms=900 items=10 resultMs=900"),
            memory_sample(42.1, 960),
            line(44.0, "op=tour phase=step index=3 kind=sort label=name outcome=reported ms=1800 items=4900 resultMs=1800"),
            memory_sample(44.1, 1200),
            memory_sample(46.0, 1200, event="tourFinish"),
            line(46.0, "op=tour phase=finish outcome=finished"),
        ]
        report, _, text = run(tour)
        peak = report["memory"]["peak"]
        self.assertEqual(peak, {
            "footprintMB": 1200, "atMs": 44100, "afterMs": 42100, "sample": "tourStep",
            "afterStep": "2:search/searchMany", "duringStep": "3:sort/name",
        })
        self.assertEqual(report["memory"]["peakFootprintMB"], 1200)
        self.assertIn("peak 1200 MB reached by 44100 ms (sample tourStep), after 42100 ms; "
                      "tour step finished before it 2:search/searchMany, running 3:sort/name", text)
        # Saved and read back as JSON like any other field.
        self.assertEqual(json.loads(json.dumps(report, default=str))["memory"]["peak"], peak)

    def test_a_peak_before_the_tour_names_the_first_step_as_running(self):
        report, _, _ = run(SESSION)
        peak = report["memory"]["peak"]
        self.assertEqual((peak["atMs"], peak["afterMs"], peak["sample"]), (8000, 1300, "memoryPressure"))
        self.assertEqual((peak["afterStep"], peak["duringStep"]), (None, "1:scope/allMedia"))


class SessionKindTests(unittest.TestCase):
    """A launch tour's numbers are under the launch's own load; a settled tour's are what a
    person's session meets. The scorecard labels which, and compares only like with like."""

    LAUNCH = SESSION[:-1] + [line(46.6, "op=tour phase=finish outcome=finished")]

    @staticmethod
    def settled(by="loadsDrained"):
        tour = [e for e in SESSION[:-1] if '"op=tour phase=config' not in e]
        return tour + [
            line(1.25, "op=tour phase=config ablated=none deadlineSeconds=120 idleSeconds=60 start=settled steps=full"),
            line(1.4, f"op=tour phase=settled by={by} waitMs=41000"),
            line(46.6, "op=tour phase=finish outcome=finished"),
        ]

    def test_each_kind_is_labelled(self):
        report, _, text = run(self.settled())
        self.assertEqual(report["sessionKind"], "settled")
        self.assertIn("kind=settled", text.splitlines()[0])
        self.assertIn("the tour waited 41000 ms for the launch to settle: by loadsDrained", text)
        self.assertEqual(run(self.settled("deadline"))[0]["sessionKind"], "settled(deadline)")
        # A config line without start is an older build's: it toured at launch.
        self.assertEqual(run(self.LAUNCH)[0]["sessionKind"], "launch")

    def compare_text(self, current, saved_report):
        report, rows, _ = run(current)
        out = io.StringIO()
        compared = scorecard.compare(report, rows, {"report": saved_report, "verdicts": rows}, out)
        return compared, out.getvalue()

    def test_two_kinds_are_never_compared(self):
        compared, text = self.compare_text(self.settled(), {"session": "OLD", "sessionKind": "launch"})
        self.assertFalse(compared)
        self.assertIn("NOT COMPARED WITH OLD: this session is settled, that one launch", text)
        compared, text = self.compare_text(self.LAUNCH, {"session": "OLD", "sessionKind": "settled"})
        self.assertFalse(compared)
        # An older saved scorecard, from before settled tours, is a launch tour's.
        compared, _ = self.compare_text(self.LAUNCH, {"session": "OLD"})
        self.assertTrue(compared)
        compared, _ = self.compare_text(self.settled(), {"session": "OLD"})
        self.assertFalse(compared)
        compared, text = self.compare_text(self.settled(), {"session": "OLD", "sessionKind": "settled"})
        self.assertTrue(compared)
        self.assertIn("COMPARED WITH OLD (both settled)", text)

    def test_owners_never_quiescent_are_named_with_what_they_did(self):
        lines = self.LAUNCH[:-1] + [
            line(46.0, "op=owners.status phase=sessionEnd owners=14 pending=descriptions,searchIndex quiescent=12"),
            line(46.0, "op=owners.pending phase=sessionEnd holdsWork=false owedRequests=1 owner=descriptions passes=1 "
                       "reads=12 rows=3000 runningPasses=1 unactedChanges=0 wake=none written=212"),
            line(46.0, "op=owners.pending phase=sessionEnd holdsWork=true owedRequests=0 owner=searchIndex passes=3 "
                       "reads=40 rows=900 runningPasses=0 unactedChanges=2 wake=backoff+500ms written=0"),
            line(46.6, "op=tour phase=finish outcome=finished"),
        ]
        report, _, text = run(lines)
        self.assertEqual([p["owner"] for p in report["ownersAtEnd"]["pending"]], ["descriptions", "searchIndex"])
        self.assertIn("owners never quiescent: at sessionEnd 12 of 14 were", text)
        self.assertIn("descriptions: running 1 pass (written 212 so far), owed 1 requests", text)
        self.assertIn("searchIndex: 2 store changes not acted on, holding work in flight, wake backoff+500ms", text)
        # A session with no status line says so, never a bare dash.
        self.assertIn("owners never quiescent; which and why not measured (no op=owners.status line)", run(self.LAUNCH)[2])

    def test_a_settled_tour_waits_out_its_settle_deadline_before_it_is_stuck(self):
        self.assertEqual(scorecard.tour_silence_limit(60, 120, 900), 900 + scorecard.TOUR_SILENCE_MARGIN_SECONDS)
        self.assertEqual(scorecard.tour_silence_limit(60, 120), scorecard.tour_silence_limit(60, 120, 0))


class SandboxTrashTests(unittest.TestCase):
    """A sandbox library's teardown tests the account's Trash for each generated file by name
    (script/sandbox-library.sh check-trash). A folder stands in for the Trash here."""

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="otos-scorecard-test-")
        self.trash = os.path.join(self.folder, "Trash")
        os.mkdir(self.trash)
        self.names = os.path.join(self.folder, "names")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.folder)
        self.assertFalse(os.path.exists(self.folder))

    def check(self, names):
        with open(self.names, "w", encoding="utf-8") as handle:
            handle.write("".join(n + "\n" for n in names))
        out = io.StringIO()
        status = scorecard.report_trash_leftovers(self.names, self.trash, out)
        return status, out.getvalue()

    def test_a_clean_trash_passes_without_touching_anything_else(self):
        other = os.path.join(self.trash, "someone-elses.jpg")
        open(other, "w").close()
        status, text = self.check(["otos-tour-abc-00000.jpg", "otos-tour-abc-00001.jpg"])
        self.assertEqual(status, 0)
        self.assertIn("phase=clean tested=2 leftovers=0 unknown=0", text)
        self.assertTrue(os.path.exists(other))

    def test_a_leftover_is_removed_named_and_fails_the_teardown(self):
        leftover = os.path.join(self.trash, "otos-tour-abc-00001.jpg")
        open(leftover, "w").close()
        status, text = self.check(["otos-tour-abc-00000.jpg", "otos-tour-abc-00001.jpg"])
        self.assertEqual(status, 1)
        self.assertIn("phase=leftover name=otos-tour-abc-00001.jpg removed=true", text)
        self.assertIn("phase=FAILED tested=2 leftovers=1", text)
        self.assertFalse(os.path.exists(leftover))

    def test_a_trash_that_cannot_be_tested_is_never_read_as_clean(self):
        def denied(_path):
            raise PermissionError("denied")
        self.assertEqual(scorecard.trash_presence("otos-tour-abc-00000.jpg", self.trash, lstat=denied), "unknown")
        removed, unknown = scorecard.trash_leftovers(["otos-tour-abc-00000.jpg"], self.trash, lstat=denied)
        self.assertEqual((removed, unknown), ([], ["otos-tour-abc-00000.jpg"]))
        # A name that is not a plain file name is never joined onto the Trash's path.
        for name in ("../escape.jpg", "a/b.jpg", "..", ""):
            self.assertEqual(scorecard.trash_presence(name, self.trash), "unknown")

    def test_a_leftover_that_cannot_be_removed_is_reported_not_cleaned(self):
        leftover = os.path.join(self.trash, "otos-tour-abc-00002.jpg")
        open(leftover, "w").close()

        def refuse(_path):
            raise PermissionError("denied")
        removed, unknown = scorecard.trash_leftovers(["otos-tour-abc-00002.jpg"], self.trash, remove=refuse)
        self.assertEqual((removed, unknown), ([], ["otos-tour-abc-00002.jpg"]))


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=0).result
    if result.wasSuccessful():
        print(f"op=scorecard-test phase=pass cases={result.testsRun}")
        sys.exit(0)
    print("op=scorecard-test phase=fail")
    sys.exit(1)
