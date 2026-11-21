import Foundation
import Observation
import StoreKit

/// Unwalked Plus: unlimited fresh loops. Recording and the map stay free.
@Observable
final class Purchases {
    enum Plan: String, CaseIterable, Identifiable {
        case yearly = "com.unwalked.plus.yearly"
        case monthly = "com.unwalked.plus.monthly"

        var id: String { rawValue }
        var label: String { self == .yearly ? "Yearly" : "Monthly" }

        /// Prices from the design, shown until the App Store answers.
        var fallbackMonthly: String { self == .yearly ? "£1.67" : "£2.99" }
        var fallbackPrice: String { self == .yearly ? "£19.99" : "£2.99" }
    }

    private(set) var products: [Plan: Product] = [:]
    private(set) var hasPlus = false
    private(set) var isPurchasing = false
    var errorMessage: String?

    private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self?.refreshEntitlements()
                }
            }
        }
        Task { await load() }
    }

    deinit { updates?.cancel() }

    func load() async {
        if let loaded = try? await Product.products(for: Plan.allCases.map(\.rawValue)) {
            var map: [Plan: Product] = [:]
            for product in loaded { if let plan = Plan(rawValue: product.id) { map[plan] = product } }
            products = map
        }
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, Plan(rawValue: t.productID) != nil, t.revocationDate == nil {
                active = true
            }
        }
        #if DEBUG
        // Launch with `-plus` to try the Plus features without a StoreKit purchase.
        if ProcessInfo.processInfo.arguments.contains("-plus") { active = true }
        #endif
        hasPlus = active
    }

    func purchase(_ plan: Plan) async {
        guard let product = products[plan] else {
            errorMessage = "The App Store isn't available right now. Try again in a moment."
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                await refreshEntitlements()
            case .success(.unverified):
                errorMessage = "The App Store couldn't confirm that purchase."
            default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !hasPlus { errorMessage = "No Unwalked Plus purchase found for this Apple ID." }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Copy

    func monthlyPrice(_ plan: Plan) -> String {
        guard let product = products[plan] else { return plan.fallbackMonthly }
        if plan == .yearly {
            return (product.price / 12).formatted(product.priceFormatStyle)
        }
        return product.displayPrice
    }

    func price(_ plan: Plan) -> String { products[plan]?.displayPrice ?? plan.fallbackPrice }

    func detail(_ plan: Plan) -> String {
        switch plan {
        case .yearly: "\(trialDays(plan).map { "\($0) days free, then " } ?? "")\(price(plan)) a year"
        case .monthly: "Billed every month"
        }
    }

    func cta(_ plan: Plan) -> String {
        if let days = trialDays(plan) { return "Try free for \(days) days" }
        return plan == .yearly ? "Subscribe for \(price(plan)) a year" : "Subscribe for \(price(plan)) a month"
    }

    func terms(_ plan: Plan) -> String {
        plan == .yearly
            ? "\(trialDays(plan) != nil ? "Then " : "")\(price(plan)) a year. Cancel anytime in Settings."
            : "Renews monthly. Cancel anytime in Settings."
    }

    /// Free-trial length. Assumes the 7-day trial in the design until the product loads.
    func trialDays(_ plan: Plan) -> Int? {
        guard plan == .yearly else { return nil }
        guard let product = products[plan] else { return 7 }
        guard let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        switch offer.period.unit {
        case .day: return offer.period.value
        case .week: return offer.period.value * 7
        default: return nil
        }
    }
}
