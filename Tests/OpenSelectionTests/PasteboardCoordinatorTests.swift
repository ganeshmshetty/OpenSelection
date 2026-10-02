// PasteboardCoordinatorTests.swift
// OpenSelectionTests
import XCTest
import AppKit
@testable import OpenSelection

@MainActor
final class PasteboardCoordinatorTests: XCTestCase {

    private func createTestPasteboard(initial: String = "Original User Clipboard") -> NSPasteboard {
        let board = NSPasteboard(name: .init("com.openselection.tests.coord.\(UUID().uuidString)"))
        board.clearContents()
        board.setString(initial, forType: .string)
        return board
    }

    func testUserActionPreemptsBackgroundCaptureAndInheritsBaselineSnapshot() {
        let board = createTestPasteboard(initial: "Original User Clipboard")
        defer { board.releaseGlobally() }

        let coordinator = PasteboardCoordinator()

        // 1. Background capture begins session
        let bgSession = coordinator.beginSession(priority: .backgroundCapture, pasteboard: board)
        XCTAssertNotNil(bgSession)
        XCTAssertFalse(bgSession!.isCancelled)

        // Background capture writes temporary content to pasteboard
        board.clearContents()
        board.setString("Background Synthetic Copy", forType: .string)
        coordinator.markDirty(for: bgSession!)

        // 2. User action arrives while background capture is in flight
        let userSession = coordinator.beginSession(priority: .userAction, pasteboard: board)
        XCTAssertNotNil(userSession)
        XCTAssertTrue(bgSession!.isCancelled, "Background capture must be cancelled when user action arrives")
        XCTAssertFalse(userSession!.isCancelled)

        // User action writes its temporary content
        board.clearContents()
        board.setString("User Action Paste Payload", forType: .string)
        coordinator.markDirty(for: userSession!)

        // Background capture tries to restore (e.g. when its loop finishes)
        bgSession!.restoreImmediately()
        XCTAssertEqual(board.string(forType: .string), "User Action Paste Payload",
                       "Cancelled background capture must NOT restore over active user action")

        // 3. User action restores
        userSession!.restoreImmediately()
        XCTAssertEqual(board.string(forType: .string), "Original User Clipboard",
                       "User action must restore the baseline snapshot from before background capture mutated the board")
    }

    func testRapidSuccessiveUserActionsDoNotSnapshotTemporaryText() async {
        let board = createTestPasteboard(initial: "Original User Clipboard")
        defer { board.releaseGlobally() }

        let coordinator = PasteboardCoordinator()

        // 1. First user action begins
        let session1 = coordinator.beginSession(priority: .userAction, pasteboard: board)
        XCTAssertNotNil(session1)

        // Action 1 writes temporary text
        board.clearContents()
        board.setString("Temporary Paste 1", forType: .string)
        coordinator.markDirty(for: session1!)
        let changeCount1 = board.changeCount
        coordinator.scheduleRestore(for: session1!, delay: 0.1, expectedChangeCount: changeCount1)

        // 2. Second user action arrives rapidly before Action 1's delay expires
        let session2 = coordinator.beginSession(priority: .userAction, pasteboard: board)
        XCTAssertNotNil(session2)
        XCTAssertTrue(session1!.isCancelled, "Action 1 must be cancelled by Action 2")
        XCTAssertFalse(session2!.isCancelled)

        // Action 2 writes its temporary text
        board.clearContents()
        board.setString("Temporary Paste 2", forType: .string)
        coordinator.markDirty(for: session2!)
        let changeCount2 = board.changeCount
        coordinator.scheduleRestore(for: session2!, delay: 0.05, expectedChangeCount: changeCount2)

        // Wait for Action 2's restore delay to expire
        try? await Task.sleep(nanoseconds: 70_000_000)

        // Verify: Board is restored to "Original User Clipboard", NOT "Temporary Paste 1"
        XCTAssertEqual(board.string(forType: .string), "Original User Clipboard",
                       "Action 2 must restore the true original clipboard, never Action 1's temporary text")

        // Wait for Action 1's original delay to also expire to ensure it doesn't fire stale restore
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(board.string(forType: .string), "Original User Clipboard")
    }

