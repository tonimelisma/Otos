#!/usr/bin/env python3
"""Pins script/lib/scorecard.py against synthetic log lines written in the app's real format.

Every line here is made up: no path, name or number comes from anyone's library. Run by
script/check.sh's fast gates; prints `op=scorecard-test phase=pass` when every case holds.
"""

import io
import json
import os
import sys
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
    line(4.3, "op=ui.mediaGrid.structuralApply phase=finish animationMs=0 commitMs=12 items=4900 scope=allMedia totalMs=40"),
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
        self.assertEqual(by_label["search searchMany"], (1400, "FAIL"))
        # The filter is timed from its intent, not from the wait for the options it chose from.
        self.assertEqual(by_label["filter video"], (800, "PASS"))
        self.assertNotIn("act liked", by_label)

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

    def test_a_matrix_puts_each_configuration_on_one_row(self):
        report, rows, _ = run(SESSION)
        out = io.StringIO()
        scorecard.print_matrix([{"report": report, "verdicts": rows}] * 2, ["floor(all off)", "none off"], out)
        lines = out.getvalue().splitlines()
        self.assertEqual(len(lines), 3)
        self.assertIn("allMedia#1", lines[0])
        self.assertIn("2300", lines[1])


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=0).result
    if result.wasSuccessful():
        print(f"op=scorecard-test phase=pass cases={result.testsRun}")
        sys.exit(0)
    print("op=scorecard-test phase=fail")
    sys.exit(1)
