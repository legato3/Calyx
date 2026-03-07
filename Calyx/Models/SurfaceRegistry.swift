// SurfaceRegistry.swift
// Calyx
//
// Mutable UUID→SurfaceView mapping. Controller layer for managing surface lifecycle.

import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "SurfaceRegistry")

@MainActor
final class SurfaceRegistry {

    enum EntryState: Equatable, Sendable {
        case creating
        case attached
        case detaching
        case destroyed
    }

    struct RegistryEntry {
        let view: SurfaceView
        let controller: GhosttySurfaceController
        var state: EntryState
        var isDragging: Bool = false
    }

    private var entries: [UUID: RegistryEntry] = [:]

    var count: Int { entries.count }

    var allIDs: [UUID] { Array(entries.keys) }

    // MARK: - Surface Lifecycle

    func createSurface(app: ghostty_app_t, config: ghostty_surface_config_s) -> UUID? {
        let surfaceView = SurfaceView(frame: .zero)
        surfaceView.wantsLayer = true
        _ = surfaceView.layer

        var mutableConfig = config
        mutableConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        mutableConfig.platform.macos = ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(surfaceView).toOpaque()
        )

        guard let controller = GhosttySurfaceController(app: app, baseConfig: mutableConfig, view: surfaceView) else {
            logger.error("Failed to create surface controller")
            return nil
        }

        surfaceView.surfaceController = controller
        let id = controller.id

        entries[id] = RegistryEntry(
            view: surfaceView,
            controller: controller,
            state: .attached
        )

        logger.info("Surface created and registered: \(id)")
        return id
    }

    func destroySurface(_ id: UUID) {
        guard var entry = entries[id] else { return }
        guard entry.state != .destroyed else { return }

        if entry.isDragging {
            entry.state = .detaching
            entries[id] = entry
            logger.info("Surface destroy deferred (dragging): \(id)")
            return
        }

        entry.state = .destroyed
        entries[id] = entry

        entry.controller.setOcclusion(true)
        entry.view.removeFromSuperview()
        entry.controller.requestClose()

        entries.removeValue(forKey: id)
        logger.info("Surface destroyed: \(id)")
    }

    func completeDragAndDestroyIfNeeded(_ id: UUID) {
        guard var entry = entries[id] else { return }
        entry.isDragging = false
        entries[id] = entry

        if entry.state == .detaching {
            destroySurface(id)
        }
    }

    // MARK: - Lookup

    func view(for id: UUID) -> SurfaceView? {
        entries[id]?.view
    }

    func controller(for id: UUID) -> GhosttySurfaceController? {
        entries[id]?.controller
    }

    func state(for id: UUID) -> EntryState? {
        entries[id]?.state
    }

    func id(for surfaceView: SurfaceView) -> UUID? {
        entries.first(where: { $0.value.view === surfaceView })?.key
    }

    // MARK: - Tab Lifecycle

    func pauseAll() {
        for id in allIDs {
            entries[id]?.controller.setOcclusion(true)
            entries[id]?.controller.setFocus(false)
        }
    }

    func resumeAll() {
        for id in allIDs {
            entries[id]?.controller.setOcclusion(false)
        }
    }

    func contains(_ id: UUID) -> Bool {
        entries[id] != nil
    }
}
