import Foundation
import Observation
import StoreKit

enum SubscriptionStoreError: LocalizedError {
    case productUnavailable
    case failedVerification

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return "The monthly plan is unavailable right now. Try again later."
        case .failedVerification:
            return "The App Store could not verify this purchase."
        }
    }
}

@MainActor
@Observable
final class SubscriptionStore {
    private(set) var product: Product?
    private(set) var entitlementJWS: String?
    private(set) var expirationDate: Date?
    private(set) var usage: CloudUsage?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored
    private var updatesTask: Task<Void, Never>?

    var isSubscribed: Bool {
        guard entitlementJWS != nil else { return false }
        return expirationDate.map { $0 > Date() } ?? false
    }

    var priceText: String {
        product?.displayPrice ?? "$4.99"
    }

    init() {
        updatesTask = observeTransactions()
        Task { await load() }
    }

    deinit {
        updatesTask?.cancel()
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            product = try await Product.products(for: [CloudPlan.productID]).first
            await refreshEntitlement()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func purchase() async throws {
        guard let product else { throw SubscriptionStoreError.productUnavailable }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw SubscriptionStoreError.failedVerification
            }
            await transaction.finish()
            await refreshEntitlement()
        case .pending, .userCancelled:
            return
        @unknown default:
            return
        }
    }

    func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlement()
    }

    func record(_ usage: CloudUsage) {
        self.usage = usage
    }

    private func refreshEntitlement() async {
        var currentJWS: String?
        var currentExpiration: Date?

        for await verification in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification,
                  transaction.productID == CloudPlan.productID,
                  transaction.revocationDate == nil,
                  let expiration = transaction.expirationDate,
                  expiration > Date() else { continue }
            currentJWS = verification.jwsRepresentation
            currentExpiration = expiration
            break
        }

        entitlementJWS = currentJWS
        expirationDate = currentExpiration
    }

    private func observeTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await verification in Transaction.updates {
                guard !Task.isCancelled else { return }
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
    }
}
