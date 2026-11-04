import Foundation

struct FakeProvider: AIProvider {
    let answer: String
    var displayName: String { "Fake" }
    var isLocal: Bool { true }
    func availability() -> AIAvailability { .available }
    func complete(system: String, prompt: String) async throws -> String { answer }
}

func runPlan(_ answer: String, request: String, service: TaskService, now: Date) throws -> AIPlan {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<AIPlan, Error>!
    let snapshot = service.snapshot
    Task {
        do { result = .success(try await AIPlanner(provider: FakeProvider(answer: answer)).plan(request, snapshot: snapshot, now: now)) }
        catch { result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try result.get()
}

func testAI() {
    let now = date("2026-09-30T10:00:00+06:00")   // Wednesday

    test("AI: create task, deterministic date wins, title cleaned") {
        let svc = try TaskService(layout: tempVault())
        let answer = """
        Sure! ```json
        {"reply": "Added it.", "operations": [{"op": "create_task", "title": "remind me to finish the Acme brochure before Thursday", "due": "2026-10-09", "priority": null, "group": null, "parent": null}]}
        ```
        """
        let plan = try runPlan(answer, request: "remind me to finish the Acme brochure before Thursday", service: svc, now: now)
        guard case .createTask(let title, let due, _, _, _)? = plan.operations.first else { check(false, "op"); return }
        check(title == "Finish the Acme brochure", "title: \(title)")
        check(due == "2026-10-01", "due: \(String(describing: due))")
        try AIPlanner.apply(plan.operations, service: svc, now: now)
        check(svc.snapshot.tasks.first?.due == "2026-10-01", "applied")
    }

    test("AI: invented task numbers are rejected, real ones resolve") {
        let svc = try TaskService(layout: tempVault())
        let a = try svc.addTask(title: "Brochure", now: now)
        let answer = #"{"reply":"Done.","operations":[{"op":"complete_task","task":1},{"op":"delete_task","task":42},{"op":"rm -rf","task":1}]}"#
        let plan = try runPlan(answer, request: "mark the brochure complete", service: svc, now: now)
        check(plan.operations == [.completeTask(id: a)], "ops: \(plan.operations)")
        check(plan.rejected.count == 2, "rejected: \(plan.rejected)")
    }

    test("AI: subtasks + update + summary-only") {
        let svc = try TaskService(layout: tempVault())
        let a = try svc.addTask(title: "Launch the website", now: now)
        let answer = #"{"reply":"Here's a breakdown.","operations":[{"op":"create_subtasks","parent":1,"titles":["Write copy","Test forms"]},{"op":"update_task","task":1,"priority":"high"}]}"#
        let plan = try runPlan(answer, request: "Break launch the website into smaller tasks, make it high priority", service: svc, now: now)
        try AIPlanner.apply(plan.operations, service: svc, now: now)
        check(svc.snapshot.children(of: a).map(\.title) == ["Write copy", "Test forms"], "subtasks")
        check(svc.snapshot.task(a)?.priority == .high, "priority")
        let summary = try runPlan(#"{"reply":"You focused 25 minutes today.","operations":[]}"#, request: "How did I spend my time today?", service: svc, now: now)
        check(summary.operations.isEmpty && summary.reply.contains("25"), "summary")
        check((try? runPlan("I cannot help", request: "x", service: svc, now: now)) == nil, "garbage throws")
    }
}
