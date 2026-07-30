import XCTest
@testable import Fuse

final class ClamshellSleepControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ClamshellSleepControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSuccessfulEnableThenDisableClearsMarker() {
        let selector = SelectorFake(results: [true, true])
        let retryScheduler = RetrySchedulerFake()
        let controller = makeController(selector: selector, retryScheduler: retryScheduler)

        controller.requestEnable()
        XCTAssertTrue(heldMarker)
        XCTAssertEqual(controller.state, .enableRequested)

        controller.requestRelease()

        XCTAssertFalse(heldMarker)
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertEqual(selector.requests, [true, false])
        XCTAssertFalse(controller.hasScheduledReleaseRetry)
    }

    func testFailedDisableKeepsMarkerAndCannotReassertEnable() {
        let selector = SelectorFake(results: [true, false])
        let retryScheduler = RetrySchedulerFake()
        let controller = makeController(selector: selector, retryScheduler: retryScheduler)

        controller.requestEnable()
        controller.requestRelease()
        controller.reassertEnableIfRequested()

        XCTAssertTrue(heldMarker)
        XCTAssertEqual(controller.state, .releasePending)
        XCTAssertEqual(selector.requests, [true, false])
        XCTAssertTrue(controller.hasScheduledReleaseRetry)
        XCTAssertEqual(retryScheduler.scheduleCount, 1)
    }

    func testLaterSuccessfulRetryClearsMarker() {
        let selector = SelectorFake(results: [true, false, true])
        let retryScheduler = RetrySchedulerFake()
        let controller = makeController(selector: selector, retryScheduler: retryScheduler)

        controller.requestEnable()
        controller.requestRelease()
        retryScheduler.fire()

        XCTAssertFalse(heldMarker)
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertEqual(selector.requests, [true, false, false])
        XCTAssertFalse(controller.hasScheduledReleaseRetry)
    }

    func testFailedStartupRecoveryKeepsMarker() {
        heldMarker = true
        let selector = SelectorFake(results: [false])
        let retryScheduler = RetrySchedulerFake()
        let controller = makeController(selector: selector, retryScheduler: retryScheduler)

        controller.recoverStaleHold()

        XCTAssertTrue(heldMarker)
        XCTAssertEqual(controller.state, .releasePending)
        XCTAssertEqual(selector.requests, [false])
        XCTAssertTrue(controller.hasScheduledReleaseRetry)
    }

    func testSuccessfulStartupRecoveryClearsMarker() {
        heldMarker = true
        let selector = SelectorFake(results: [true])
        let retryScheduler = RetrySchedulerFake()
        let controller = makeController(selector: selector, retryScheduler: retryScheduler)

        controller.recoverStaleHold()

        XCTAssertFalse(heldMarker)
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertEqual(selector.requests, [false])
        XCTAssertFalse(controller.hasScheduledReleaseRetry)
    }

    func testRepeatedReleaseAndRecoveryWithoutMarkerAreIdempotent() {
        let selector = SelectorFake(results: [])
        let retryScheduler = RetrySchedulerFake()
        let controller = makeController(selector: selector, retryScheduler: retryScheduler)

        controller.requestRelease()
        controller.requestRelease()
        controller.recoverStaleHold()

        XCTAssertFalse(heldMarker)
        XCTAssertEqual(controller.state, .inactive)
        XCTAssertEqual(selector.requests, [])
        XCTAssertEqual(retryScheduler.scheduleCount, 0)
    }

    func testRepeatedCleanupRetriesImmediatelyWithoutSchedulingAnotherRetry() {
        let selector = SelectorFake(results: [true, false, false])
        let retryScheduler = RetrySchedulerFake()
        let controller = makeController(selector: selector, retryScheduler: retryScheduler)

        controller.requestEnable()
        controller.requestRelease()
        controller.requestRelease()

        XCTAssertTrue(heldMarker)
        XCTAssertEqual(controller.state, .releasePending)
        XCTAssertEqual(selector.requests, [true, false, false])
        XCTAssertEqual(retryScheduler.scheduleCount, 1)
    }

    func testEnableWhileReleasePendingCancelsRetry() {
        let selector = SelectorFake(results: [true, false, true])
        let retryScheduler = RetrySchedulerFake()
        let controller = makeController(selector: selector, retryScheduler: retryScheduler)

        controller.requestEnable()
        controller.requestRelease()
        controller.requestEnable()

        XCTAssertTrue(heldMarker)
        XCTAssertEqual(controller.state, .enableRequested)
        XCTAssertEqual(selector.requests, [true, false, true])
        XCTAssertFalse(controller.hasScheduledReleaseRetry)
        XCTAssertEqual(retryScheduler.cancelCount, 1)
    }

    private var heldMarker: Bool {
        get { defaults.bool(forKey: ClamshellSleepController.heldMarkerKey) }
        set { defaults.set(newValue, forKey: ClamshellSleepController.heldMarkerKey) }
    }

    private func makeController(
        selector: SelectorFake,
        retryScheduler: RetrySchedulerFake
    ) -> ClamshellSleepController {
        ClamshellSleepController(
            defaults: defaults,
            selectorOperation: selector.call,
            retryScheduler: retryScheduler.schedule
        )
    }
}

private final class SelectorFake {
    private var results: [Bool]
    private(set) var requests: [Bool] = []

    init(results: [Bool]) {
        self.results = results
    }

    func call(disabled: Bool) -> Bool {
        requests.append(disabled)
        return results.removeFirst()
    }
}

private final class RetrySchedulerFake {
    private var action: (() -> Void)?
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0

    func schedule(action: @escaping () -> Void) -> () -> Void {
        scheduleCount += 1
        self.action = action
        return { [weak self] in
            self?.cancelCount += 1
            self?.action = nil
        }
    }

    func fire() {
        let action = action
        self.action = nil
        action?()
    }
}
