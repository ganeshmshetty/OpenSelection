import AppKit
import XCTest
@testable import OpenSelection

@MainActor
final class NativeCopyOperationTests: XCTestCase {
    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: .init("com.openselection.native-copy.\(UUID().uuidString)"))
        board.setString("Original", forType: .string)
        return board
    }

    func testRetainsMultipleItemsAndLazyCustomFormatsWithoutReadingOrRewriting() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("com.test.custom-markdown")
        let provider = Provider()
        var copiedCount = 0
        try await NativeCopyOperation().perform(pasteboard: board, timeout: 0.1, isAuthorized: { true }) {
            let first = NSPasteboardItem()
            first.setString("Bold", forType: .string)
            first.setString("<b>Bold</b>", forType: .html)
            first.setDataProvider(provider, forTypes: [custom])
            let second = NSPasteboardItem()
            second.setString("Second", forType: .string)
            board.clearContents()
            board.writeObjects([first, second])
            copiedCount = board.changeCount
        }
        XCTAssertEqual(board.changeCount, copiedCount, "Copy must not rewrite or restore the source's items")
        XCTAssertEqual(provider.requests, 0, "Lazy data belongs to the source, not the copy observer")
        XCTAssertEqual(board.pasteboardItems?.count, 2)
        XCTAssertEqual(board.pasteboardItems?.first?.string(forType: .html), "<b>Bold</b>")
        XCTAssertEqual(board.pasteboardItems?.first?.string(forType: custom), "**Bold**")
        XCTAssertEqual(board.pasteboardItems?.last?.string(forType: .string), "Second")
    }

    func testTimeoutLeavesExistingClipboardUntouchedAndReleasesOwnership() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let count = board.changeCount
        do {
            try await NativeCopyOperation().perform(pasteboard: board, timeout: 0.01, isAuthorized: { true }) {}
            XCTFail("An unchanged clipboard must not report Copy success")
        } catch NativeCopyOperation.Failure.timedOut {}
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(board.string(forType: .string), "Original")
        let next = try await PasteboardCoordinator.shared.acquireSession(priority: .userAction, pasteboard: board)
        next.commitPermanent()
    }

    func testRechecksSelectionAfterWaitingForClipboardOwnership() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let occupied = try await PasteboardCoordinator.shared.acquireSession(priority: .userAction, pasteboard: board)
        var checked = false
        var current = true
        var posted = false
        let copy = Task {
            try await NativeCopyOperation().perform(pasteboard: board, timeout: 0.1, isAuthorized: {
                checked = true
                return current
            }) { posted = true }
        }
        while !checked { await Task.yield() }
        current = false
        occupied.commitPermanent()
        do {
            try await copy.value
            XCTFail("A superseded selection must not be copied")
        } catch NativeCopyOperation.Failure.targetChanged {}
        XCTAssertFalse(posted)
        XCTAssertEqual(board.string(forType: .string), "Original")
    }

    func testCancellationAfterPostingDrainsResponseBeforeNextWrite() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        var posted = false
        let copy = Task {
            try await NativeCopyOperation().perform(pasteboard: board, timeout: 0.1, isAuthorized: { true }) {
                posted = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(20))
                    board.clearContents()
                    board.setString("Native copy", forType: .string)
                }
            }
        }
        while !posted { await Task.yield() }
        copy.cancel()
        let next = try await PasteboardCoordinator.shared.acquireSession(priority: .userAction, pasteboard: board)
        XCTAssertEqual(board.string(forType: .string), "Native copy", "The posted command must drain before the next operation")
        next.commitPermanent()
        do {
            try await copy.value
            XCTFail("Cancellation must reach the caller after draining")
        } catch is CancellationError {}
    }

    func testFailedCommandStillDrainsAnAlreadySubmittedResponse() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        do {
            try await NativeCopyOperation().perform(pasteboard: board, timeout: 0.1, isAuthorized: { true }) {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(10))
                    board.clearContents()
                    board.setString("Late native response", forType: .string)
                }
                throw NativeCopyOperation.Failure.commandUnavailable
            }
            XCTFail("A failed command must not report success")
        } catch NativeCopyOperation.Failure.commandUnavailable {}
        XCTAssertEqual(board.string(forType: .string), "Late native response")
    }

    private final class Provider: NSObject, NSPasteboardItemDataProvider {
        var requests = 0
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            requests += 1
            item.setString("**Bold**", forType: type)
        }
    }
}
