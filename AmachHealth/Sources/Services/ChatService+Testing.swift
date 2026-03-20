// ChatService+Testing.swift
// AmachHealth
//
// Provides a test-only initializer so XCTest can inject mock dependencies
// without modifying the production singleton.
//
// Only compiled in DEBUG builds — zero overhead in release/App Store builds.

#if DEBUG
import Foundation

extension ChatService {
    /// Test-only factory. Creates an isolated ChatService instance that uses
    /// the provided mock API/wallet clients instead of the production singletons.
    ///
    /// Usage in XCTestCase:
    ///
    ///     let mockAPI = MockAmachAPIClient()
    ///     let mockWallet = MockWalletService()
    ///     let sut = await ChatService.makeForTesting(api: mockAPI, wallet: mockWallet)
    ///
    @MainActor
    static func makeForTesting(
        api: any AmachAPIClientProtocol,
        wallet: any WalletServiceProtocol
    ) -> ChatService {
        ChatService(testAPI: api, testWallet: wallet)
    }

    /// Internal initializer used only by makeForTesting. Not accessible from production code.
    @MainActor
    convenience init(
        testAPI: any AmachAPIClientProtocol,
        testWallet: any WalletServiceProtocol
    ) {
        self.init(injectedAPI: testAPI, injectedWallet: testWallet)
    }

}
#endif
