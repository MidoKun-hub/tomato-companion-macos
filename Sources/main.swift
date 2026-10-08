import AppKit
import QuartzCore

private let focusDuration = 50 * 60
private let restDuration = 10 * 60

private enum Stage: String {
    case idle
    case focus
    case focusDone
    case rest
    case review
}

private enum MascotKind: String, CaseIterable {
    case tomato
    case carrot
    case broccoli
    case eggplant
    case bellPepper

    var displayName: String {
        switch self {
        case .tomato: return "番茄"
        case .carrot: return "胡萝卜"
        case .broccoli: return "西兰花"
        case .eggplant: return "茄子"
        case .bellPepper: return "彩椒"
        }
    }

    var assetName: String {
        switch self {
        case .tomato: return "tomato-pet"
        case .carrot: return "mascot-carrot"
        case .broccoli: return "mascot-broccoli"
        case .eggplant: return "mascot-eggplant"
        case .bellPepper: return "mascot-bell-pepper"
        }
    }
}

private struct Reflection: Codable {
    let date: Date
    let task: String
    let note: String
    let completedItems: [String]?
    let incompleteItems: [String]?
}

private struct ChecklistItem: Codable {
    var text: String
    var isDone: Bool
}

private final class DragView: NSView {
    var menuProvider: (() -> NSMenu)?

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

private final class PetInteractionView: NSView {
    var clickHandler: (() -> Void)?
    var doubleClickHandler: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    private var pendingSingleClick: DispatchWorkItem?

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startingMouse = NSEvent.mouseLocation
        let startingOrigin = window.frame.origin
        var wasDragged = false

        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if nextEvent.type == .leftMouseUp {
                break
            }

            let currentMouse = NSEvent.mouseLocation
            let deltaX = currentMouse.x - startingMouse.x
            let deltaY = currentMouse.y - startingMouse.y
            if abs(deltaX) > 2 || abs(deltaY) > 2 {
                wasDragged = true
                window.setFrameOrigin(NSPoint(x: startingOrigin.x + deltaX, y: startingOrigin.y + deltaY))
            }
        }

        if !wasDragged {
            if event.clickCount >= 2 {
                pendingSingleClick?.cancel()
                pendingSingleClick = nil
                doubleClickHandler?()
            } else {
                pendingSingleClick?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.clickHandler?()
                }
                pendingSingleClick = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

private final class PlaceholderTextView: NSTextView {
    var placeholderString = "" {
        didSet { needsDisplay = true }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        updateFocusAppearance(isFocused: accepted)
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        updateFocusAppearance(isFocused: false)
        needsDisplay = true
        return resigned
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }

        let inset = textContainerInset
        let placeholderRect = bounds.insetBy(dx: inset.width + 5, dy: inset.height + 3)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        (placeholderString as NSString).draw(in: placeholderRect, withAttributes: attributes)
    }

    private func updateFocusAppearance(isFocused: Bool) {
        guard let scrollView = enclosingScrollView else { return }
        scrollView.wantsLayer = true
        scrollView.layer?.borderWidth = isFocused ? 2 : 1
        scrollView.layer?.borderColor = (isFocused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }
}

private func makeTextEditingMenu(includeShortcuts: Bool = false) -> NSMenu {
    let menu = NSMenu(title: "编辑")
    let commands: [(String, String, String)] = [
        ("撤销", "undo:", "z"),
        ("重做", "redo:", "Z"),
        ("剪切", "cut:", "x"),
        ("复制", "copy:", "c"),
        ("粘贴", "paste:", "v"),
        ("全选", "selectAll:", "a")
    ]

    for (index, command) in commands.enumerated() {
        if index == 2 || index == 5 {
            menu.addItem(.separator())
        }
        let item = NSMenuItem(
            title: command.0,
            action: Selector((command.1)),
            keyEquivalent: includeShortcuts ? command.2.lowercased() : ""
        )
        if includeShortcuts {
            item.keyEquivalentModifierMask = command.2 == "Z" ? [.command, .shift] : [.command]
        }
        item.target = nil
        menu.addItem(item)
    }
    return menu
}

private final class ClosureCheckBox: NSButton {
    var onToggle: ((NSButton) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.switch)
        title = ""
        target = self
        action = #selector(didToggle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func didToggle() {
        onToggle?(self)
    }
}

private final class ChecklistPopoverController: NSViewController, NSTextFieldDelegate {
    private var items: [ChecklistItem]
    private let statusText: String
    private let onChange: ([ChecklistItem]) -> Void
    private var checkBoxes: [NSButton] = []

    init(items: [ChecklistItem], statusText: String, onChange: @escaping ([ChecklistItem]) -> Void) {
        var normalized = Array(items.prefix(3))
        while normalized.count < 3 {
            normalized.append(ChecklistItem(text: "", isDone: false))
        }
        self.items = normalized
        self.statusText = statusText
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 206))

        let heading = NSTextField(labelWithString: "当前番茄清单 · 可直接编辑")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.frame = NSRect(x: 16, y: 172, width: 318, height: 22)
        contentView.addSubview(heading)

        let status = NSTextField(labelWithString: statusText)
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 16, y: 151, width: 318, height: 18)
        contentView.addSubview(status)

        for index in 0..<3 {
            let y = 109 - CGFloat(index * 45)
            let checkBox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleItem(_:)))
            checkBox.tag = index
            checkBox.state = items[index].isDone ? .on : .off
            checkBox.isEnabled = !items[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            checkBox.frame = NSRect(x: 14, y: y + 3, width: 24, height: 24)
            contentView.addSubview(checkBox)
            checkBoxes.append(checkBox)

            let input = NSTextField(frame: NSRect(x: 42, y: y, width: 292, height: 29))
            input.tag = index
            input.stringValue = items[index].text
            input.placeholderString = "第 \(index + 1) 件事"
            input.isEditable = true
            input.isSelectable = true
            input.delegate = self
            input.menu = makeTextEditingMenu()
            if items[index].isDone {
                applyCompletedStyle(to: input, completed: true)
            }
            contentView.addSubview(input)
        }

        view = contentView
    }

    @objc private func toggleItem(_ sender: NSButton) {
        let index = sender.tag
        guard items.indices.contains(index) else { return }
        let text = items[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            sender.state = .off
            NSSound.beep()
            return
        }
        items[index].isDone = sender.state == .on
        if let input = view.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.tag == index && $0.isEditable }) {
            applyCompletedStyle(to: input, completed: items[index].isDone)
        }
        onChange(items)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let input = obj.object as? NSTextField, items.indices.contains(input.tag) else { return }
        items[input.tag].text = input.stringValue
        if input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items[input.tag].isDone = false
            applyCompletedStyle(to: input, completed: false)
        }
        checkBoxes[input.tag].isEnabled = !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        checkBoxes[input.tag].state = items[input.tag].isDone ? .on : .off
        onChange(items)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let input = obj.object as? NSTextField,
              items.indices.contains(input.tag) else { return }
        applyCompletedStyle(to: input, completed: items[input.tag].isDone)
    }

    private func applyCompletedStyle(to field: NSTextField, completed: Bool) {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: completed ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .strikethroughStyle: completed ? NSUnderlineStyle.single.rawValue : 0
        ]
        field.attributedStringValue = NSAttributedString(string: field.stringValue, attributes: attributes)
    }
}

