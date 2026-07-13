import Testing
@testable import Tome

@Suite @MainActor struct StopConfirmationModelTests {

    @Test func requestPresentsTheConfirmation() {
        let model = StopConfirmationModel()
        #expect(!model.isPresented)
        model.requestStop()
        #expect(model.isPresented)
    }

    @Test func confirmDismissesAndFiresStopExactlyOnce() {
        let model = StopConfirmationModel()
        var stops = 0
        model.onConfirm = { stops += 1 }
        model.requestStop()
        model.confirmStop()
        #expect(!model.isPresented)
        #expect(stops == 1)
    }

    @Test func cancelDismissesWithoutFiring() {
        let model = StopConfirmationModel()
        var stops = 0
        model.onConfirm = { stops += 1 }
        model.requestStop()
        model.cancelStop()
        #expect(!model.isPresented)
        #expect(stops == 0)
    }

    @Test func externalRecordingEndWithdrawsTheDialogWithoutFiring() {
        let model = StopConfirmationModel()
        var stops = 0
        model.onConfirm = { stops += 1 }
        model.requestStop()
        // Session ended by a capture error / API stop / notification stop
        // while the dialog was up — it must withdraw without stopping again.
        model.recordingDidEnd()
        #expect(!model.isPresented)
        #expect(stops == 0)
    }

    @Test func accidentalClickThenRealStopFiresExactlyOnce() {
        let model = StopConfirmationModel()
        var stops = 0
        model.onConfirm = { stops += 1 }
        // The motivating scenario: accidental click mid-meeting → Cancel,
        // then the real stop at meeting end → Stop Recording.
        model.requestStop()
        model.cancelStop()
        model.requestStop()
        model.confirmStop()
        #expect(stops == 1)
    }
}
