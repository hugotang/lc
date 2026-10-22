import Foundation
import SwiftUI

struct LCStorageManagementView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @StateObject private var model = LCStorageManagementModel()
    @State private var refreshed: Bool = false

    var body: some View {
        Form {
            LCStorageSummarySection(
                breakdown: model.breakdown,
                isCalculating: model.isCalculating,
                errorInfo: model.errorInfo,
                availableBytes: model.availableBytes
            )
            LCInstalledAppsSection(breakdown: model.breakdown)
        }
        .navigationTitle("lc.settings.storageManagement".loc)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await refresh() } } label: {
                    Label("lc.storage.refresh".loc, systemImage: "arrow.clockwise")
                }
                .disabled(model.isCalculating)
            }
        }
        .task {
            if !refreshed {
                await refresh()
                refreshed = true
            }

        }
    }

    private func refresh() async {
        await model.refresh(apps: sharedModel.apps, hiddenApps: sharedModel.hiddenApps)
    }
}
