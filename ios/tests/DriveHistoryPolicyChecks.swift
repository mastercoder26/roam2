import Foundation

@main
struct DriveHistoryPolicyChecks {
    private struct StubDrive: Identifiable {
        let id: UUID
    }

    static func main() {
        expect(
            DriveHistoryPolicy.minimumSavedDriveSeconds == 30,
            "minimum saved duration should be 30 seconds"
        )
        expect(
            !DriveHistoryPolicy.shouldSave(duration: 0),
            "a zero-length drive must not be saved"
        )
        expect(
            !DriveHistoryPolicy.shouldSave(duration: 29),
            "29 seconds must stay under the save threshold"
        )
        expect(
            !DriveHistoryPolicy.shouldSave(duration: 29.9),
            "just under 30 seconds must not be saved"
        )
        expect(
            DriveHistoryPolicy.shouldSave(duration: 30),
            "exactly 30 seconds should be saved"
        )
        expect(
            DriveHistoryPolicy.shouldSave(duration: 120),
            "longer drives should be saved"
        )

        let first = StubDrive(id: UUID())
        let second = StubDrive(id: UUID())
        let remaining = DriveHistoryPolicy.removing(id: first.id, from: [first, second])
        expect(remaining.count == 1, "removing should drop exactly one drive")
        expect(remaining.first?.id == second.id, "removing should keep the other drive")
        expect(
            DriveHistoryPolicy.removing(id: UUID(), from: [first, second]).count == 2,
            "removing an unknown id should leave the list unchanged"
        )

        print("DriveHistoryPolicy checks passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("DriveHistoryPolicy check failed: \(message)")
        }
    }
}
