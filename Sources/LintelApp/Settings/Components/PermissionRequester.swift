import AVFoundation
import LintelKit

/// Asks macOS for a permission it can ask for (spec `2026-11-04-lintel-main-window`, D5). Only the microphone has
/// a system prompt; it is shown on a user click on "Allow Microphone" and never otherwise. The other permissions
/// are granted in System Settings, so `request` does nothing for them.
@MainActor
protocol PermissionRequester {
    func request(_ permission: Permission) async
}

/// The real requester: `AVCaptureDevice.requestAccess` for the microphone.
struct SystemPermissionRequester: PermissionRequester {
    func request(_ permission: Permission) async {
        guard permission == .microphone else { return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }
}