    func testLowerPriorityBackgroundCaptureRejectedWhileUserActionActive() {
        let board = createTestPasteboard()
        defer { board.releaseGlobally() }

        let coordinator = PasteboardCoordinator()

        let userSession = coordinator.beginSession(priority: .userAction, pasteboard: board)
        XCTAssertNotNil(userSession)

        let bgSession = coordinator.beginSession(priority: .backgroundCapture, pasteboard: board)
        XCTAssertNil(bgSession, "Background capture must be rejected while user action owns the pasteboard")

        userSession!.restoreImmediately()
    }

    func testCancelAndClearAbortsPendingRestores() async {
        let board = createTestPasteboard(initial: "Original User Clipboard")
        defer { board.releaseGlobally() }

        let coordinator = PasteboardCoordinator()

        let session = coordinator.beginSession(priority: .userAction, pasteboard: board)
        board.clearContents()
        board.setString("Temporary Paste", forType: .string)
        coordinator.markDirty(for: session!)
        coordinator.scheduleRestore(for: session!, delay: 0.05, expectedChangeCount: board.changeCount)

        // User explicitly copies something
        coordinator.cancelAndClear(pasteboard: board)
        board.clearContents()
        board.setString("Explicit Permanent Copy", forType: .string)

        // Wait for restore delay
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(board.string(forType: .string), "Explicit Permanent Copy",
                       "Cancelled restore must not overwrite the explicit permanent copy")
    }

    func testExternalMutationSkipsRestoration() {
        let board = createTestPasteboard(initial: "Original User Clipboard")
        defer { board.releaseGlobally() }

        let coordinator = PasteboardCoordinator()

        let session = coordinator.beginSession(priority: .userAction, pasteboard: board)
        board.clearContents()
        board.setString("Temporary Paste", forType: .string)
        coordinator.markDirty(for: session!)
        let changeCount = board.changeCount

        // External app writes to pasteboard
        board.clearContents()
        board.setString("External App Data", forType: .string)

        // Session attempts restore with original expected changeCount
        session!.restoreImmediately(expectedChangeCount: changeCount)

        XCTAssertEqual(board.string(forType: .string), "External App Data",
                       "Restoration must be skipped when external mutation changed changeCount")
    }
    func testNewSessionPreservesExternalCopyBetweenTemporaryWrites() {
        let board = createTestPasteboard(initial: "A")
        defer { board.releaseGlobally() }
        let coordinator = PasteboardCoordinator()
        let first = coordinator.beginSession(priority: .userAction, pasteboard: board)!
        board.clearContents(); board.setString("temporary", forType: .string)
        coordinator.recordOwnedWrite(changeCount: board.changeCount, for: first)
        board.clearContents(); board.setString("B", forType: .string)
        let second = coordinator.beginSession(priority: .userAction, pasteboard: board)!
        board.clearContents(); board.setString("second temporary", forType: .string)
        coordinator.recordOwnedWrite(changeCount: board.changeCount, for: second)
        second.restoreImmediately()
        XCTAssertEqual(board.string(forType: .string), "B")
    }

    func testPostedCaptureCannotBePreempted() {
        let board = createTestPasteboard()
        defer { board.releaseGlobally() }
        let coordinator = PasteboardCoordinator()
        let capture = coordinator.beginSession(priority: .backgroundCapture, pasteboard: board)!
        coordinator.markCopyPosted(for: capture)
        XCTAssertNil(coordinator.beginSession(priority: .userAction, pasteboard: board))
        coordinator.cancelAndClear(pasteboard: board)
        XCTAssertTrue(coordinator.isSessionActive(for: capture))
        capture.commitPermanent()
        XCTAssertNotNil(coordinator.beginSession(priority: .userAction, pasteboard: board))
        coordinator.cancelAndClear(pasteboard: board)
    }

}