private final class InspirationPopoverController: NSViewController, NSTextFieldDelegate {
    private var inspirations: [String]
    private let onChange: ([String]) -> Void

    init(inspirations: [String], onChange: @escaping ([String]) -> Void) {
        var normalized = Array(inspirations.prefix(5))
        while normalized.count < 5 {
            normalized.append("")
        }
        self.inspirations = normalized
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 286))

        let heading = NSTextField(labelWithString: "番茄内灵感速记")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.frame = NSRect(x: 16, y: 252, width: 318, height: 22)
        contentView.addSubview(heading)

        let hint = NSTextField(labelWithString: "随手写下，不打断当前专注 · 内容自动保存")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: 231, width: 318, height: 18)
        contentView.addSubview(hint)

        for index in 0..<5 {
            let y = 185 - CGFloat(index * 42)
            let marker = NSTextField(labelWithString: "\(index + 1)")
            marker.alignment = .center
            marker.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            marker.textColor = .secondaryLabelColor
            marker.frame = NSRect(x: 14, y: y + 5, width: 22, height: 18)
            contentView.addSubview(marker)

            let input = NSTextField(frame: NSRect(x: 42, y: y, width: 292, height: 29))
            input.tag = index
            input.stringValue = inspirations[index]
            input.placeholderString = index == 0 ? "刚冒出的想法……" : "再记一条灵感"
            input.isEditable = true
            input.isSelectable = true
            input.delegate = self
            input.menu = makeTextEditingMenu()
            input.focusRingType = .default
            contentView.addSubview(input)
        }

        view = contentView
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let input = obj.object as? NSTextField,
              inspirations.indices.contains(input.tag) else { return }
        inspirations[input.tag] = input.stringValue
        onChange(inspirations)
    }
}

