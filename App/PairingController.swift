import Foundation
import SwiftUI
import LLMCostBarCore

@MainActor
final class PairingController: ObservableObject {
    enum State: Equatable { case idle, waitingForBrowser, exchanging, done, failed(String) }
    @Published var state: State = .idle
    var pendingVerifier: String?
    var pendingDisplayName: String = ""
    var onPaired: (() -> Void)?

    func handleCallback(url: URL) {}   // implemented in Task 13
}
