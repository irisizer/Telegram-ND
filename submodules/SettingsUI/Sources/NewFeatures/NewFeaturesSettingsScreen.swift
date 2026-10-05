import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI

private enum NewFeaturesSection: Int32 {
    case sharing
    case customization
    case colors
}

private enum NewFeaturesEntry: ItemListNodeEntry {
    case sharingHeader
    case toggle(Bool)
    case sharingFooter(String)
    case customizationHeader
    case emojiInput(String)
    case premiumInfo(String)
    case colorsHeader
    case colorOption(index: Int, hex: Int32, selected: Bool)
    case colorsFooter(String)

    var section: ItemListSectionId {
        switch self {
        case .sharingHeader, .toggle, .sharingFooter:
            return NewFeaturesSection.sharing.rawValue
        case .customizationHeader, .emojiInput, .premiumInfo:
            return NewFeaturesSection.customization.rawValue
        case .colorsHeader, .colorOption, .colorsFooter:
            return NewFeaturesSection.colors.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .sharingHeader:
            return 0
        case .toggle:
            return 1
        case .sharingFooter:
            return 2
        case .customizationHeader:
            return 3
        case .emojiInput:
            return 4
        case .premiumInfo:
            return 5
        case .colorsHeader:
            return 6
        case let .colorOption(index, _, _):
            return 10 + Int32(index)
        case .colorsFooter:
            return 30
        }
    }

    static func <(lhs: NewFeaturesEntry, rhs: NewFeaturesEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! NewFeaturesArguments
        switch self {
        case .sharingHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: arguments.sharingHeader, sectionId: self.section)
        case let .toggle(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: arguments.toggleTitle, text: arguments.toggleText, value: value, sectionId: self.section, style: .blocks, updated: { _ in
                arguments.toggle()
            })
        case let .sharingFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .customizationHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: arguments.customizationHeader, sectionId: self.section)
        case let .emojiInput(current):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: arguments.emojiTitle, font: Font.regular(17.0), textColor: presentationData.theme.list.itemPrimaryTextColor), text: current, placeholder: arguments.emojiPlaceholder, type: .regular(capitalization: false, autocorrection: false), returnKeyType: .done, maxLength: 8, enabled: arguments.isPremium, sectionId: self.section, textUpdated: { updated in
                arguments.updateEmoji(updated)
            }, action: {
            })
        case let .premiumInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .colorsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: arguments.colorTitle, sectionId: self.section)
        case let .colorOption(_, hex, selected):
            let label = selected ? "✓" : ""
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: arguments.colorName(hex: hex), label: label, labelStyle: .text, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.selectColor(hex)
            })
        case let .colorsFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private final class NewFeaturesArguments {
    let sharingHeader: String
    let toggleTitle: String
    let toggleText: String
    let customizationHeader: String
    let emojiTitle: String
    let emojiPlaceholder: String
    let colorTitle: String
    let isPremium: Bool
    let toggle: () -> Void
    let updateEmoji: (String) -> Void
    let selectColor: (Int32) -> Void
    let colorName: (Int32) -> String

    init(sharingHeader: String, toggleTitle: String, toggleText: String, customizationHeader: String, emojiTitle: String, emojiPlaceholder: String, colorTitle: String, isPremium: Bool, toggle: @escaping () -> Void, updateEmoji: @escaping (String) -> Void, selectColor: @escaping (Int32) -> Void, colorName: @escaping (Int32) -> String) {
        self.sharingHeader = sharingHeader
        self.toggleTitle = toggleTitle
        self.toggleText = toggleText
        self.customizationHeader = customizationHeader
        self.emojiTitle = emojiTitle
        self.emojiPlaceholder = emojiPlaceholder
        self.colorTitle = colorTitle
        self.isPremium = isPremium
        self.toggle = toggle
        self.updateEmoji = updateEmoji
        self.selectColor = selectColor
        self.colorName = colorName
    }
}

private let nameDropColorPresets: [Int32] = [
    0x007AFF,
    0x34C759,
    0xFF9500,
    0xFF3B30,
    0xAF52DE,
    0x00C7BE,
    0xFFCC00,
    0x8E8E93,
]

