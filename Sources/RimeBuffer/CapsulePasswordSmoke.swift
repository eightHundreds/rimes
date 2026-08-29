import Darwin
import Foundation

func runCapsulePasswordSmokeTest() -> Bool {
    print("== RIMES Capsule smoke ==")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "rimes-capsule-smoke-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var instant = Date(timeIntervalSince1970: 1_787_961_600)
    let contentStore = CapsuleContentStore(rootURL: root, now: { instant })
    let passwordStore = CapsulePasswordStore(rootURL: root, now: { instant })

    do {
        guard try contentStore.seedDefaultsIfNeeded(),
              !(try contentStore.seedDefaultsIfNeeded()),
              permissions(root.path) == 0o700,
              permissions(contentStore.entryDirectoryURL.path) == 0o700,
              permissions(contentStore.seedMarkerURL.path) == 0o600 else {
            return fail("one-shot default seed and private permissions")
        }
        let seeded = try contentStore.record(
            id: CapsuleContentStore.defaultEntryID
        )
        guard seeded.summary.type == .memory,
              seeded.summary.title == CapsuleContentStore.defaultEntryTitle,
              seeded.content == CapsuleContentStore.defaultEntryContent,
              permissions(seeded.summary.fileURL.path) == 0o600,
              try contentStore.search("rimes", limit: 5).map(\.summary.id)
                == [CapsuleContentStore.defaultEntryID] else {
            return fail("RIMES default Memory seed")
        }
        let seededMarkdown = try String(
            contentsOf: seeded.summary.fileURL,
            encoding: .utf8
        )
        guard seededMarkdown.contains("capsule: memory"),
              seededMarkdown.contains("title: \"RIMES 默认词条\""),
              seededMarkdown.contains("\nRIMES") else {
            return fail("Obsidian-readable default Markdown")
        }
        try contentStore.remove(id: CapsuleContentStore.defaultEntryID)
        guard !(try contentStore.seedDefaultsIfNeeded()) else {
            return fail("deleted default was recreated after seed marker")
        }
        do {
            _ = try contentStore.record(id: CapsuleContentStore.defaultEntryID)
            return fail("removed default still readable")
        } catch CapsuleContentStoreError.recordNotFound {
            // Expected: the seed marker preserves the user's deletion.
        }

        instant.addTimeInterval(1)
        let prompt = try contentStore.put(CapsuleContentWriteRequest(
            type: .prompt,
            title: "总结论文",
            content: "请总结这篇论文的核心贡献。"
        ))
        let memory = try contentStore.put(CapsuleContentWriteRequest(
            type: .memory,
            title: "项目事实",
            content: "Capsule 条目使用 Markdown 管理。"
        ))
        let skill = try contentStore.put(CapsuleContentWriteRequest(
            type: .skill,
            title: "示例技能",
            content: "/tmp/example-skill"
        ))
        guard try contentStore.record(id: prompt.id).content
                == "请总结这篇论文的核心贡献。",
              try contentStore.search("核心贡献", kind: .memory, limit: 5)
                .isEmpty,
              try contentStore.search("核心贡献", limit: 5)
                .map(\.summary.id) == [prompt.id],
              try contentStore.search("Markdown", limit: 5)
                .map(\.summary.id) == [memory.id],
              try contentStore.record(id: skill.id).content
                == "/tmp/example-skill" else {
            return fail("Prompt Memory Skill Markdown round trip")
        }
        instant.addTimeInterval(1)
        let updatedPrompt = try contentStore.put(CapsuleContentWriteRequest(
            id: prompt.id,
            type: .prompt,
            title: "总结论文（精简）",
            content: "用三点总结论文。"
        ))
        guard updatedPrompt.id == prompt.id,
              updatedPrompt.updatedAt == instant,
              try contentStore.record(id: prompt.id).content
                == "用三点总结论文。" else {
            return fail("ordinary Capsule entry update")
        }
        do {
            _ = try contentStore.put(CapsuleContentWriteRequest(
                type: .skill,
                title: "相对路径",
                content: "relative/example-skill"
            ))
            return fail("relative Skill path accepted")
        } catch CapsuleContentStoreError.invalidRequest {
            // Expected.
        }

        let firstRequest = CapsulePasswordWriteRequest(
            title: "示例站点",
            url: "https://example.invalid/login",
            app: "Example Browser",
            username: "fixture-user",
            password: "fixture-current-password",
            previousPasswords: ["fixture-old-password"]
        )
        let first = try passwordStore.put(firstRequest)
        guard permissions(passwordStore.passwordDirectoryURL.path) == 0o700,
              permissions(passwordStore.masterKeyURL.path) == 0o600,
              permissions(first.fileURL.path) == 0o600 else {
            return fail("password private filesystem permissions")
        }

        let markdown = try String(contentsOf: first.fileURL, encoding: .utf8)
        guard markdown.contains("capsule: password"),
              markdown.contains("title: \"示例站点\""),
              markdown.contains("```capsule-password"),
              !markdown.contains("fixture-user"),
              !markdown.contains("fixture-current-password"),
              !markdown.contains("fixture-old-password"),
              !markdown.contains("example.invalid") else {
            return fail("password Markdown plaintext boundary")
        }

        let summaries = try passwordStore.listSummaries()
        guard summaries.count == 1,
              summaries[0].id == first.id,
              summaries[0].title == "示例站点",
              summaries[0].maskedPassword == "••••••••",
              try passwordStore.search("示例", limit: 5).map(\.id) == [first.id],
              try passwordStore.search("fixture-user", limit: 5).isEmpty else {
            return fail("password title-only local search")
        }

        let decrypted = try passwordStore.record(id: first.id)
        guard decrypted.secret.url == firstRequest.url,
              decrypted.secret.app == firstRequest.app,
              decrypted.secret.username == firstRequest.username,
              decrypted.secret.password == firstRequest.password,
              decrypted.secret.previousPasswords
                == firstRequest.previousPasswords else {
            return fail("encrypted password round trip")
        }

        instant.addTimeInterval(10)
        let updated = try passwordStore.put(CapsulePasswordWriteRequest(
            id: first.id,
            title: "示例站点（工作）",
            url: firstRequest.url,
            app: firstRequest.app,
            username: firstRequest.username,
            password: "fixture-rotated-password",
            previousPasswords: [firstRequest.password]
        ))
        let updatedRecord = try passwordStore.record(id: first.id)
        guard updated.id == first.id,
              updated.title == "示例站点（工作）",
              updated.updatedAt == instant,
              updatedRecord.secret.password == "fixture-rotated-password",
              updatedRecord.secret.previousPasswords == [firstRequest.password] else {
            return fail("password update and previous password")
        }

        var tampered = try String(contentsOf: updated.fileURL, encoding: .utf8)
        tampered = tampered.replacingOccurrences(
            of: "title: \"示例站点（工作）\"",
            with: "title: \"被修改标题\""
        )
        try Data(tampered.utf8).write(to: updated.fileURL, options: .atomic)
        guard chmod(updated.fileURL.path, 0o600) == 0 else {
            return fail("tamper fixture permissions")
        }
        do {
            _ = try passwordStore.record(id: first.id)
            return fail("authenticated password title tamper was accepted")
        } catch CapsulePasswordStoreError.decryptionFailed {
            // Expected.
        }

        guard CapsulePasswordUnlockChord.stepCount == 4,
              CapsulePasswordUnlockChord.accepts(keycode: 0x72),
              CapsulePasswordUnlockChord.accepts(keycode: 0x6e),
              !CapsulePasswordUnlockChord.accepts(keycode: 0x66),
              !CapsulePasswordUnlockChord.accepts(keycode: 0x6a),
              CapsulePasswordUnlockChord.matches([
                (keycode: 0x68, mask: 0),
                (keycode: 0x72, mask: 0),
              ], step: 0),
              CapsulePasswordUnlockChord.matches([
                (keycode: 0x6f, mask: 0),
                (keycode: 0x77, mask: 0),
              ], step: 1),
              CapsulePasswordUnlockChord.matches([
                (keycode: 0x76, mask: 0),
                (keycode: 0x6e, mask: 0),
                (keycode: 0x63, mask: 0),
              ], step: 2),
              CapsulePasswordUnlockChord.matches([
                (keycode: 0x75, mask: 0),
                (keycode: 0x71, mask: 0),
              ], step: 3),
              !CapsulePasswordUnlockChord.matches([
                (keycode: 0x72, mask: 0),
              ], step: 0),
              !CapsulePasswordUnlockChord.matches([
                (keycode: 0x72, mask: RimeKey.shiftMask),
                (keycode: 0x68, mask: 0),
              ], step: 0) else {
            return fail("sequenced unlock chord contract")
        }

        guard testInlineContentCreation(store: contentStore),
              testAbsoluteSkillAction(),
              testPasswordWorkspace(root: root, instant: instant),
              TranslationRailRoleSymbolRules.resolve("囊", target: true).name
                == "archivebox",
              TranslationRailRoleSymbolRules.resolve("查", target: false).name
                == "magnifyingglass" else {
            return false
        }

        try passwordStore.remove(id: first.id)
        guard try passwordStore.listSummaries().isEmpty else {
            return fail("password record removal")
        }
    } catch {
        return fail("unexpected error: \(error.localizedDescription)")
    }

    print("Capsule smoke: OK")
    return true
}

