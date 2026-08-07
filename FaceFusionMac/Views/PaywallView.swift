//
//  PaywallView.swift
//  FaceFusionMac
//
//  Uses Apple's SubscriptionStoreView for the recurring plans and presents
//  the lifetime non-consumable beside it, matching the iOS upgrade screen.
//

import Foundation
import StoreKit
import SwiftUI

@MainActor
struct PaywallView: View {
    private enum Links {
        static let privacy = URL(string: "https://morphiqo.app/privacy")!
        static let support = URL(string: "https://morphiqo.app/support")!
        static let terms = URL(string: "https://morphiqo.app/terms")!
    }

    @Environment(StoreManager.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Morphiqo Pro", systemImage: "sparkles")
                            .font(.title2.weight(.semibold))
                        Text("Swap videos and export your results with unlimited Pro access.")
                            .foregroundStyle(.secondary)
                    }

                    SubscriptionStoreView(
                        groupID: StoreManager.subscriptionGroupID,
                        visibleRelationships: .all
                    )
                    .storeButton(.visible, for: .restorePurchases)
                    .subscriptionStorePolicyDestination(url: Links.privacy,
                                                        for: .privacyPolicy)
                    .subscriptionStorePolicyDestination(url: Links.terms,
                                                        for: .termsOfService)
                    .frame(minHeight: 300)

                    lifetimePurchase

                    Link(destination: Links.support) {
                        Label("Need help? Contact support", systemImage: "questionmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .font(.footnote.weight(.medium))

                    if let errorMessage = store.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Text("Subscriptions renew automatically until cancelled. You can manage or cancel them in your App Store account settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Upgrade")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await store.loadProducts()
            }
            .onChange(of: store.isPro) { _, isPro in
                if isPro { dismiss() }
            }
        }
        .frame(minWidth: 560, minHeight: 620)
    }

    @ViewBuilder
    private var lifetimePurchase: some View {
        if let product = store.lifetimeProduct {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lifetime access")
                        .font(.headline)
                    Text("Pay once for permanent Pro access. No renewal.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await store.purchase(product) }
                } label: {
                    HStack {
                        Text("Unlock lifetime")
                        Spacer()
                        if store.isPurchasing {
                            ProgressView()
                        } else {
                            Text(product.displayPrice)
                                .fontWeight(.semibold)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.isPurchasing)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        } else if store.isLoading {
            ProgressView("Loading lifetime access…")
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

#Preview {
    PaywallView()
        .environment(StoreManager.shared)
}
