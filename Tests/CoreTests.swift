// Lightweight test runner (the machine has Command Line Tools only, so no XCTest/SwiftPM).
// Build & run with: scripts/test.sh
import Foundation

var failures = 0
var passes = 0

func check(_ cond: @autoclosure () -> Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if cond() { passes += 1 } else { failures += 1; print("  ✗ \(msg)  (line \(line))") }
}

func test(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch { failures += 1; print("  ✗ threw \(error)") }
}

func tempVault() -> VaultLayout {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("floatask-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return VaultLayout(vault: dir)
}

func date(_ s: String) -> Date { Dates.parseISO(s)! }

@main
struct TestMain {
    static func main() {
        test("task line round-trip keeps untouched lines byte-for-byte") {
            let text = """
            ---
            schema_version: 1
            ---

            # Tasks

            Some intro paragraph the user wrote.

            - [ ] Finish landing page · due 2026-10-02 · high #design <!-- id:t_1 created:2026-09-29T10:10:00+06:00 -->
            \tComplete the desktop layout.
            \t- [x] Hero section <!-- id:t_2 done:2026-09-29T11:00:00+06:00 -->
            \t- [ ] Footer <!-- id:t_3 -->
            - [ ] Typed in Obsidian without id
            * [/] Odd bullet and mark <!-- id:t_4 -->

            ## Acme

            - [ ] Brochure <!-- id:t_5 -->
            """
            let doc = TasksDocument.parse(text)
            check(doc.serialize() == text + "\n", "serialize == original")
            let items = doc.items()
            check(items.count == 6, "6 tasks, got \(items.count)")
            let first = items[0]
            check(first.title == "Finish landing page", "title parsed: \(first.title)")
            check(first.due == "2026-10-02" && first.priority == .high && first.tags == ["design"], "meta parsed")
            check(first.notes == "Complete the desktop layout.", "notes parsed: \(first.notes)")
            check(items[1].parentId == "t_1" && items[1].depth == 1 && items[1].isDone, "subtask nesting")
            check(items[3].hasPersistedId == false && items[3].id.hasPrefix("tmp_"), "temp id for id-less")
            check(items[4].isDone == false, "[/] is not done")
            check(items[5].group == "Acme" && items[0].group == nil, "groups")
        }

        test("modified line is re-serialised canonically") {
            var doc = TasksDocument.parse("- [ ] Draft #a · low <!-- id:x -->\n")
            _ = doc.modify("x") { $0.setDone(true, at: date("2026-09-30T09:00:00+06:00")); $0.setDue("2026-10-01") }
            let out = doc.serialize()
            check(out.hasPrefix("- [x] Draft · due 2026-10-01 · low #a <!-- id:x done:2026-09-30T"), "canonical: \(out)")
            let again = TasksDocument.parse(out).items()[0]
            check(again.isDone && again.due == "2026-10-01" && again.tags == ["a"] && again.priority == .low, "re-parse")
        }

        test("titles containing separators and comments are sanitised") {
            let t = TaskLine.clean("A · B <!-- evil --> \n C")
            check(!t.contains("<!--") && !t.contains(" · ") && !t.contains("\n"), "clean: \(t)")
        }

        test("service: add, nest, complete cascade, reopen") {
            let layout = tempVault()
            let svc = try TaskService(layout: layout)
            let now = date("2026-09-30T10:00:00+06:00")
            let a = try svc.addTask(title: "Launch website", now: now)
            let b = try svc.addTask(title: "Write copy", parentId: a, now: now)
            let c = try svc.addTask(title: "Ship", parentId: a, now: now)
            _ = try svc.addTask(title: "Brochure", group: "Acme", due: "2026-10-01", now: now)
            check(svc.snapshot.tasks.count == 4, "4 tasks")
            check(svc.snapshot.task(b)?.parentId == a, "b under a")
            try svc.setDone(b, true, now: now)
            check(svc.snapshot.task(a)?.isDone == false, "parent still open")
            try svc.setDone(c, true, now: now)
            check(svc.snapshot.task(a)?.isDone == true, "parent auto-completes")
            try svc.setDone(b, false, now: now)
            check(svc.snapshot.task(a)?.isDone == false, "parent reopens")
            let p = svc.snapshot.progress(now: now)
            check(p.done == 1 && p.total == 4, "progress \(p)")
            let file = try String(contentsOf: layout.tasks, encoding: .utf8)
            check(file.contains("## Acme") && file.contains("\t- [ ] Write copy"), "file layout:\n\(file)")
        }

        test("service: external id-less task gets id when used") {
            let layout = tempVault()
            let svc = try TaskService(layout: layout)
            try (TaskService.tasksTemplate + "- [ ] From Obsidian\n").write(to: layout.tasks, atomically: true, encoding: .utf8)
            check(svc.hasExternalChanges(), "detects external change")
            try svc.reload()
            let tmp = svc.snapshot.tasks[0].id
            check(tmp.hasPrefix("tmp_"), "temp id")
            try svc.toggle(tmp)
            check(svc.snapshot.tasks[0].hasPersistedId && svc.snapshot.tasks[0].isDone, "persisted + done")
            check(!svc.hasExternalChanges(), "own write not external")
        }

        test("service: checked in Obsidian gets a done stamp") {
            let layout = tempVault()
            let svc = try TaskService(layout: layout)
            try (TaskService.tasksTemplate + "- [x] Done elsewhere <!-- id:t_z -->\n").write(to: layout.tasks, atomically: true, encoding: .utf8)
            let stamped = try svc.stampExternalCompletions(); check(stamped, "stamped")
            check(svc.snapshot.tasks[0].completedAt != nil, "has completedAt")
        }

        test("rollover archives yesterday's finished trees only") {
            let layout = tempVault()
            let svc = try TaskService(layout: layout)
            let yesterday = date("2026-09-29T16:00:00+06:00")
            let today = date("2026-09-30T09:00:00+06:00")
            let a = try svc.addTask(title: "Old done", group: "Work", now: yesterday)
            let b = try svc.addTask(title: "Parent", now: yesterday)
            let b1 = try svc.addTask(title: "Child done", parentId: b, now: yesterday)
            _ = try svc.addTask(title: "Child open", parentId: b, now: yesterday)
            let c = try svc.addTask(title: "Done today", now: today)
            try svc.setDone(a, true, now: yesterday)
            try svc.setDone(b1, true, now: yesterday)
            try svc.setDone(c, true, now: today)
            // Visible list hides nothing but the fully done yesterday tree.
            let visible = svc.snapshot.visibleTasks(now: today).map(\.title)
            check(!visible.contains("Old done") && !visible.contains("Child done") && visible.contains("Parent") && visible.contains("Done today"), "visible: \(visible)")
            let moved = try svc.rollover(now: today)
            check(moved == 1, "moved \(moved)")
            check(svc.snapshot.task(a) == nil && svc.snapshot.task(c) != nil, "a archived, c kept")
            let archive = try String(contentsOf: layout.archive(month: "2026-09"), encoding: .utf8)
            check(archive.contains("## 2026-09-29") && archive.contains("Old done") && archive.contains("group:Work"), "archive:\n\(archive)")
            let completed = svc.completedTasks(now: today).map(\.title)
            check(completed.contains("Old done") && completed.contains("Done today"), "history completed: \(completed)")
            let again = try svc.rollover(now: today); check(again == 0, "idempotent")
        }

        test("focus: timestamps drive the timer, pause/resume, completion while closed") {
            let layout = tempVault()
            let svc = try TaskService(layout: layout)
            let t0 = date("2026-09-30T15:30:00+06:00")
            let task = try svc.addTask(title: "Finish landing page", now: t0)
            try svc.startFocus(taskId: task, minutes: 25, now: t0)
            let active = svc.snapshot.active!
            check(active.remainingSeconds(at: t0.addingTimeInterval(750)) == 750, "12:30 left")
            try svc.pauseFocus(now: t0.addingTimeInterval(600))
            check(svc.snapshot.active!.remainingSeconds(at: t0.addingTimeInterval(1200)) == 900, "paused freezes")
            try svc.resumeFocus(now: t0.addingTimeInterval(900))   // paused 5 min
            // Simulate a restart: new service instance reading the same vault.
            let svc2 = try TaskService(layout: layout)
            check(svc2.snapshot.active?.remainingSeconds(at: t0.addingTimeInterval(1000)) == 800, "recovered")
            let event = try svc2.reconcileFocus(now: t0.addingTimeInterval(4000))
            if case .completed(let s)? = event {
                check(s.actualSeconds == 1500, "actual 1500")
                check(s.endedAt == t0.addingTimeInterval(1800), "ended at start+planned+paused")
            } else { check(false, "should complete") }
            check(svc2.snapshot.active == nil && svc2.snapshot.focusSeconds[task] == 1500, "focus time attributed")
        }

        test("focus: finish early, short sessions discarded, adjust bounds") {
            let layout = tempVault()
            let svc = try TaskService(layout: layout)
            let t0 = date("2026-09-30T10:00:00+06:00")
            try svc.startFocus(taskId: nil, minutes: 25, now: t0)
            try svc.resetFocus(now: t0.addingTimeInterval(30))
            check(svc.snapshot.sessions.isEmpty, "short reset discarded")
            try svc.startFocus(taskId: nil, minutes: 25, now: t0)
            try svc.adjustFocus(byMinutes: -30, now: t0.addingTimeInterval(600))
            check(svc.snapshot.active!.plannedMinutes == 11, "floor = elapsed+1 → \(svc.snapshot.active!.plannedMinutes)")
            try svc.adjustFocus(byMinutes: 500, now: t0.addingTimeInterval(600))
            check(svc.snapshot.active!.plannedMinutes == 120, "max 120")
            try svc.finishFocus(now: t0.addingTimeInterval(900))
            let s = svc.snapshot.sessions[0]
            check(s.status == .endedEarly && s.actualSeconds == 900, "ended early 900s")
        }

        test("completing the focused task stops the session") {
            let layout = tempVault()
            let svc = try TaskService(layout: layout)
            let t0 = date("2026-09-30T10:00:00+06:00")
            let task = try svc.addTask(title: "X", now: t0)
            try svc.startFocus(taskId: task, minutes: 25, now: t0)
            try svc.setDone(task, true, now: t0.addingTimeInterval(300))
            check(svc.snapshot.active == nil && svc.snapshot.sessions.first?.actualSeconds == 300, "stopped")
        }

        test("sessions file round-trip with quoting") {
            var s = FocusSession(id: "fs_1", taskId: "t_1", taskTitle: "Say \"hi\": now", startedAt: date("2026-09-29T15:30:00+06:00"),
                                 endedAt: date("2026-09-29T15:55:00+06:00"), plannedMinutes: 25, actualSeconds: 1500, status: .completed)
            s.note = "ok"
            let text = SessionsDocument.serialize([s])
            let back = SessionsDocument.parse(text)
            check(back.skipped == 0 && back.sessions.first == s, "round trip:\n\(text)")
        }

        test("settings round-trip keeps body") {
            let layout = tempVault()
            let svc = try TaskService(layout: layout)
            var st = svc.snapshot.settings
            st.defaultFocusMinutes = 50
            st.theme = "dark"
            try svc.updateSettings(st)
            check(svc.snapshot.settings.defaultFocusMinutes == 50 && svc.snapshot.settings.theme == "dark", "saved")
            let text = try String(contentsOf: layout.settings, encoding: .utf8)
            check(text.contains("# Task Manager Settings"), "body kept")
        }

        test("natural dates") {
            let wed = date("2026-09-30T10:00:00+06:00")   // a Wednesday
            check(NaturalDate.find(in: "finish brochure before Thursday", now: wed)?.day == "2026-10-01", "thursday")
            check(NaturalDate.find(in: "call mum tomorrow", now: wed)?.day == "2026-10-01", "tomorrow")
            check(NaturalDate.find(in: "review on wed", now: wed)?.day == "2026-10-07", "same weekday → next week")
            check(NaturalDate.find(in: "in 3 days", now: wed)?.day == "2026-10-03", "in 3 days")
            check(NaturalDate.find(in: "due Oct 12", now: wed)?.day == "2026-10-12", "oct 12")
            check(NaturalDate.find(in: "next week", now: wed)?.day == "2026-10-05", "next week monday")
            check(NaturalDate.find(in: "plain task", now: wed) == nil, "none")
        }

        test("up next: order key, file-order fallback, subtasks stay with parent") {
            let text = """
            - [ ] A <!-- id:t_a -->
            	- [ ] A1 <!-- id:t_a1 -->
            - [ ] B <!-- id:t_b order:2 -->

            ## Work

            - [ ] C <!-- id:t_c order:1 -->
            - [ ] D <!-- id:t_d -->
            """
            let items = TasksDocument.parse(text).items()
            check(items.first { $0.id == "t_c" }?.order == 1, "order parsed")
            check(Snapshot.upNext(items).map(\.id) == ["t_c", "t_b", "t_a", "t_a1", "t_d"], "up next order: \(Snapshot.upNext(items).map(\.id))")
        }

        test("reorder and move write order keys; new tasks join the end") {
            let layout = tempVault()
            let svc = try TaskService(layout: layout)
            let a = try svc.addTask(title: "A")
            let b = try svc.addTask(title: "B", group: "Work")
            let c = try svc.addTask(title: "C")
            let sub = try svc.addTask(title: "A sub", parentId: a)
            check(Snapshot.upNext(svc.snapshot.tasks).map(\.id) == [a, sub, c, b], "file order before arranging")
            try svc.reorder([b, a])
            check(Snapshot.upNext(svc.snapshot.tasks).map(\.id) == [b, a, sub, c], "reordered, unlisted kept after")
            check(svc.snapshot.task(c)?.order == 3 && svc.snapshot.task(sub)?.order == nil, "orders stored on top-level only")
            try svc.move(c, to: 0)
            check(Snapshot.upNext(svc.snapshot.tasks).filter { $0.depth == 0 }.map(\.id) == [c, b, a], "moved to top")
            let d = try svc.addTask(title: "D", group: "Work")
            check(Snapshot.upNext(svc.snapshot.tasks).last?.id == d, "new task at the end of up next")
            check(svc.snapshot.nextTask()?.id == c, "next task follows up next")
            do { try svc.move(sub, to: 0); check(false, "moving a subtask should throw") } catch {}
            let text = try String(contentsOf: layout.tasks, encoding: .utf8)
            check(text.contains("order:1"), "order saved in the id comment")
        }

        testAI()

        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
