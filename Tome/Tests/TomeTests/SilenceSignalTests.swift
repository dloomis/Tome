import Testing
@testable import Tome

@Suite struct SilenceSignalTests {

    @Test func micCountsUntilTheFarEndIsHeard() {
        #expect(SilenceSignal.level(combined: 0.4, farEnd: 0, farEndHeard: false) == 0.4)
        #expect(SilenceSignal.utteranceBreaksSilence(.you, farEndHeard: false))
    }

    @Test func onlyTheFarEndCountsOnceHeard() {
        // Mic is loud, far end is dead: the call is over, the room is not.
        #expect(SilenceSignal.level(combined: 0.4, farEnd: 0, farEndHeard: true) == 0)
        #expect(SilenceSignal.level(combined: 0.4, farEnd: 0.2, farEndHeard: true) == 0.2)
        #expect(!SilenceSignal.utteranceBreaksSilence(.you, farEndHeard: true))
        #expect(SilenceSignal.utteranceBreaksSilence(.them, farEndHeard: true))
    }
}