private final class PetController: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private var focusSeconds = focusDuration
    private let restSeconds = restDuration

    private var window: NSPanel!
    private var rootView: DragView!
    private var petContainer: NSView!
    private var haloView: NSView!
    private var mascotView: NSImageView!
    private var idleMascotImage: NSImage?
    private var focusMascotImage: NSImage?
    private var restMascotImage: NSImage?
    private var timerLabel: NSTextField!
    private var taskBackdrop: NSView!
    private var taskLabel: NSTextField!
    private var expandButton: NSButton!
    private var inspirationButton: NSButton!
    private var actionButton: NSButton!
    private var taskPopover: NSPopover?
    private var inspirationPopover: NSPopover?
    private var tickTimer: Timer?

    private var stage: Stage = .idle
    private var secondsRemaining = focusDuration
    private var isRunning = false
    private var endDate: Date?
    private var currentTask = ""
    private var currentChecklist: [ChecklistItem] = []
    private var summaryDraft = ""
    private var nextChecklistDraft: [String] = ["", "", ""]
    private var nextTaskDraft = ""
    private var nextFocusSeconds = focusDuration
    private var inspirationBacklog: [String] = ["", "", "", "", ""]
    private var isReflectionPlannerOpen = false
    private var reflections: [Reflection] = []
    private var selectedMascot: MascotKind = .tomato

    func applicationDidFinishLaunching(_ notification: Notification) {
        closeOtherInstances()
        NSApp.setActivationPolicy(.regular)
        installApplicationMenu()
        loadState()
        buildWindow()
        render()
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        if stage == .focusDone {
            startJumping()
        } else if stage == .rest {
            startRestBreathing()
        } else if stage == .review {
            DispatchQueue.main.async { [weak self] in self?.showSummary() }
        } else if isRunning, let endDate, endDate <= Date() {
            tick()
        }
    }

    private func closeOtherInstances() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.codex.tomato-companion"
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID }

        for instance in otherInstances {
            if !instance.terminate() {
                instance.forceTerminate()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveState()
        tickTimer?.invalidate()
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu(title: "番茄伴伴")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = makeTextEditingMenu(includeShortcuts: true)
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        let designSize = NSSize(width: 330, height: 410)
        let size = NSSize(width: designSize.width / 2, height: designSize.height / 2)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.maxX - size.width - 28, y: visible.minY + 34)

        window = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = false

        rootView = DragView(frame: NSRect(origin: .zero, size: size))
        rootView.bounds = NSRect(origin: .zero, size: designSize)
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.menuProvider = { [weak self] in self?.makeContextMenu() ?? NSMenu() }
        window.contentView = rootView

        petContainer = NSView(frame: NSRect(x: 25, y: 98, width: 280, height: 300))
        petContainer.wantsLayer = true
        rootView.addSubview(petContainer)

        haloView = NSView(frame: NSRect(x: 15, y: 16, width: 250, height: 250))
        haloView.wantsLayer = true
        haloView.layer?.cornerRadius = 125
        haloView.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.22).cgColor
        haloView.layer?.shadowColor = NSColor(calibratedRed: 0.42, green: 0.14, blue: 0.10, alpha: 0.28).cgColor
        haloView.layer?.shadowOpacity = 1
        haloView.layer?.shadowRadius = 18
        haloView.layer?.shadowOffset = CGSize(width: 0, height: -8)
        petContainer.addSubview(haloView)

        mascotView = NSImageView(frame: NSRect(x: 10, y: 10, width: 260, height: 260))
        mascotView.wantsLayer = true
        mascotView.imageScaling = .scaleProportionallyUpOrDown
        mascotView.imageAlignment = .alignCenter
        loadMascotImages()
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let appIcon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = appIcon
        }
        petContainer.addSubview(mascotView)

        timerLabel = label(font: .monospacedDigitSystemFont(ofSize: 28, weight: .bold), color: .white)
        timerLabel.alignment = .center
        timerLabel.frame = NSRect(x: 69, y: 70, width: 142, height: 46)
        timerLabel.wantsLayer = true
        timerLabel.layer?.cornerRadius = 23
        timerLabel.layer?.backgroundColor = NSColor(calibratedRed: 0.62, green: 0.13, blue: 0.11, alpha: 0.91).cgColor
        timerLabel.layer?.borderWidth = 1
        timerLabel.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.68).cgColor
        timerLabel.layer?.shadowColor = NSColor.black.cgColor
        timerLabel.layer?.shadowOpacity = 0.16
        timerLabel.layer?.shadowRadius = 6
        timerLabel.layer?.shadowOffset = CGSize(width: 0, height: -3)
        petContainer.addSubview(timerLabel)

        let petInteraction = PetInteractionView(frame: petContainer.bounds)
        petInteraction.toolTip = "轻点操作，按住拖动"
        petInteraction.clickHandler = { [weak self] in self?.petClicked() }
        petInteraction.doubleClickHandler = { [weak self] in self?.petDoubleClicked() }
        petInteraction.menuProvider = { [weak self] in self?.makeContextMenu() ?? NSMenu() }
        petContainer.addSubview(petInteraction)

        taskBackdrop = NSView(frame: NSRect(x: 24, y: 24, width: 282, height: 64))
        taskBackdrop.wantsLayer = true
        taskBackdrop.layer?.cornerRadius = 16
        taskBackdrop.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.78).cgColor
        taskBackdrop.layer?.borderWidth = 1
        taskBackdrop.layer?.borderColor = NSColor(calibratedRed: 0.48, green: 0.25, blue: 0.20, alpha: 0.13).cgColor
        taskBackdrop.layer?.shadowColor = NSColor.black.cgColor
        taskBackdrop.layer?.shadowOpacity = 0.08
        taskBackdrop.layer?.shadowRadius = 7
        taskBackdrop.layer?.shadowOffset = CGSize(width: 0, height: -2)
        rootView.addSubview(taskBackdrop)

        let roundedDescriptor = NSFont.systemFont(ofSize: 21, weight: .semibold).fontDescriptor.withDesign(.rounded)
        let taskFont = roundedDescriptor.flatMap { NSFont(descriptor: $0, size: 21) } ?? .systemFont(ofSize: 21, weight: .semibold)
        taskLabel = label(font: taskFont, color: NSColor(calibratedRed: 0.25, green: 0.14, blue: 0.12, alpha: 0.90))
        taskLabel.alignment = .center
        taskLabel.lineBreakMode = .byWordWrapping
        taskLabel.usesSingleLineMode = false
        taskLabel.maximumNumberOfLines = 3
        taskLabel.cell?.wraps = true
        taskLabel.frame = NSRect(x: 35, y: 31, width: 260, height: 50)
        rootView.addSubview(taskLabel)

        expandButton = NSButton(frame: NSRect(x: 242, y: 37, width: 62, height: 36))
        expandButton.title = "清单"
        expandButton.bezelStyle = .rounded
        expandButton.controlSize = .small
        expandButton.font = .systemFont(ofSize: 12, weight: .semibold)
        expandButton.contentTintColor = NSColor(calibratedRed: 0.46, green: 0.13, blue: 0.11, alpha: 0.92)
        expandButton.toolTip = "展开查看完整的当前番茄计划"
        expandButton.target = self
        expandButton.action = #selector(showFullTask)
        expandButton.isHidden = true
        rootView.addSubview(expandButton)

        inspirationButton = NSButton(frame: NSRect(x: 242, y: 37, width: 62, height: 36))
        inspirationButton.title = "灵感"
        inspirationButton.bezelStyle = .rounded
        inspirationButton.controlSize = .small
        inspirationButton.font = .systemFont(ofSize: 12, weight: .semibold)
        inspirationButton.contentTintColor = NSColor(calibratedRed: 0.46, green: 0.13, blue: 0.11, alpha: 0.92)
        inspirationButton.toolTip = "在当前番茄内随手记录灵感"
        inspirationButton.target = self
        inspirationButton.action = #selector(showInspirations)
        inspirationButton.isHidden = true
        rootView.addSubview(inspirationButton)

        actionButton = NSButton(frame: NSRect(x: 55, y: 24, width: 220, height: 40))
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.font = .systemFont(ofSize: 13, weight: .semibold)
        actionButton.contentTintColor = .white
        actionButton.wantsLayer = true
        actionButton.layer?.cornerRadius = 14
        actionButton.layer?.backgroundColor = NSColor(calibratedRed: 0.80, green: 0.20, blue: 0.16, alpha: 0.96).cgColor
        actionButton.target = self
        actionButton.action = #selector(primaryAction)
        rootView.addSubview(actionButton)

        let closeButton = NSButton(frame: NSRect(x: 296, y: 376, width: 24, height: 24))
        closeButton.title = "×"
        closeButton.font = .systemFont(ofSize: 18, weight: .medium)
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor(calibratedWhite: 0.12, alpha: 0.46)
        closeButton.toolTip = "退出番茄伴伴"
        closeButton.target = NSApp
        closeButton.action = #selector(NSApplication.terminate(_:))
        rootView.addSubview(closeButton)

        window.orderFrontRegardless()
    }

    private func label(font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.textColor = color
        field.backgroundColor = .clear
        field.isBordered = false
        field.isEditable = false
        field.isSelectable = false
        return field
    }

    private func bundledImage(named name: String) -> NSImage? {
        guard let imageURL = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: imageURL)
    }

    private func loadMascotImages() {
        if selectedMascot == .tomato {
            idleMascotImage = bundledImage(named: "tomato-pet")
            focusMascotImage = bundledImage(named: "tomato-focus") ?? idleMascotImage
            restMascotImage = bundledImage(named: "tomato-rest") ?? idleMascotImage
        } else {
            let image = bundledImage(named: selectedMascot.assetName)
            idleMascotImage = image
            focusMascotImage = image
            restMascotImage = image
        }
        mascotView?.image = idleMascotImage
    }

    private func normalizedChecklist(_ items: [ChecklistItem]) -> [ChecklistItem] {
        var normalized = Array(items.prefix(3))
        while normalized.count < 3 {
            normalized.append(ChecklistItem(text: "", isDone: false))
        }
        return normalized
    }

    private func normalizedPlanDraft(_ items: [String]) -> [String] {
        var normalized = Array(items.prefix(3))
        while normalized.count < 3 { normalized.append("") }
        return normalized
    }

    private func normalizedInspirations(_ items: [String]) -> [String] {
        var normalized = Array(items.prefix(5))
        while normalized.count < 5 { normalized.append("") }
        return normalized
    }

    private func syncCurrentTaskFromChecklist() {
        currentChecklist = normalizedChecklist(currentChecklist)
        currentTask = currentChecklist
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func checklistTexts(completed: Bool) -> [String] {
        currentChecklist.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && item.isDone == completed ? text : nil
        }
    }

    private func automaticSummaryDraft() -> String {
        let completed = checklistTexts(completed: true)
        let incomplete = checklistTexts(completed: false)
        var sections: [String] = []

        if !completed.isEmpty {
            sections.append("已完成：\n" + completed.map { "✓ \($0)" }.joined(separator: "\n"))
        }
        if !incomplete.isEmpty {
            sections.append("待继续：\n" + incomplete.map { "• \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    @objc private func tick() {
        guard isRunning, let endDate else { return }
        secondsRemaining = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        render()

        guard secondsRemaining == 0 else { return }
        isRunning = false
        self.endDate = nil

        switch stage {
        case .focus:
            stage = .focusDone
            notifyCompletion(title: "专注完成", message: "点一下小番茄，开始 10 分钟休息。")
            startJumping()
        case .rest:
            stage = .review
            notifyCompletion(title: "休息完成", message: "检查总结和下一颗计划，然后继续。")
            saveState()
            render()
            if !isReflectionPlannerOpen {
                DispatchQueue.main.async { [weak self] in self?.showSummary() }
            }
        default:
            break
        }
        saveState()
        render()
    }

    private func notifyCompletion(title: String, message: String) {
        NSSound(named: NSSound.Name("Glass"))?.play()
        window.orderFrontRegardless()
        window.alphaValue = 1
        taskLabel.stringValue = message
    }

    @objc private func petClicked() {
        switch stage {
        case .idle:
            askForTask()
        case .focus, .rest:
            togglePause()
        case .focusDone:
            startRest()
        case .review:
            showSummary()
        }
    }

    private func petDoubleClicked() {
        if stage == .idle {
            askForCustomSession()
        } else {
            petClicked()
        }
    }

    @objc private func primaryAction() {
        switch stage {
        case .idle:
            askForTask()
        case .focus:
            togglePause()
        case .rest:
            showSummary()
        case .focusDone:
            startRest()
        case .review:
            showSummary()
        }
    }

    private func askForTask() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "这颗番茄要做什么？"
        alert.informativeText = "写下一件小事，接下来只专注它 50 分钟。"
        alert.addButton(withTitle: "开始专注")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 30))
        input.placeholderString = "例如：完成方案的第一版提纲"
        input.stringValue = currentTask
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let task = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            NSSound.beep()
            askForTask()
            return
        }

        currentTask = task
        currentChecklist = normalizedChecklist([ChecklistItem(text: task, isDone: false)])
        focusSeconds = focusDuration
        summaryDraft = ""
        nextChecklistDraft = ["", "", ""]
        nextTaskDraft = ""
        nextFocusSeconds = focusSeconds
        stage = .focus
        secondsRemaining = focusSeconds
        isRunning = true
        endDate = Date().addingTimeInterval(TimeInterval(focusSeconds))
        stopJumping()
        saveState()
        render()
    }

    private func askForCustomSession() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "自定义这颗番茄"
        alert.informativeText = "默认是 50 分钟。修改后按 Enter 直接开始。"
        alert.addButton(withTitle: "开始专注")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.keyEquivalent = "\r"

        let form = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 82))
        let taskCaption = label(font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)
        taskCaption.stringValue = "本次目标"
        taskCaption.frame = NSRect(x: 0, y: 58, width: 70, height: 18)
        form.addSubview(taskCaption)

        let taskInput = NSTextField(frame: NSRect(x: 78, y: 52, width: 272, height: 28))
        taskInput.placeholderString = "例如：完成方案第一版"
        taskInput.stringValue = currentTask
        form.addSubview(taskInput)

        let timeCaption = label(font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)
        timeCaption.stringValue = "专注时长"
        timeCaption.frame = NSRect(x: 0, y: 12, width: 70, height: 18)
        form.addSubview(timeCaption)

        let minutesInput = NSTextField(frame: NSRect(x: 78, y: 6, width: 74, height: 28))
        minutesInput.alignment = .center
        minutesInput.stringValue = String(max(1, focusSeconds / 60))
        minutesInput.placeholderString = "50"
        form.addSubview(minutesInput)

        let minutesSuffix = label(font: .systemFont(ofSize: 12, weight: .regular), color: .secondaryLabelColor)
        minutesSuffix.stringValue = "分钟（1–180）"
        minutesSuffix.frame = NSRect(x: 160, y: 11, width: 120, height: 18)
        form.addSubview(minutesSuffix)

        alert.accessoryView = form
        alert.window.initialFirstResponder = taskInput

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let task = taskInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let minutesText = minutesInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, let minutes = Int(minutesText), (1...180).contains(minutes) else {
            NSSound.beep()
            askForCustomSession()
            return
        }

        currentTask = task
        currentChecklist = normalizedChecklist([ChecklistItem(text: task, isDone: false)])
        focusSeconds = minutes * 60
        summaryDraft = ""
        nextChecklistDraft = ["", "", ""]
        nextTaskDraft = ""
        nextFocusSeconds = focusSeconds
        stage = .focus
        secondsRemaining = focusSeconds
        isRunning = true
        endDate = Date().addingTimeInterval(TimeInterval(focusSeconds))
        stopJumping()
        saveState()
        render()
    }

    private func startRest() {
        guard stage == .focusDone else { return }
        stopJumping()
        if summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summaryDraft = automaticSummaryDraft()
        }
        let incompleteItems = checklistTexts(completed: false)
        nextChecklistDraft = normalizedPlanDraft(incompleteItems)
        nextTaskDraft = incompleteItems.joined(separator: "\n")
        nextFocusSeconds = focusSeconds
        stage = .rest
        secondsRemaining = restSeconds
        isRunning = true
        endDate = Date().addingTimeInterval(TimeInterval(restSeconds))
        saveState()
        render()
    }

    @objc private func togglePause() {
        guard stage == .focus || stage == .rest else { return }
        if isRunning {
            if let endDate {
                secondsRemaining = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
            }
            isRunning = false
            endDate = nil
        } else if secondsRemaining > 0 {
            isRunning = true
            endDate = Date().addingTimeInterval(TimeInterval(secondsRemaining))
        }
        saveState()
        render()
    }

    @objc private func resetSession() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "重新开始这颗番茄？"
        alert.informativeText = "当前倒计时会被清除，已经保存的小结不会丢失。"
        alert.addButton(withTitle: "重新开始")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        stopJumping()
        stage = .idle
        focusSeconds = focusDuration
        secondsRemaining = focusSeconds
        isRunning = false
        endDate = nil
        currentTask = ""
        currentChecklist = []
        summaryDraft = ""
        nextChecklistDraft = ["", "", ""]
        nextTaskDraft = ""
        nextFocusSeconds = focusDuration
        saveState()
        render()
    }

    @objc private func showSummary() {
        guard stage == .rest || stage == .review, !isReflectionPlannerOpen else { return }
        isReflectionPlannerOpen = true
        defer { isReflectionPlannerOpen = false }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        while true {
            let mustStartNext = stage == .review
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = mustStartNext ? "回看一下，再开始下一颗" : "边休息，边总结和规划"
            let previousItems = currentChecklist.compactMap { item -> String? in
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            let previewText = previousItems.prefix(2).joined(separator: " · ")
            let boundedPreview = String(previewText.prefix(72))
            let moreHint = previousItems.count > 2 || previewText.count > 72 ? "…（共 \(previousItems.count) 项）" : ""
            alert.informativeText = "上一颗：\(boundedPreview)\(moreHint)\n完整勾选结果已折叠在下方总结框中，底部保存按钮会始终保留。"
            alert.addButton(withTitle: mustStartNext ? "保存并开始下一颗" : "保存草稿")
            if !mustStartNext {
                alert.addButton(withTitle: "取消")
            }

            let form = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 520))

            let summaryCaption = label(font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
            summaryCaption.stringValue = "本小时总结（支持选择、复制和粘贴）"
            summaryCaption.frame = NSRect(x: 0, y: 494, width: 300, height: 20)
            form.addSubview(summaryCaption)

            let scroll = NSScrollView(frame: NSRect(x: 0, y: 382, width: 440, height: 106))
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.wantsLayer = true
            scroll.layer?.cornerRadius = 7
            scroll.layer?.borderWidth = 1
            scroll.layer?.borderColor = NSColor.separatorColor.cgColor
            scroll.layer?.masksToBounds = true

            let textView = PlaceholderTextView(frame: scroll.bounds)
            textView.font = .systemFont(ofSize: 14)
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.placeholderString = "点击这里，写下完成了什么、遇到的卡点或下一步……"
            textView.isEditable = true
            textView.isSelectable = true
            textView.isRichText = false
            textView.allowsUndo = true
            textView.focusRingType = .none
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            textView.menu = makeTextEditingMenu()
            textView.string = summaryDraft
            scroll.documentView = textView
            form.addSubview(scroll)

            let nextCaption = label(font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
            nextCaption.stringValue = "下一颗番茄 · 最多 3 件事"
            nextCaption.frame = NSRect(x: 0, y: 350, width: 220, height: 20)
            form.addSubview(nextCaption)

            var planDraft = normalizedPlanDraft(nextChecklistDraft)
            if planDraft.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), !nextTaskDraft.isEmpty {
                planDraft[0] = nextTaskDraft
            }
            var nextPlanInputs: [NSTextField] = []
            for index in 0..<3 {
                let y = 306 - CGFloat(index * 36)
                let number = label(font: .systemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor)
                number.stringValue = "\(index + 1)."
                number.alignment = .right
                number.frame = NSRect(x: 0, y: y + 5, width: 24, height: 18)
                form.addSubview(number)

                let input = NSTextField(frame: NSRect(x: 32, y: y, width: 408, height: 28))
                input.placeholderString = index == 0 ? "例如：根据刚才的小结完成下一步" : "可选计划"
                input.stringValue = planDraft[index]
                input.isEditable = true
                input.isSelectable = true
                input.focusRingType = .default
                input.menu = makeTextEditingMenu()
                form.addSubview(input)
                nextPlanInputs.append(input)
            }

            let timeCaption = label(font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)
            timeCaption.stringValue = "专注时长"
            timeCaption.frame = NSRect(x: 0, y: 202, width: 70, height: 20)
            form.addSubview(timeCaption)

            let minutesInput = NSTextField(frame: NSRect(x: 72, y: 197, width: 70, height: 28))
            minutesInput.alignment = .center
            minutesInput.stringValue = String(max(1, nextFocusSeconds / 60))
            minutesInput.isEditable = true
            minutesInput.isSelectable = true
            minutesInput.menu = makeTextEditingMenu()
            form.addSubview(minutesInput)

            let minutesSuffix = label(font: .systemFont(ofSize: 12, weight: .regular), color: .secondaryLabelColor)
            minutesSuffix.stringValue = "分钟（1–180，可在开始前修改）"
            minutesSuffix.frame = NSRect(x: 150, y: 202, width: 240, height: 20)
            form.addSubview(minutesSuffix)

            let inspirationCaption = label(font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
            inspirationCaption.stringValue = "灵感清单 · 勾选即可加入上方计划"
            inspirationCaption.frame = NSRect(x: 0, y: 166, width: 300, height: 20)
            form.addSubview(inspirationCaption)

            let inspirationDraft = normalizedInspirations(inspirationBacklog)
            var inspirationInputs: [NSTextField] = []
            var inspirationCheckBoxes: [ClosureCheckBox] = []
            for index in 0..<5 {
                let y = 128 - CGFloat(index * 31)
                let checkBox = ClosureCheckBox(frame: NSRect(x: 0, y: y + 2, width: 24, height: 24))
                checkBox.toolTip = "勾选后加入下一颗番茄"

                let input = NSTextField(frame: NSRect(x: 30, y: y, width: 410, height: 26))
                input.placeholderString = "记录一个稍后想做的灵感"
                input.stringValue = inspirationDraft[index]
                input.isEditable = true
                input.isSelectable = true
                input.menu = makeTextEditingMenu()
                form.addSubview(checkBox)
                form.addSubview(input)
                inspirationInputs.append(input)
                inspirationCheckBoxes.append(checkBox)

                if !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   nextPlanInputs.contains(where: { $0.stringValue == input.stringValue }) {
                    checkBox.state = .on
                }

                checkBox.onToggle = { button in
                    guard button.state == .on else { return }
                    let inspiration = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !inspiration.isEmpty else {
                        button.state = .off
                        NSSound.beep()
                        return
                    }
                    if nextPlanInputs.contains(where: {
                        $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == inspiration
                    }) {
                        return
                    }
                    guard let emptyInput = nextPlanInputs.first(where: {
                        $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }) else {
                        button.state = .off
                        NSSound.beep()
                        return
                    }
                    emptyInput.stringValue = inspiration
                    let remainingInspirations = inspirationInputs.enumerated().compactMap { offset, field -> String? in
                        guard offset != index else { return nil }
                        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        return value.isEmpty ? nil : value
                    }
                    for inspirationIndex in inspirationInputs.indices {
                        inspirationInputs[inspirationIndex].stringValue = inspirationIndex < remainingInspirations.count
                            ? remainingInspirations[inspirationIndex]
                            : ""
                    }
                    inspirationCheckBoxes.forEach { $0.state = .off }
                }
            }

            let formViewport = NSScrollView(frame: NSRect(x: 0, y: 0, width: 458, height: 400))
            formViewport.hasVerticalScroller = true
            formViewport.autohidesScrollers = false
            formViewport.borderType = .noBorder
            formViewport.drawsBackground = false
            formViewport.documentView = form
            alert.accessoryView = formViewport
            formViewport.contentView.scroll(
                to: NSPoint(x: 0, y: max(0, form.bounds.height - formViewport.contentView.bounds.height))
            )
            formViewport.reflectScrolledClipView(formViewport.contentView)
            alert.window.initialFirstResponder = textView

            let response = alert.runModal()
            if response != .alertFirstButtonReturn {
                if stage == .review {
                    NSSound.beep()
                    continue
                }
                return
            }

            let note = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let plannedItems = nextPlanInputs
                .map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let minutesText = minutesInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let minutes = Int(minutesText), (1...180).contains(minutes) else {
                NSSound.beep()
                continue
            }

            summaryDraft = note
            nextChecklistDraft = normalizedPlanDraft(plannedItems)
            nextTaskDraft = plannedItems.joined(separator: "\n")
            nextFocusSeconds = minutes * 60
            inspirationBacklog = normalizedInspirations(inspirationInputs.map {
                $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            })

            if stage == .rest {
                saveState()
                render()
                return
            }

            guard stage == .review, !summaryDraft.isEmpty, !plannedItems.isEmpty else {
                NSSound.beep()
                continue
            }

            reflections.insert(
                Reflection(
                    date: Date(),
                    task: currentTask,
                    note: summaryDraft,
                    completedItems: checklistTexts(completed: true),
                    incompleteItems: checklistTexts(completed: false)
                ),
                at: 0
            )
            if reflections.count > 30 { reflections = Array(reflections.prefix(30)) }

            currentChecklist = normalizedChecklist(plannedItems.map { ChecklistItem(text: $0, isDone: false) })
            syncCurrentTaskFromChecklist()
            focusSeconds = nextFocusSeconds
            secondsRemaining = focusSeconds
            stage = .focus
            isRunning = true
            endDate = Date().addingTimeInterval(TimeInterval(focusSeconds))
            summaryDraft = ""
            nextChecklistDraft = ["", "", ""]
            nextTaskDraft = ""
            nextFocusSeconds = focusSeconds
            saveState()
            render()
            return
        }
    }

    @objc private func showHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "我的小时小结"
        alert.informativeText = reflections.isEmpty ? "完成一轮专注与休息后，小结会保存在这里。" : "最近 \(reflections.count) 条记录"
        alert.addButton(withTitle: "完成")

        if !reflections.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 HH:mm"
            let text = reflections.prefix(20).map {
                "\(formatter.string(from: $0.date))  ·  \($0.task)\n\($0.note)"
            }.joined(separator: "\n\n")

            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            let textView = NSTextView(frame: scroll.bounds)
            textView.font = .systemFont(ofSize: 13)
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.isEditable = false
            textView.drawsBackground = false
            textView.string = text
            scroll.documentView = textView
            alert.accessoryView = scroll
        }
        alert.runModal()
    }

    @objc private func showDailySummary() {
        NSApp.activate(ignoringOtherApps: true)

        let calendar = Calendar.current
        let todayReflections = reflections.filter { calendar.isDateInToday($0.date) }
        var completed = todayReflections.flatMap { $0.completedItems ?? [] }
        var incomplete = todayReflections.flatMap { $0.incompleteItems ?? [] }

        if stage != .idle {
            completed.append(contentsOf: checklistTexts(completed: true))
            incomplete.append(contentsOf: checklistTexts(completed: false))
        }

        func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !seen.contains(trimmed) else { return false }
                seen.insert(trimmed)
                return true
            }
        }

        completed = unique(completed)
        incomplete = unique(incomplete).filter { !completed.contains($0) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"

        var sections = ["\(formatter.string(from: Date())) · 今日总结", "完成番茄：\(todayReflections.count) 轮"]
        if !completed.isEmpty {
            sections.append("已完成\n" + completed.map { "✓ \($0)" }.joined(separator: "\n"))
        }
        if !incomplete.isEmpty {
            sections.append("待继续\n" + incomplete.map { "• \($0)" }.joined(separator: "\n"))
        }

        let notes = unique(todayReflections.map(\.note))
        if !notes.isEmpty {
            sections.append("复盘摘录\n" + notes.joined(separator: "\n\n"))
        }

        let summary = sections.joined(separator: "\n\n")
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "今日自动总结"
        alert.informativeText = "已根据今天勾选的任务和小时复盘自动整理，可继续编辑后复制。"
        alert.addButton(withTitle: "复制全部")
        alert.addButton(withTitle: "关闭")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.menu = makeTextEditingMenu()
        textView.string = summary
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = textView

        if alert.runModal() == .alertFirstButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(textView.string, forType: .string)
        }
    }

    @objc private func showFullTask() {
        guard stage == .focus else { return }

        inspirationPopover?.close()
        if let taskPopover, taskPopover.isShown {
            taskPopover.close()
            return
        }

        currentChecklist = normalizedChecklist(currentChecklist)
        let statusText = "剩余 \(format(secondsRemaining))\(isRunning ? "" : " · 已暂停")"
        let controller = ChecklistPopoverController(
            items: currentChecklist,
            statusText: statusText
        ) { [weak self] updatedItems in
            guard let self else { return }
            self.currentChecklist = self.normalizedChecklist(updatedItems)
            self.syncCurrentTaskFromChecklist()
            self.saveState()
            self.render()
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 350, height: 206)
        popover.contentViewController = controller
        popover.show(relativeTo: expandButton.bounds, of: expandButton, preferredEdge: .maxY)
        taskPopover = popover
    }

    @objc private func showInspirations() {
        guard stage == .focus else { return }

        taskPopover?.close()
        if let inspirationPopover, inspirationPopover.isShown {
            inspirationPopover.close()
            return
        }

        inspirationBacklog = normalizedInspirations(inspirationBacklog)
        let controller = InspirationPopoverController(
            inspirations: inspirationBacklog
        ) { [weak self] updatedInspirations in
            guard let self else { return }
            self.inspirationBacklog = self.normalizedInspirations(updatedInspirations)
            self.saveState()
            self.render()
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 350, height: 286)
        popover.contentViewController = controller
        popover.show(relativeTo: inspirationButton.bounds, of: inspirationButton, preferredEdge: .maxY)
        inspirationPopover = popover
    }

    private func startJumping() {
        guard petContainer.layer?.animation(forKey: "tomatoJump") == nil else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        animation.values = [0, 25, 0, 12, 0]
        animation.keyTimes = [0, 0.22, 0.48, 0.66, 1]
        animation.duration = 0.78
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        petContainer.layer?.add(animation, forKey: "tomatoJump")
    }

    private func stopJumping() {
        petContainer.layer?.removeAnimation(forKey: "tomatoJump")
    }

    private func startRestBreathing() {
        guard mascotView.layer?.animation(forKey: "restBreathing") == nil else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, 1.025, 1.0]
        animation.keyTimes = [0, 0.5, 1]
        animation.duration = 2.6
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mascotView.layer?.add(animation, forKey: "restBreathing")
    }

    private func stopRestBreathing() {
        mascotView.layer?.removeAnimation(forKey: "restBreathing")
    }

    private func applyFocusPalette() {
        mascotView.image = focusMascotImage
        timerLabel.layer?.backgroundColor = NSColor(calibratedRed: 0.58, green: 0.10, blue: 0.09, alpha: 0.93).cgColor
        taskBackdrop.layer?.backgroundColor = NSColor(calibratedRed: 1.00, green: 0.94, blue: 0.87, alpha: 0.88).cgColor
        taskBackdrop.layer?.borderColor = NSColor(calibratedRed: 0.62, green: 0.18, blue: 0.13, alpha: 0.18).cgColor
        taskLabel.textColor = NSColor(calibratedRed: 0.29, green: 0.12, blue: 0.10, alpha: 0.94)
        haloView.layer?.backgroundColor = NSColor(calibratedRed: 1.00, green: 0.82, blue: 0.66, alpha: 0.24).cgColor
        haloView.layer?.shadowColor = NSColor(calibratedRed: 0.52, green: 0.12, blue: 0.08, alpha: 0.28).cgColor
    }

    private func applyRestPalette() {
        mascotView.image = restMascotImage
        timerLabel.layer?.backgroundColor = NSColor(calibratedRed: 0.18, green: 0.43, blue: 0.27, alpha: 0.93).cgColor
        taskBackdrop.layer?.backgroundColor = NSColor(calibratedRed: 0.89, green: 0.98, blue: 0.89, alpha: 0.90).cgColor
        taskBackdrop.layer?.borderColor = NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.29, alpha: 0.20).cgColor
        taskLabel.textColor = NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.17, alpha: 0.94)
        haloView.layer?.backgroundColor = NSColor(calibratedRed: 0.67, green: 0.91, blue: 0.67, alpha: 0.25).cgColor
        haloView.layer?.shadowColor = NSColor(calibratedRed: 0.15, green: 0.43, blue: 0.23, alpha: 0.28).cgColor
    }

    private func applyIdlePalette() {
        mascotView.image = idleMascotImage
        timerLabel.layer?.backgroundColor = NSColor(calibratedRed: 0.62, green: 0.13, blue: 0.11, alpha: 0.91).cgColor
        taskBackdrop.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.78).cgColor
        taskBackdrop.layer?.borderColor = NSColor(calibratedRed: 0.48, green: 0.25, blue: 0.20, alpha: 0.13).cgColor
        taskLabel.textColor = NSColor(calibratedRed: 0.25, green: 0.14, blue: 0.12, alpha: 0.90)
        haloView.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.22).cgColor
        haloView.layer?.shadowColor = NSColor(calibratedRed: 0.42, green: 0.14, blue: 0.10, alpha: 0.28).cgColor
    }

    private func render() {
        timerLabel.stringValue = format(secondsRemaining)
        actionButton.isHidden = false
        expandButton.isHidden = true
        inspirationButton.isHidden = true
        taskBackdrop.isHidden = false
        taskLabel.frame = NSRect(x: 35, y: 31, width: 260, height: 50)

        if stage != .focus {
            taskPopover?.close()
            inspirationPopover?.close()
        }

        switch stage {
        case .idle:
            stopRestBreathing()
            applyIdlePalette()
            taskLabel.stringValue = "单击开始 · 双击自定时长 · 按住拖动"
            taskLabel.toolTip = "单击按默认 50 分钟开始；双击可修改分钟数；按住番茄拖动即可移动"
            taskLabel.font = .systemFont(ofSize: 13, weight: .medium)
            taskLabel.frame = NSRect(x: 38, y: 70, width: 254, height: 22)
            taskBackdrop.isHidden = true
            actionButton.title = "写下任务 · 开始专注"
            actionButton.layer?.backgroundColor = NSColor(calibratedRed: 0.80, green: 0.20, blue: 0.16, alpha: 0.96).cgColor
        case .focus:
            stopRestBreathing()
            applyFocusPalette()
            let activeItems = currentChecklist.filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let doneCount = activeItems.filter { $0.isDone }.count
            let preview = activeItems.isEmpty
                ? "点击清单添加任务"
                : (activeItems.first(where: { !$0.isDone })?.text ?? "全部完成 ✓")
            let progressText = "\(doneCount)/\(activeItems.isEmpty ? 3 : activeItems.count) · \(preview)"
            taskLabel.stringValue = isRunning ? progressText : "已暂停 · \(progressText)"
            taskLabel.toolTip = activeItems.map { "\($0.isDone ? "☑" : "☐") \($0.text)" }.joined(separator: "\n")
            taskLabel.font = roundedTaskFont()
            taskLabel.frame = NSRect(x: 35, y: 31, width: 142, height: 50)
            expandButton.frame = NSRect(x: 180, y: 37, width: 58, height: 36)
            inspirationButton.frame = NSRect(x: 242, y: 37, width: 62, height: 36)
            expandButton.isHidden = false
            let inspirationCount = inspirationBacklog.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
            inspirationButton.title = inspirationCount > 0 ? "灵感·\(inspirationCount)" : "灵感"
            inspirationButton.isHidden = false
            actionButton.isHidden = true
            actionButton.layer?.backgroundColor = NSColor(calibratedRed: 0.80, green: 0.20, blue: 0.16, alpha: 0.96).cgColor
        case .focusDone:
            stopRestBreathing()
            applyFocusPalette()
            taskLabel.stringValue = "专注完成！点点我，开始休息"
            taskLabel.toolTip = currentTask
            taskLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            taskLabel.frame = NSRect(x: 38, y: 70, width: 254, height: 22)
            taskBackdrop.isHidden = true
            actionButton.title = "开始 10 分钟休息"
            actionButton.layer?.backgroundColor = NSColor(calibratedRed: 0.29, green: 0.51, blue: 0.34, alpha: 0.96).cgColor
        case .rest:
            applyRestPalette()
            startRestBreathing()
            let elapsed = restSeconds - secondsRemaining
            let tips = ["站起来伸个懒腰", "接杯水，走几步", "看看远处，放松眼睛", "停下手上的事，回顾进展"]
            let tip = tips[max(0, elapsed / 15) % tips.count]
            taskLabel.stringValue = isRunning ? tip : "已暂停 · \(tip)"
            taskLabel.toolTip = tip
            taskLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            taskLabel.frame = NSRect(x: 38, y: 70, width: 254, height: 22)
            taskBackdrop.isHidden = true
            actionButton.title = "总结 · 规划下一颗"
            actionButton.layer?.backgroundColor = NSColor(calibratedRed: 0.29, green: 0.51, blue: 0.34, alpha: 0.96).cgColor
        case .review:
            stopRestBreathing()
            applyRestPalette()
            taskLabel.stringValue = "休息结束 · 核对总结与下一颗"
            taskLabel.toolTip = currentTask
            taskLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            taskLabel.frame = NSRect(x: 38, y: 70, width: 254, height: 22)
            taskBackdrop.isHidden = true
            actionButton.title = "核对并开始下一颗"
            actionButton.layer?.backgroundColor = NSColor(calibratedRed: 0.29, green: 0.51, blue: 0.34, alpha: 0.96).cgColor
        }
    }

    private func roundedTaskFont() -> NSFont {
        let descriptor = NSFont.systemFont(ofSize: 21, weight: .semibold).fontDescriptor.withDesign(.rounded)
        return descriptor.flatMap { NSFont(descriptor: $0, size: 21) } ?? .systemFont(ofSize: 21, weight: .semibold)
    }

    private func format(_ seconds: Int) -> String {
        String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "番茄伴伴")
        let primaryTitle: String
        let primarySelector: Selector

        switch stage {
        case .idle:
            primaryTitle = "开始一颗番茄"
            primarySelector = #selector(primaryAction)
        case .focus, .rest:
            primaryTitle = isRunning ? "暂停" : "继续"
            primarySelector = #selector(togglePause)
        case .focusDone:
            primaryTitle = "开始 10 分钟休息"
            primarySelector = #selector(primaryAction)
        case .review:
            primaryTitle = "核对总结与下一颗"
            primarySelector = #selector(primaryAction)
        }

        let primary = NSMenuItem(title: primaryTitle, action: primarySelector, keyEquivalent: "")
        primary.target = self
        menu.addItem(primary)

        if stage == .focus {
            let showTask = NSMenuItem(title: "查看或编辑当前清单", action: #selector(showFullTask), keyEquivalent: "")
            showTask.target = self
            menu.addItem(showTask)

            let captureInspiration = NSMenuItem(title: "记录灵感", action: #selector(showInspirations), keyEquivalent: "")
            captureInspiration.target = self
            menu.addItem(captureInspiration)
        }

        if stage == .rest {
            let planNext = NSMenuItem(title: "总结并规划下一颗", action: #selector(showSummary), keyEquivalent: "")
            planNext.target = self
            menu.addItem(planNext)
        }

        let reset = NSMenuItem(title: "重新开始", action: #selector(resetSession), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = stage != .idle
        menu.addItem(reset)

        menu.addItem(.separator())
        let mascotMenu = NSMenu(title: "选择蔬菜形象")
        for mascot in MascotKind.allCases {
            let item = NSMenuItem(title: mascot.displayName, action: #selector(selectMascot(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mascot.rawValue
            item.state = mascot == selectedMascot ? .on : .off
            mascotMenu.addItem(item)
        }
        let mascotItem = NSMenuItem(title: "选择蔬菜形象", action: nil, keyEquivalent: "")
        mascotItem.submenu = mascotMenu
        menu.addItem(mascotItem)

        let history = NSMenuItem(title: "查看小时小结", action: #selector(showHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        let dailySummary = NSMenuItem(title: "生成今日总结", action: #selector(showDailySummary), keyEquivalent: "")
        dailySummary.target = self
        menu.addItem(dailySummary)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出番茄伴伴", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    @objc private func selectMascot(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mascot = MascotKind(rawValue: rawValue) else { return }
        selectedMascot = mascot
        loadMascotImages()
        saveState()
        render()
    }

    private func saveState() {
        defaults.set(stage.rawValue, forKey: "stage")
        defaults.set(secondsRemaining, forKey: "secondsRemaining")
        defaults.set(isRunning, forKey: "isRunning")
        defaults.set(endDate?.timeIntervalSince1970, forKey: "endDate")
        defaults.set(currentTask, forKey: "currentTask")
        defaults.set(focusSeconds, forKey: "focusSeconds")
        defaults.set(summaryDraft, forKey: "summaryDraft")
        defaults.set(nextTaskDraft, forKey: "nextTaskDraft")
        defaults.set(nextChecklistDraft, forKey: "nextChecklistDraft")
        defaults.set(nextFocusSeconds, forKey: "nextFocusSeconds")
        defaults.set(inspirationBacklog, forKey: "inspirationBacklog")
        defaults.set(selectedMascot.rawValue, forKey: "selectedMascot")
        if let data = try? JSONEncoder().encode(currentChecklist) {
            defaults.set(data, forKey: "currentChecklist")
        }
        if let data = try? JSONEncoder().encode(reflections) {
            defaults.set(data, forKey: "reflections")
        }
    }

    private func loadState() {
        if let raw = defaults.string(forKey: "selectedMascot"),
           let savedMascot = MascotKind(rawValue: raw) {
            selectedMascot = savedMascot
        }
        if let raw = defaults.string(forKey: "stage"), let savedStage = Stage(rawValue: raw) {
            stage = savedStage
        }
        isRunning = defaults.bool(forKey: "isRunning")
        let timestamp = defaults.double(forKey: "endDate")
        endDate = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        currentTask = defaults.string(forKey: "currentTask") ?? ""
        if let data = defaults.data(forKey: "currentChecklist"),
           let savedChecklist = try? JSONDecoder().decode([ChecklistItem].self, from: data) {
            currentChecklist = normalizedChecklist(savedChecklist)
        } else {
            let legacyItems = currentTask
                .split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: true)
                .map { ChecklistItem(text: String($0), isDone: false) }
            currentChecklist = normalizedChecklist(legacyItems)
        }
        syncCurrentTaskFromChecklist()
        let savedFocusSeconds = defaults.integer(forKey: "focusSeconds")
        focusSeconds = savedFocusSeconds > 0 ? savedFocusSeconds : focusDuration
        let savedSeconds = defaults.integer(forKey: "secondsRemaining")
        secondsRemaining = savedSeconds > 0 ? savedSeconds : (stage == .rest ? restSeconds : focusSeconds)
        summaryDraft = defaults.string(forKey: "summaryDraft") ?? ""
        nextTaskDraft = defaults.string(forKey: "nextTaskDraft") ?? ""
        if let savedDraft = defaults.stringArray(forKey: "nextChecklistDraft") {
            nextChecklistDraft = normalizedPlanDraft(savedDraft)
        } else {
            nextChecklistDraft = normalizedPlanDraft(nextTaskDraft.isEmpty ? [] : [nextTaskDraft])
        }
        inspirationBacklog = normalizedInspirations(defaults.stringArray(forKey: "inspirationBacklog") ?? [])
        let savedNextFocusSeconds = defaults.integer(forKey: "nextFocusSeconds")
        nextFocusSeconds = savedNextFocusSeconds > 0 ? savedNextFocusSeconds : focusSeconds
        if let data = defaults.data(forKey: "reflections"),
           let saved = try? JSONDecoder().decode([Reflection].self, from: data) {
            reflections = saved
        }

        if isRunning, let endDate {
            secondsRemaining = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        }
    }
}

private let application = NSApplication.shared
private let controller = PetController()
application.delegate = controller
application.run()
