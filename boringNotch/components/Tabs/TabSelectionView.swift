//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

var visibleTabs: [TabModel] {
    var tabs = [TabModel(label: "Home", icon: "house.fill", view: .home)]
    if Defaults[.boringShelf] { tabs.append(TabModel(label: "Shelf", icon: "tray.fill", view: .shelf)) }
    if Defaults[.showClaudeTab] { tabs.append(TabModel(label: "Claude", icon: "sparkle", view: .claude)) }
    if Defaults[.showFansTab] { tabs.append(TabModel(label: "Fans", icon: "fan", view: .fans)) }
    return tabs
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace var animation
    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
        .onAppear { fallBackIfHidden() }
        .onChange(of: Defaults[.showClaudeTab]) { fallBackIfHidden() }
        .onChange(of: Defaults[.showFansTab]) { fallBackIfHidden() }
        .onChange(of: Defaults[.boringShelf]) { fallBackIfHidden() }
    }

    private func fallBackIfHidden() {
        if !visibleTabs.contains(where: { $0.view == coordinator.currentView }) {
            coordinator.currentView = .home
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
