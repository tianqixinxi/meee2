import Combine
import Foundation
import Meee2CommKit

public final class CoordinationWatcher {
    public static let shared = CoordinationWatcher()

    private let queue = DispatchQueue(label: "com.meee2.coordination-watcher", qos: .utility)
    private var subscription: AnyCancellable?
    private var pendingSessionIds = Set<String>()
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceSeconds: TimeInterval = 2
    private let wakeCooldown: TimeInterval = 30

    private init() {}

    public func start() {
        queue.sync {
            guard subscription == nil else { return }
            subscription = SessionEventBus.shared.publisher.sink { [weak self] event in
                self?.handle(event)
            }
        }
    }

    func syncNow(groupId: String) throws {
        let group = try CoordinationStore.shared.group(id: groupId)
        for sid in group.memberSessionIds {
            _ = try? CoordinationStore.shared.refreshMemberDigest(groupId: group.id, sessionId: sid)
        }
        _ = try CoordinationStore.shared.appendEvent(
            groupId: group.id,
            kind: "sync",
            reason: "manual sync",
            sessionIds: group.memberSessionIds,
            contextPreview: ""
        )
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .sessionAdded(let sessionId),
             .sessionMetadataChanged(let sessionId),
             .transcriptAppended(let sessionId):
            schedule(sessionId: sessionId)
        case .sessionRemoved,
             .channelMutated,
             .messageMutated,
             .cardTemplateChanged,
             .boardLayoutChanged:
            break
        }
    }

    private func schedule(sessionId: String) {
        queue.async {
            self.pendingSessionIds.insert(sessionId)
            self.debounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.flush()
            }
            self.debounceWorkItem = work
            self.queue.asyncAfter(deadline: .now() + self.debounceSeconds, execute: work)
        }
    }

    private func flush() {
        let changedIds = pendingSessionIds
        pendingSessionIds.removeAll()
        debounceWorkItem = nil
        guard !changedIds.isEmpty else { return }

        let groups = CoordinationStore.shared.snapshot().filter { !$0.paused }
        for group in groups {
            let affected = group.memberSessionIds.filter { changedIds.contains($0) || changedIds.contains(rawLikeSessionId($0)) }
            guard !affected.isEmpty else { continue }
            var wakeReasons: [String] = []
            for sid in affected {
                do {
                    let result = try CoordinationStore.shared.refreshMemberDigest(groupId: group.id, sessionId: sid)
                    if let reason = result.wakeReason, result.changed {
                        wakeReasons.append(reason)
                    }
                } catch {
                    MWarn("[CoordinationWatcher] digest refresh failed group=\(group.id) sid=\(sid): \(error)")
                }
            }
            guard !wakeReasons.isEmpty else { continue }
            maybeWake(groupId: group.id, reason: wakeReasons.joined(separator: "; "), changedSessionIds: affected)
        }
    }

    private func maybeWake(groupId: String, reason: String, changedSessionIds: [String]) {
        do {
            let group = try CoordinationStore.shared.group(id: groupId)
            guard !group.paused else { return }
            guard let coordinator = group.coordinatorSessionId, !coordinator.isEmpty else {
                _ = try CoordinationStore.shared.appendEvent(
                    groupId: groupId,
                    kind: "wake_skipped",
                    reason: "coordinator session not ready: \(reason)",
                    sessionIds: changedSessionIds,
                    contextPreview: ""
                )
                return
            }
            if let last = group.lastWakeAt, Date().timeIntervalSince(last) < wakeCooldown {
                _ = try CoordinationStore.shared.appendEvent(
                    groupId: groupId,
                    kind: "wake_skipped",
                    reason: "cooldown: \(reason)",
                    sessionIds: changedSessionIds,
                    contextPreview: ""
                )
                return
            }
            let context = try CoordinationStore.shared.compactContext(
                groupId: groupId,
                reason: reason,
                changedSessionIds: changedSessionIds
            )
            try CoordinationStore.shared.sendToSession(sessionId: coordinator, content: context)
            _ = try CoordinationStore.shared.appendEvent(
                groupId: groupId,
                kind: "wake",
                reason: reason,
                sessionIds: changedSessionIds,
                contextPreview: context
            )
            _ = try CoordinationStore.shared.markWoken(groupId: groupId, lastRoutedAction: "Auto wake: \(reason)")
        } catch {
            MWarn("[CoordinationWatcher] wake failed group=\(groupId): \(error)")
        }
    }

    private func rawLikeSessionId(_ id: String) -> String {
        guard let dash = id.lastIndex(of: "-") else { return id }
        return String(id[id.index(after: dash)...])
    }
}
