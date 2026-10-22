//
//  LCMultitaskSettingView.swift
//  LiveContainer
//
//  Created by s s on 2026/3/21.
//

import SwiftUI

struct LCMultitaskSettingView: View {
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("LCLaunchInMultitaskMode") var launchInMultitaskMode = false
    @AppStorage("LCLaunchMultitaskMaximized") var launchMultitaskMaximized = false
    @AppStorage("LCAutoTileMultitaskWindows", store: LCUtils.appGroupUserDefault) var autoTileMultitaskWindows = false
    @AppStorage("LCGridSingleRowInLandscape", store: LCUtils.appGroupUserDefault) var singleRowInLandscape = false
    @AppStorage("LCGridReservePortraitTop", store: LCUtils.appGroupUserDefault) var reservePortraitTop = true
    @AppStorage("LCGridReservePortraitBottom", store: LCUtils.appGroupUserDefault) var reservePortraitBottom = false
    @AppStorage("LCHideGridWindowBars", store: LCUtils.appGroupUserDefault) var hideGridWindowBars = true
    @AppStorage("LCMultitaskBottomWindowBar", store: LCUtils.appGroupUserDefault) var bottomWindowBar = false
    @AppStorage("LCAutoEndPiP", store: LCUtils.appGroupUserDefault) var autoEndPiP = false
    @AppStorage("LCMultitaskAvoidKeyboard", store: LCUtils.appGroupUserDefault) var avoidKeyboard = true
    @AppStorage("LCSkipTerminatedScreen", store: LCUtils.appGroupUserDefault) var skipTerminatedScreen = false
    @AppStorage("LCRestartTerminatedApp", store: LCUtils.appGroupUserDefault) var restartTerminatedApp = false
    @AppStorage("LCMaxOneAppOnStage", store: LCUtils.appGroupUserDefault) var onlyOneAppOnStage = false
    @AppStorage("LCDockWidth", store: LCUtils.appGroupUserDefault) var dockWidth: Double = 80
    @AppStorage("LCHideCollapsedDock", store: LCUtils.appGroupUserDefault) var hideCollapsedDock: Bool = false
    @AppStorage("LCRedirectURLToHost", store: LCUtils.appGroupUserDefault) var redirectURLToHost = false
    
    var body: some View {
        List {
            Section {
                if(UIApplication.shared.supportsMultipleScenes) {
                    Picker(selection: $multitaskMode) {
                        Text("lc.settings.multitaskMode.virtualWindow".loc).tag(MultitaskMode.virtualWindow)
                        Text("lc.settings.multitaskMode.nativeWindow".loc).tag(MultitaskMode.nativeWindow)
                    } label: {
                        Text("lc.settings.multitaskMode".loc)
                    }
                }
                Toggle(isOn: $launchInMultitaskMode) {
                    Text("lc.settings.autoLaunchInMultitaskMode".loc)
                }
                
                if multitaskMode == .virtualWindow {
                    Toggle(isOn: $launchMultitaskMaximized) {
                        Text("lc.settings.launchMultitaskMaximized".loc)
                    }
                    .disabled(autoTileMultitaskWindows)
                    if launchMultitaskMaximized {
                        Toggle(isOn: $onlyOneAppOnStage) {
                            Text("lc.settings.onlyOneAppOnStage".loc)
                        }
                        .disabled(autoTileMultitaskWindows)
                    }
                    Toggle(isOn: $autoEndPiP) {
                        Text("lc.settings.autoEndPiP".loc)
                    }
                    Toggle(isOn: $skipTerminatedScreen) {
                        Text("lc.settings.skipTerminatedScreen".loc)
                    }
                    if skipTerminatedScreen {
                        Toggle(isOn: $restartTerminatedApp) {
                            Text("lc.settings.restartTerminatedApp".loc)
                        }
                    }
                    Toggle(isOn: $bottomWindowBar) {
                        Text("lc.settings.bottomWindowBar".loc)
                    }
                    .disabled(autoTileMultitaskWindows && hideGridWindowBars)
                    Toggle(isOn: $redirectURLToHost) {
                        Text("lc.settings.redirectURLToHost".loc)
                    }

                }
            }

            if multitaskMode == .virtualWindow, #available(iOS 16.0, *) {
                Section {
                    Toggle("lc.settings.avoidKeyboard".loc, isOn: $avoidKeyboard)
                } footer: {
                    Text("lc.settings.avoidKeyboardDesc".loc)
                }
                Section {
                    MultitaskWorkspaceActions()
                } header: {
                    Text("lc.workspace.title".loc)
                } footer: {
                    Text("lc.workspace.description".loc)
                }
                Section {
                    MultitaskTapSyncActions()
                } footer: {
                    Text("lc.tapSync.description".loc)
                }
                Section {
                    Toggle(isOn: $autoTileMultitaskWindows) {
                        Text("lc.settings.autoTileMultitaskWindows".loc)
                    }
                    Picker("lc.multitask.landscapeLayout".loc, selection: $singleRowInLandscape) {
                        Text("lc.multitask.landscapeLayout.automatic".loc).tag(false)
                        Text("lc.multitask.landscapeLayout.singleRow".loc).tag(true)
                    }
                    Toggle(isOn: $hideGridWindowBars) {
                        Text("lc.settings.hideGridWindowBars".loc)
                    }
                    Button {
                        MultitaskDockManager.shared.windowHostingView.arrangeWindowsInGrid()
                    } label: {
                        Label("lc.multitask.arrangeWindowsInGrid".loc, systemImage: "square.grid.2x2")
                    }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("lc.settings.landscapeLayoutDesc".loc)
                            Text("lc.settings.hideGridWindowBarsDesc".loc)
                            Text("lc.settings.gridDividersDesc".loc)
                            Text("lc.settings.gridSwapDesc".loc)
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    } label: {
                        Label("lc.settings.gridHelp".loc, systemImage: "questionmark.circle")
                    }
                } header: {
                    Text("lc.settings.currentWindowLayout".loc)
                } footer: {
                    Text("lc.settings.autoTileMultitaskWindowsDesc".loc)
                }
                Section {
                    Toggle("lc.multitask.reservePortraitTop".loc, isOn: $reservePortraitTop)
                    Toggle("lc.multitask.reservePortraitBottom".loc, isOn: $reservePortraitBottom)
                } header: {
                    Text("lc.multitask.portraitReservedAreas".loc)
                } footer: {
                    Text("lc.settings.portraitReservedAreasDesc".loc)
                }
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("lc.settings.dockWidth".loc)
                            .foregroundColor(.primary)
                        Spacer()
                        Text("\(Int(dockWidth))px")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    Slider(value: $dockWidth, in: 20...120) {
                        Text("lc.settings.dockWidth".loc)
                    }
                    .tint(.accentColor)
                }
                .padding(.vertical, 4)
                Toggle(isOn: $hideCollapsedDock) {
                    Text("lc.settings.hideCollapsedDock".loc)
                }
            }
        }
        .navigationTitle("lc.appBanner.multitask".loc)
        .navigationBarTitleDisplayMode(.inline)
    }
}
