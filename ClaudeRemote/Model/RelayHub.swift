import SwiftUI
import Combine

/// Multi-Mac coordinator. Pairings are PERMANENT history (scan once, keep forever;
/// re-scanning a Mac just refreshes its key/url — deduped by relay room). Whether a
/// paired Mac is actually CONNECTED is a per-device switch the user flips on the
/// phone: nothing connects by default. Enabled devices each get their own
/// `RelayClient` (room + socket); the UI reads the merged surface here and
/// per-session traffic routes to the owning client.
@MainActor
final class RelayHub: ObservableObject {
    struct Device: Identifiable {
        let id: String            // relay room — stable per Mac
        var pairingString: String
        var enabled: Bool         // user's connect switch (persisted)
        var label: String         // last-known hostname (persisted, survives disable)
        var client: RelayClient?  // live only while enabled
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var sessions: [Session] = []          // merged, newest first
    @Published private(set) var paired = false                    // any device in the list
    @Published private(set) var state: RelayClient.ConnState = .offline   // over enabled devices
    @Published private(set) var lastError = ""
    /// cwd → live hook state, merged across connected devices — drives the
    /// in-list "task running" indicators and the Active/Needs filter chips.
    @Published private(set) var liveStates: [String: RelayClient.AgentStateInfo] = [:]

    var isOnline: Bool { state == .online }
    /// Any device switched on (the drawer shows remote content only then).
    var anyEnabled: Bool { devices.contains { $0.enabled } }

    private var owners: [String: RelayClient] = [:]   // session id → owning client
    private var bags: [String: Set<AnyCancellable>] = [:]

    private struct StoredDevice: Codable { var s: String; var on: Bool; var label: String? }
    private let devicesKey = "cr.devices"
    private let legacyListKey = "cr.pairings"   // brief multi-pairing era — migrated (off)
    private let legacyKey = "cr.pairing"        // single-pairing era — migrated (off)

    // MARK: pairing lifecycle

    func loadPersisted() {
        var stored: [StoredDevice] = []
        if let data = UserDefaults.standard.data(forKey: devicesKey),
           let decoded = try? JSONDecoder().decode([StoredDevice].self, from: data) {
            stored = decoded
        } else {
            // Migrations land DISABLED — connecting is an explicit user action.
            if let list = UserDefaults.standard.stringArray(forKey: legacyListKey) {
                stored = list.map { StoredDevice(s: $0, on: false, label: nil) }
            } else if let single = UserDefaults.standard.string(forKey: legacyKey) {
                stored = [StoredDevice(s: single, on: false, label: nil)]
            }
        }
        for d in stored {
            guard let info = RelayCrypto.parsePairing(d.s),
                  !devices.contains(where: { $0.id == info.room }) else { continue }
            var device = Device(id: info.room, pairingString: d.s, enabled: false,
                                label: d.label ?? "Mac · \(String(info.room.prefix(6)))", client: nil)
            if d.on { attachClient(&device) }
            devices.append(device)
        }
        recompute()
        persist()   // normalize storage + complete migration
    }

    /// Add (or refresh) a paired Mac. New devices join the list SWITCHED OFF —
    /// the user connects them explicitly. `connectImmediately` is for dev hooks
    /// (CR_PAIRING) and tests.
    @discardableResult
    func add(_ string: String, persist shouldPersist: Bool = true, connectImmediately: Bool = false) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let info = RelayCrypto.parsePairing(trimmed) else { return false }
        if let i = devices.firstIndex(where: { $0.id == info.room }) {
            // Same Mac re-scanned: refresh key/url, keep its switch state.
            devices[i].pairingString = trimmed
            if devices[i].enabled, let client = devices[i].client {
                _ = client.pair(with: trimmed, persist: false)
            }
            if connectImmediately { setEnabled(info.room, true) }
        } else {
            var device = Device(id: info.room, pairingString: trimmed, enabled: false,
                                label: "Mac · \(String(info.room.prefix(6)))", client: nil)
            if connectImmediately { attachClient(&device) }
            devices.append(device)
        }
        recompute()
        if shouldPersist { persist() }
        return true
    }

