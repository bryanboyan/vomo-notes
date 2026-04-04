import Foundation

/// Protocol for speech-to-text providers.
/// All STT vendors (Apple, OpenAI, Deepgram) conform to this.
protocol STTProvider: AnyObject {
    var text: String { get }
    var isActive: Bool { get }
    var errorMessage: String? { get }

    func start()
    func stop()
}
