//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    var id: NotchViews { view }
    let label: String
    let icon: String
    let view: NotchViews
}

func makeVisibleTabs(shelf: Bool, claude: Bool, fans: Bool) -> [TabModel] {
    var tabs = [TabModel(label: "Home", icon: "house.fill", view: .home)]
    if shelf { tabs.append(TabModel(label: "Shelf", icon: "tray.fill", view: .shelf)) }
    if claude { tabs.append(TabModel(label: "Claude", icon: "sparkle", view: .claude)) }
    if fans { tabs.append(TabModel(label: "Fans", icon: "fan", view: .fans)) }
    return tabs
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace var animation
    @Default(.boringShelf) private var shelfEnabled
    @Default(.showClaudeTab) private var showClaudeTab
    @Default(.showFansTab) private var showFansTab
    @ObservedObject private var fanManager = FanManager.shared

    private var visibleTabs: [TabModel] {
        makeVisibleTabs(shelf: shelfEnabled, claude: showClaudeTab, fans: showFansTab && fanManager.hasFans)
    }
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
        .onChange(of: fanManager.hasFans) { _, has in
            if !has && coordinator.currentView == .fans { coordinator.currentView = .home }
        }
    }

}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