private func testInlineContentCreation(store: CapsuleContentStore) -> Bool {
    let source = BufferModel()
    source.enabled = true
    source.stageExternal("一条全新的本地事实", origin: .rime)
    let workspace = CapsuleWorkspace(
        sourceModel: source,
        selected: { true },
        dependencies: .init(
            search: { _, kind, _ in
                guard kind == .memory else { return [] }
                return []
            },
            passwordRecord: { _ in
                throw CapsulePasswordStoreError.recordNotFound
            },
            createContent: { try store.put($0) },
            performBackground: { $0() }
        ),
        initialKind: .memory,
        persistSelectedKind: { _ in }
    )
    workspace.start()
    workspace.fireSearchDebounceForTesting()
    guard capsuleSmokeWaitUntil({ workspace.phase == .ready }),
          workspace.railSnapshot.outputBlocks.map(\.text)
            == ["＋ Memory"],
          let memoryAction = workspace.railSnapshot.outputBlocks.first,
          workspace.selectResult(blockID: memoryAction.id),
          capsuleSmokeWaitUntil({ workspace.phase == .ready }),
          workspace.railSnapshot.outputBlocks.map(\.text)
            == ["Memory · 一条全新的本地事实 · 一条全新的本地事实"],
          workspace.deliveryPendingBlocks.map(\.text)
            == ["一条全新的本地事实"],
          workspace.prepareForDelivery() else {
        workspace.stop()
        return fail("empty-result inline Memory creation")
    }
    let generation = workspace.deliveryGeneration
    guard let deliveryID = workspace.deliveryPendingBlocks.first?.id,
          workspace.deliveryBlock(id: deliveryID, generation: generation)?.text
            == "一条全新的本地事实" else {
        workspace.stop()
        return fail("ordinary Capsule delivery lease")
    }
    workspace.consumeDelivered(blockIDs: [deliveryID], generation: generation)
    guard source.blocks.isEmpty,
          workspace.deliveryPendingBlocks.isEmpty else {
        workspace.stop()
        return fail("ordinary Capsule delivery consumption")
    }
    workspace.stop()
    return true
}

