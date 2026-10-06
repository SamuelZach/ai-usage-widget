import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published var services: [ServiceUsage] = []
    @Published var lastRefresh: Date?
    @Published var refreshing = false
    @Published var now = Date()
    @Published var stats: [String: ServiceStats] = [:]

    private var refreshTimer: Timer?
    private var tickTimer: Timer?

    func start() {
        Task { await refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    func recomputeStats() {
        var out: [String: ServiceStats] = [:]
        for s in services { out[s.id] = ServiceStats.compute(for: s, at: now) }
        stats = out
    }

    func refresh() async {
        if refreshing { return }
        refreshing = true
        let fresh = await Providers.fetchAll()
        // Keep the last good numbers when a fetch fails, but surface the error.
        services = fresh.map { new in
            if new.error != nil, let old = services.first(where: { $0.id == new.id }), old.error == nil {
                return ServiceUsage(id: new.id, name: new.name, plan: old.plan, windows: old.windows,
                                    error: new.error, fetchedAt: old.fetchedAt)
            }
            return new
        }
        lastRefresh = Date()
        now = Date()
        History.shared.record(fresh, at: now)
        recomputeStats()
        refreshing = false
    }
}
