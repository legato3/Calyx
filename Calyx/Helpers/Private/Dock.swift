import Cocoa
import Darwin

// CoreDock private API — resolved at runtime via dlsym so the app still
// launches if Apple renames or removes these symbols in a future macOS update.

private typealias GetOrientationFn = @convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void
private typealias GetAutoHideFn    = @convention(c) () -> Bool
private typealias SetAutoHideFn    = @convention(c) (Bool) -> Void

// Load Dock.framework explicitly — avoids needing RTLD_DEFAULT (a C macro Swift can't import).
// nonisolated(unsafe): written once at module init, read-only thereafter.
nonisolated(unsafe) private let _dockFramework: UnsafeMutableRawPointer? =
    dlopen("/System/Library/PrivateFrameworks/Dock.framework/Dock", RTLD_LAZY)

private func dockSym<T>(_ name: String) -> T? {
    guard let sym = dlsym(_dockFramework, name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

nonisolated(unsafe) private let _coreDockGetOrientation: GetOrientationFn? = dockSym("CoreDockGetOrientationAndPinning")
nonisolated(unsafe) private let _coreDockGetAutoHide: GetAutoHideFn?       = dockSym("CoreDockGetAutoHideEnabled")
nonisolated(unsafe) private let _coreDockSetAutoHide: SetAutoHideFn?       = dockSym("CoreDockSetAutoHideEnabled")

enum DockOrientation: Int {
    case top = 1
    case bottom = 2
    case left = 3
    case right = 4
}

class Dock {
    static var orientation: DockOrientation? {
        guard let fn = _coreDockGetOrientation else { return nil }
        var orientation: Int32 = 0
        var pinning: Int32 = 0
        fn(&orientation, &pinning)
        return .init(rawValue: Int(orientation))
    }

    static var autoHideEnabled: Bool {
        get { _coreDockGetAutoHide?() ?? false }
        set { _coreDockSetAutoHide?(newValue) }
    }
}
