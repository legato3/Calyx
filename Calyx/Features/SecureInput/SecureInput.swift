import Carbon
import Cocoa
import OSLog

@Observable @MainActor
final class SecureInput {
    static let shared = SecureInput()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
        category: String(describing: SecureInput.self)
    )

    // True to enable secure input globally (user toggle via menu)
    var global: Bool = false {
        didSet {
            apply()
        }
    }

    // Per-surface scoped tracking: ObjectIdentifier -> isFocused
    private var scoped: [ObjectIdentifier: Bool] = [:]

    // True when EnableSecureEventInput() has been called
    private(set) var enabled: Bool = false

    // True if we WANT secure input enabled
    private var desired: Bool {
        global || scoped.contains(where: { $0.value })
    }

    nonisolated(unsafe) private var observers: [Any] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDidResignActive() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDidBecomeActive() }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setScoped(_ object: ObjectIdentifier, focused: Bool) {
        scoped[object] = focused
        apply()
    }

    func removeScoped(_ object: ObjectIdentifier) {
        scoped[object] = nil
        apply()
    }

    private func apply() {
        guard NSApp.isActive else { return }
        guard enabled != desired else { return }

        let err: OSStatus
        if enabled {
            err = DisableSecureEventInput()
        } else {
            err = EnableSecureEventInput()
        }
        if err == noErr {
            enabled = desired
            Self.logger.debug("secure input state=\(self.enabled)")
            return
        }
        Self.logger.warning("secure input apply failed err=\(err)")
    }

    private func onDidBecomeActive() {
        guard !enabled && desired else { return }
        let err = EnableSecureEventInput()
        if err == noErr {
            enabled = true
            Self.logger.debug("secure input enabled on activation")
            return
        }
        Self.logger.warning("secure input apply failed err=\(err)")
    }

    private func onDidResignActive() {
        guard enabled else { return }
        let err = DisableSecureEventInput()
        if err == noErr {
            enabled = false
            Self.logger.debug("secure input disabled on deactivation")
            return
        }
        Self.logger.warning("secure input apply failed err=\(err)")
    }
}
