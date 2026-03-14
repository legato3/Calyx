//
//  BrowserCommands.swift
//  CalyxCLI
//
//  All browser subcommands for the Calyx CLI.
//

import ArgumentParser
import Foundation

// MARK: - browser list

struct BrowserList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all browser tabs"
    )

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        let result = try client.call(command: "list")
        print(result)
    }
}

// MARK: - browser open

struct BrowserOpen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a new browser tab"
    )

    @Argument(help: "URL to open")
    var url: String

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        let result = try client.call(command: "open", args: ["url": url])
        print(result)
    }
}

// MARK: - browser navigate

struct BrowserNavigate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "navigate",
        abstract: "Navigate to URL"
    )

    @Argument(help: "URL to navigate to")
    var url: String

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = ["url": url]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "navigate", args: args)
        print(result)
    }
}

// MARK: - browser back

struct BrowserBack: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "back",
        abstract: "Navigate back"
    )

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = [:]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "back", args: args)
        print(result)
    }
}

// MARK: - browser forward

struct BrowserForward: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forward",
        abstract: "Navigate forward"
    )

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = [:]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "forward", args: args)
        print(result)
    }
}

// MARK: - browser reload

struct BrowserReload: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reload",
        abstract: "Reload the current page"
    )

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = [:]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "reload", args: args)
        print(result)
    }
}

// MARK: - browser snapshot

struct BrowserSnapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Get accessibility snapshot of the page"
    )

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = [:]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "snapshot", args: args)
        print(result)
    }
}

// MARK: - browser screenshot

struct BrowserScreenshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Take a screenshot of the page"
    )

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = [:]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "screenshot", args: args)
        print(result)
    }
}

// MARK: - browser click

struct BrowserClick: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Click an element"
    )

    @Argument(help: "CSS selector")
    var selector: String

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = ["selector": selector]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "click", args: args)
        print(result)
    }
}

// MARK: - browser fill

struct BrowserFill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fill",
        abstract: "Fill an input field"
    )

    @Argument(help: "CSS selector")
    var selector: String

    @Option(name: .long, help: "Value to fill")
    var value: String

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = ["selector": selector, "value": value]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "fill", args: args)
        print(result)
    }
}

// MARK: - browser type

struct BrowserType: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into the focused element"
    )

    @Argument(help: "Text to type")
    var text: String

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = ["text": text]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "type", args: args)
        print(result)
    }
}

// MARK: - browser press

struct BrowserPress: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "press",
        abstract: "Press a keyboard key"
    )

    @Argument(help: "Key to press (e.g. Enter, Tab, Escape)")
    var key: String

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = ["key": key]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "press", args: args)
        print(result)
    }
}

// MARK: - browser select

struct BrowserSelect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Select an option from a dropdown"
    )

    @Argument(help: "CSS selector for the <select> element")
    var selector: String

    @Option(name: .long, help: "Value to select")
    var value: String

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = ["selector": selector, "value": value]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "select", args: args)
        print(result)
    }
}

// MARK: - browser check

struct BrowserCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check a checkbox"
    )

    @Argument(help: "CSS selector")
    var selector: String

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = ["selector": selector]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "check", args: args)
        print(result)
    }
}

// MARK: - browser uncheck

struct BrowserUncheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uncheck",
        abstract: "Uncheck a checkbox"
    )

    @Argument(help: "CSS selector")
    var selector: String

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = ["selector": selector]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "uncheck", args: args)
        print(result)
    }
}

// MARK: - browser get-text

struct BrowserGetText: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get-text",
        abstract: "Get text content of an element"
    )

    @Argument(help: "CSS selector")
    var selector: String

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = ["selector": selector]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "get_text", args: args)
        print(result)
    }
}

// MARK: - browser get-html

struct BrowserGetHTML: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get-html",
        abstract: "Get HTML content of an element"
    )

    @Argument(help: "CSS selector")
    var selector: String

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = ["selector": selector]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "get_html", args: args)
        print(result)
    }
}

// MARK: - browser eval

struct BrowserEval: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "Evaluate JavaScript in the page"
    )

    @Argument(help: "JavaScript code to evaluate")
    var code: String

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = ["code": code]
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "eval", args: args)
        print(result)
    }
}

// MARK: - browser wait

struct BrowserWait: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait for a condition"
    )

    @Option(name: .long, help: "CSS selector to wait for")
    var selector: String?

    @Option(name: .long, help: "Text to wait for")
    var text: String?

    @Option(name: .long, help: "URL to wait for")
    var url: String?

    @Option(name: .long, help: "Timeout in milliseconds (default: 5000)")
    var timeout: Int?

    @Option(name: .long, help: "Tab ID (uses active tab if omitted)")
    var tabId: String?

    func run() throws {
        let client = try BrowserClient.fromStateFile()
        var args: [String: Any] = [:]
        if let selector { args["selector"] = selector }
        if let text { args["text"] = text }
        if let url { args["url"] = url }
        if let timeout { args["timeout"] = timeout }
        if let tabId { args["tab_id"] = tabId }
        let result = try client.call(command: "wait", args: args)
        print(result)
    }
}
