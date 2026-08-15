import Foundation

@main
struct DrivePresentationChecks {
    static func main() {
        var state = DrivePresentationState()

        expect(state.phase == .idle, "a new drive surface should begin idle")
        expect(state.action == .start, "idle should present Start Drive")
        expect(state.showsSupportingContent, "idle should show normal Drive content")

        state = DrivePresentationEngine.reduce(state, event: .startTapped)
        expect(state.phase == .switchingToEnd, "a start tap should switch the action before moving it")
        expect(state.action == .end, "the action must become End Drive before expansion")
        expect(!state.isExpanded, "the button must not move during its label swap")

        state = DrivePresentationEngine.reduce(state, event: .actionSwapCompleted)
        expect(state.phase == .active && state.isExpanded, "the action should expand only after the End Drive label settles")
        expect(!state.showsSupportingContent, "active recording should hide secondary content")
        expect(
            DrivePresentationEngine.activeButtonBottomInset >= 36,
            "the active action needs clear local spacing above the floating tab bar"
        )

        state = DrivePresentationEngine.reduce(state, event: .endTapped)
        expect(state.phase == .returning, "an end tap should begin the reverse vertical path")
        expect(state.action == .end, "the End Drive label must remain during its upward return")
        expect(!state.isExpanded, "the timer and button should return to their compact positions")
        expect(state.preservesFocusedCanvas, "the canvas must stay tall while the button returns vertically")
        expect(!state.showsSupportingContent, "normal content must stay hidden while the control returns")

        state = DrivePresentationEngine.reduce(state, event: .returnMotionCompleted)
        expect(state.phase == .switchingToStart, "the action should swap back only after return motion completes")
        expect(state.action == .start, "the returned control should now become Start Drive")
        expect(state.preservesFocusedCanvas, "the Start Drive label swap must stay on the same canvas")
        expect(!state.showsSupportingContent, "the label swap must not reveal the card contents early")

        state = DrivePresentationEngine.reduce(state, event: .startSwapCompleted)
        expect(state.phase == .idle, "the normal Drive surface should return after the Start Drive label settles")
        expect(state.showsSupportingContent, "idle should restore normal Drive content")

        print("DrivePresentation checks passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("DrivePresentation check failed: \(message)")
        }
    }
}
