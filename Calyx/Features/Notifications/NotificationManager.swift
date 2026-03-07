// NotificationManager.swift
// Calyx
//
// UNUserNotificationCenter integration with rate limiting.

import AppKit
import UserNotifications
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "NotificationManager")

@MainActor
class NotificationManager {

    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()
    private var rateLimiter = RateLimiter(maxPerSecond: 5)
    private var permissionGranted = false

    private init() {
        requestPermission()
    }

    private func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Task { @MainActor in
                self.permissionGranted = granted
                if let error {
                    logger.error("Notification permission error: \(error.localizedDescription)")
                }
            }
        }
    }

    func sendNotification(title: String, body: String, tabID: UUID) {
        let sanitizedTitle = NotificationSanitizer.sanitize(title)
        let sanitizedBody = NotificationSanitizer.sanitize(body)

        guard rateLimiter.allow(key: tabID) else {
            logger.debug("Rate limited notification for tab \(tabID)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = sanitizedTitle
        content.body = sanitizedBody
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                logger.error("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }

    func bounceDockIcon() {
        NSApp.requestUserAttention(.informationalRequest)
    }
}

// MARK: - Rate Limiter

struct RateLimiter {
    let maxPerSecond: Int
    private var windows: [UUID: [Date]]

    init(maxPerSecond: Int) {
        self.maxPerSecond = maxPerSecond
        self.windows = [:]
    }

    mutating func allow(key: UUID) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-1)

        var recent = windows[key, default: []]
        recent = recent.filter { $0 > cutoff }

        if recent.count >= maxPerSecond {
            windows[key] = recent
            return false
        }

        recent.append(now)
        windows[key] = recent
        return true
    }
}