    /// The per-device connect switch.
    func setEnabled(_ id: String, _ on: Bool) {
        NSLog("[hub] setEnabled %@ -> %d", String(id.prefix(6)), on ? 1 : 0)
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        if on {
            guard devices[i].client == nil else { devices[i].enabled = true; return }
            attachClient(&devices[i])
        } else {
            devices[i].client?.unpair()
            devices[i].client = nil
            devices[i].enabled = false
            bags[id] = nil
        }
        recompute()
        persist()
    }

    func remove(_ device: Device) {
        device.client?.unpair()
        devices.removeAll { $0.id == device.id }
        bags[device.id] = nil
        recompute()
        persist()
    }

    private func attachClient(_ device: inout Device) {
        let client = RelayClient()
        guard client.pair(with: device.pairingString, persist: false) else {
            NSLog("[hub] attachClient pair FAILED for %@", String(device.id.prefix(6)))
            return
        }
        device.client = client
        device.enabled = true
        observe(client, room: device.id)
    }

    private func persist() {
        let stored = devices.map { StoredDevice(s: $0.pairingString, on: $0.enabled, label: $0.label) }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: devicesKey)
        }
        UserDefaults.standard.removeObject(forKey: legacyListKey)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    // MARK: merged surface

    /// While the drawer is mid-drag / mid-settle, list recomputes are DEFERRED:
    /// a sessions push landing during the animation rebuilt the (composited)
    /// panel texture and dropped frames — the "rail stutter" on real devices
    /// that never reproduced against mock data. Flush runs on release.
    private var uiHold = false
    private var pendingRecompute = false

    func holdUpdates(_ on: Bool) {
        uiHold = on
        if !on, pendingRecompute {
            pendingRecompute = false
            recompute()
        }
    }

    private func gatedRecompute() {
        if uiHold { pendingRecompute = true } else { recompute() }
    }

    private func observe(_ client: RelayClient, room: String) {
        // @Published emits on WILLSET — recompute() reads `client.sessions` etc.,
        // which at emission time still hold the OLD value. Hop one runloop tick so
        // the merge sees the new state (this was why a pushed session list showed
        // up "a while later": only the NEXT unrelated event surfaced it).
        var bag = Set<AnyCancellable>()
        client.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.gatedRecompute() }
            .store(in: &bag)
        client.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &bag)
        client.$lastError
            .sink { [weak self] e in if !e.isEmpty { self?.lastError = e } }
            .store(in: &bag)
        client.$agentStates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &bag)
        bags[room] = bag
    }

    private func recompute() {
        paired = !devices.isEmpty
        var merged: [Session] = []
        var own: [String: RelayClient] = [:]
        var labelsChanged = false
        for i in devices.indices {
            guard let client = devices[i].client else { continue }
            // Remember the hostname so a switched-off device still shows its name.
            if let host = client.sessions.first?.host, !host.isEmpty, host != "remote",
               devices[i].label != host {
                devices[i].label = host
                labelsChanged = true
            }
            for s in client.sessions {
                merged.append(s)
                own[s.id] = client
            }
        }
        merged.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        sessions = merged
        owners = own
        var live: [String: RelayClient.AgentStateInfo] = [:]
        for d in devices {
            guard let client = d.client else { continue }
            live.merge(client.agentStates) { _, new in new }
        }
        if live != liveStates { liveStates = live }
        let states = devices.compactMap { $0.enabled ? $0.client?.state : nil }
        state = states.contains(.online) ? .online : (states.contains(.connecting) ? .connecting : .offline)
        if labelsChanged { persist() }
    }

    // MARK: routing

    func client(for session: Session) -> RelayClient? { owners[session.id] }

    /// Owning client for a working directory (used by New Session, where only the
    /// cwd is known) — the device that lists a session at that path.
    func client(forPath path: String) -> RelayClient? {
        if let s = sessions.first(where: { $0.path == path }) { return owners[s.id] }
        return devices.first(where: { $0.client != nil })?.client
    }

    func newSession(cwd: String, agent: AgentKind, prompt: String) {
        client(forPath: cwd)?.newSession(cwd: cwd, agent: agent, prompt: prompt)
    }

    // MARK: fan-out controls (enabled devices only)

    func connect() { for d in devices { d.client?.connect() } }
    func ensureLive() { for d in devices { d.client?.ensureLive() } }
    func requestSessions() { for d in devices { d.client?.requestSessions() } }
}
