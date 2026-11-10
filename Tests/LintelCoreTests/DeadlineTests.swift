import Testing

@testable import LintelCore

@Suite struct DeadlineTests {
    @Test func answersWithTheWorksValueWhenItIsInTime() async {
        let value = await withDeadline(.seconds(5), clock: ContinuousClock()) { 7 }
        #expect(value == 7)
    }

    @Test func givesUpOnWorkThatOutlastsTheBudgetWithoutWaitingForIt() async {
        let started = ContinuousClock.now
        let value = await withDeadline(.milliseconds(20), clock: ContinuousClock()) {
            try? await Task.sleep(for: .seconds(2))
            return 1
        }
        #expect(value == nil)
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}