private func testAbsoluteSkillAction() -> Bool {
    let source = BufferModel()
    source.enabled = true
    source.stageExternal("/tmp/example-capsule-skill", origin: .rime)
    let workspace = CapsuleWorkspace(
        sourceModel: source,
        selected: { true },
        dependencies: .init(
            search: { _, kind, _ in
                guard kind == .skill else { return [] }
                return []
            },
            passwordRecord: { _ in
                throw CapsulePasswordStoreError.recordNotFound
            },
            createContent: { _ in
                throw CapsuleContentStoreError.fileOperation("unused")
            },
            performBackground: { $0() }
        ),
        initialKind: .skill,
        persistSelectedKind: { _ in }
    )
    workspace.start()
    workspace.fireSearchDebounceForTesting()
        let passed = capsuleSmokeWaitUntil({ workspace.phase == .ready })
        && workspace.railSnapshot.outputBlocks.map(\.text)
            == ["＋ Skill"]
    workspace.stop()
    return passed || fail("absolute-path Skill inline action")
}

private func testPasswordWorkspace(root: URL, instant: Date) -> Bool {
    let source = BufferModel()
    source.enabled = true
    source.stageExternal("示例", origin: .rime)
    let visible = CapsuleWorkspace.Candidate(
        id: UUID(),
        type: .password,
        title: "示例搜索结果",
        payload: nil,
        snippet: "••••••••"
    )
    let workspace = CapsuleWorkspace(
        sourceModel: source,
        selected: { true },
        dependencies: .init(
            search: { query, kind, limit in
                guard query == "示例", kind == .password, limit == 5 else {
                    return []
                }
                return [visible]
            },
            passwordRecord: { _ in
                throw CapsulePasswordStoreError.recordNotFound
            },
            createContent: { _ in
                CapsuleContentSummary(
                    id: UUID(),
                    type: .memory,
                    title: "unused",
                    updatedAt: instant,
                    fileURL: root.appendingPathComponent("unused.md")
                )
            },
            performBackground: { $0() }
        ),
        initialKind: .password,
        persistSelectedKind: { _ in }
    )
    workspace.start()
    workspace.fireSearchDebounceForTesting()
    guard capsuleSmokeWaitUntil({ workspace.phase == .ready }),
          workspace.railSnapshot.outputBlocks.map(\.text)
            == ["Password · 示例搜索结果 · ••••••••"],
          workspace.canRequestProtectedDelivery,
          !workspace.protectedDeliveryPromptActive,
          !workspace.acceptsUnlockChordKey(0x66),
          !workspace.acceptsUnlockChordKey(0x6a),
          !workspace.acceptsUnlockChordKey(0x72),
          workspace.deliveryPendingBlocks.isEmpty,
          !workspace.prepareForDelivery() else {
        workspace.stop()
        return fail("password masked result and isolated delivery path")
    }
    let options = workspace.optionPickerOptions.map(\.identifier)
    let passed = options == ["prompt", "memory", "password", "skill"]
        && workspace.setOptionPickerSelection("prompt")
        && workspace.selectedOptionPickerID == "prompt"
        && !workspace.acceptsUnlockChordKey(0x72)
        && workspace.deliveryPendingBlocks.isEmpty
    workspace.stop()
    return passed || fail("Capsule type picker and inactive unlock capture")
}

private func permissions(_ path: String) -> mode_t? {
    var metadata = stat()
    guard path.withCString({ stat($0, &metadata) }) == 0 else { return nil }
    return metadata.st_mode & mode_t(0o777)
}

private func fail(_ message: String) -> Bool {
    print("FAILED: \(message)")
    return false
}

private func capsuleSmokeWaitUntil(
    _ predicate: () -> Bool,
    timeout: TimeInterval = 1
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline {
        RunLoop.current.run(
            mode: .default,
            before: Date().addingTimeInterval(0.005)
        )
    }
    return predicate()
}
