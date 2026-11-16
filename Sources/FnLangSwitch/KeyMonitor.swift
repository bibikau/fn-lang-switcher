import Carbon.HIToolbox
import Cocoa

/// Fn only switches the input source: the system never sees it as a modifier,
/// so Fn + letter types the letter. F1-F12 keep Fn so the top row still works.
final class KeyMonitor {
    private let inputSourceManager: InputSourceManager
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnDown = false
    private var sourceBeforeFn: TISInputSource?
    private var remappedKeys: Set<Int64> = []

    private static let functionKeys: Set<Int64> = Set([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
        kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ].map(Int64.init))

    private static let keysWithFn: Set<Int64> = functionKeys.union([
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
    ].map(Int64.init))

    // The keyboard driver turns Fn + arrow / Delete into these before any event tap sees them.
    private static let navigationTargets: [Int64: Int64] = [
        Int64(kVK_Home): Int64(kVK_LeftArrow),
        Int64(kVK_End): Int64(kVK_RightArrow),
        Int64(kVK_PageUp): Int64(kVK_UpArrow),
        Int64(kVK_PageDown): Int64(kVK_DownArrow),
        Int64(kVK_ForwardDelete): Int64(kVK_Delete),
    ]

    init(inputSourceManager: InputSourceManager) {
        self.inputSourceManager = inputSourceManager
    }

    /// Fails until the app has Accessibility access.
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                return Unmanaged<KeyMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            let isFnPressed = event.flags.contains(.maskSecondaryFn)
            guard isFnPressed != fnDown else {
                if fnDown { event.flags.remove(.maskSecondaryFn) }
                return Unmanaged.passUnretained(event)
            }
            fnDown = isFnPressed
            sourceBeforeFn = fnDown ? inputSourceManager.toggleInputSource() : nil
            return nil
        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if fnDown && type == .keyDown {
                // Fn held only for F1-F12 was never meant as a switch: the press switched too early, undo it.
                if Self.functionKeys.contains(code), let source = sourceBeforeFn {
                    TISSelectInputSource(source)
                }
                sourceBeforeFn = nil
            }
            if let target = Self.navigationTargets[code], fnDown || remappedKeys.contains(code) {
                if type == .keyDown { remappedKeys.insert(code) } else { remappedKeys.remove(code) }
                return remap(event, type, to: target)
            }
            if fnDown && Self.keysWithFn.contains(code) == false {
                event.flags.remove(.maskSecondaryFn)
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // A new event rather than an edited keycode: the original keeps the Home / End characters.
    private func remap(_ event: CGEvent, _ type: CGEventType, to target: Int64) -> Unmanaged<CGEvent>? {
        guard let remapped = CGEvent(
            keyboardEventSource: CGEventSource(event: event),
            virtualKey: CGKeyCode(target),
            keyDown: type == .keyDown
        ) else { return Unmanaged.passUnretained(event) }
        var flags = event.flags
        if target == Int64(kVK_Delete) {
            flags.subtract([.maskSecondaryFn, .maskNumericPad])
        } else {
            flags.formUnion([.maskSecondaryFn, .maskNumericPad])
        }
        remapped.flags = flags
        remapped.timestamp = event.timestamp
        remapped.setIntegerValueField(.keyboardEventAutorepeat, value: event.getIntegerValueField(.keyboardEventAutorepeat))
        remapped.setIntegerValueField(.keyboardEventKeyboardType, value: event.getIntegerValueField(.keyboardEventKeyboardType))
        return Unmanaged.passRetained(remapped)
    }

    deinit { stop() }
}