private func newFeaturesEntries(presentationData: PresentationData, settings: NameDropSettings, isPremium: Bool) -> [NewFeaturesEntry] {
    var entries: [NewFeaturesEntry] = []
    entries.append(.sharingHeader)
    entries.append(.toggle(settings.enabled))
    entries.append(.sharingFooter(presentationData.strings.NewFeatures_NameDrop_Text))
    entries.append(.customizationHeader)
    entries.append(.emojiInput(settings.backgroundEmoji ?? ""))
    if !isPremium {
        entries.append(.premiumInfo(presentationData.strings.NewFeatures_Customization_PremiumRequiredText))
    }
    entries.append(.colorsHeader)
    for (index, hex) in nameDropColorPresets.enumerated() {
        entries.append(.colorOption(index: index, hex: hex, selected: settings.backgroundColorHex == hex))
    }
    if settings.backgroundColorHex != nil {
        entries.append(.colorOption(index: 99, hex: -1, selected: false))
    }
    entries.append(.colorsFooter(presentationData.strings.NewFeatures_Customization_PremiumRequiredText))
    return entries
}

public func newFeaturesSettingsScreen(context: AccountContext) -> ViewController {
    let settingsPromise = ValuePromise<NameDropSettings>(NameDropSettingsStore.shared.get(), ignoreRepeated: false)

    var presentPremiumImpl: (() -> Void)?
    var dismissInputImpl: (() -> Void)?

    let arguments = NewFeaturesArguments(
        sharingHeader: context.sharedContext.currentPresentationData.with { $0 }.strings.NewFeatures_NameDrop_Header,
        toggleTitle: context.sharedContext.currentPresentationData.with { $0 }.strings.NewFeatures_NameDrop_Enabled,
        toggleText: context.sharedContext.currentPresentationData.with { $0 }.strings.NewFeatures_NameDrop_Title,
        customizationHeader: context.sharedContext.currentPresentationData.with { $0 }.strings.NewFeatures_Customization_Header,
        emojiTitle: context.sharedContext.currentPresentationData.with { $0 }.strings.NewFeatures_Customization_BackgroundEmoji,
        emojiPlaceholder: context.sharedContext.currentPresentationData.with { $0 }.strings.NewFeatures_Customization_BackgroundEmojiPlaceholder,
        colorTitle: context.sharedContext.currentPresentationData.with { $0 }.strings.NewFeatures_Customization_WindowColor,
        isPremium: context.isPremium,
        toggle: {
            let current = NameDropSettingsStore.shared.get()
            let updated = NameDropSettings(enabled: !current.enabled, backgroundEmoji: current.backgroundEmoji, backgroundColorHex: current.backgroundColorHex)
            NameDropSettingsStore.shared.setEnabled(!current.enabled)
            settingsPromise.set(updated)
        },
        updateEmoji: { updated in
            guard context.isPremium else {
                presentPremiumImpl?()
                settingsPromise.set(NameDropSettingsStore.shared.get())
                return
            }
            NameDropSettingsStore.shared.setBackgroundEmoji(updated)
            settingsPromise.set(NameDropSettingsStore.shared.get())
        },
        selectColor: { hex in
            guard context.isPremium else {
                presentPremiumImpl?()
                return
            }
            if hex == -1 {
                NameDropSettingsStore.shared.setBackgroundColorHex(nil)
            } else {
                let current = NameDropSettingsStore.shared.get()
                if current.backgroundColorHex == hex {
                    NameDropSettingsStore.shared.setBackgroundColorHex(nil)
                } else {
                    NameDropSettingsStore.shared.setBackgroundColorHex(hex)
                }
            }
            settingsPromise.set(NameDropSettingsStore.shared.get())
            dismissInputImpl?()
        },
        colorName: { hex in
            if hex == -1 {
                return "Clear"
            }
            return String(format: "#%06X", hex)
        }
    )

    let signal = combineLatest(
        context.sharedContext.presentationData,
        settingsPromise.get()
    )
    |> deliverOnMainQueue
    |> map { presentationData, settings -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(presentationData.strings.NewFeatures_Title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: newFeaturesEntries(presentationData: presentationData, settings: settings, isPremium: context.isPremium),
            style: .blocks,
            emptyStateItem: nil,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentPremiumImpl = { [weak controller] in
        guard let controller else { return }
        let premiumController = context.sharedContext.makePremiumIntroController(context: context, source: .settings, forceDark: false, dismissed: nil)
        controller.push(premiumController)
    }
    dismissInputImpl = { [weak controller] in
        controller?.view.endEditing(true)
    }

    // Ensure the receiver side is armed while the user configures the feature.
    NameDropManager.shared.ensureReceiver(with: context)

    controller.navigationPresentation = .modal
    return controller
}
