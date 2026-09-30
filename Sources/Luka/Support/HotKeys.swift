import Carbon.HIToolbox

/// System-wide shortcuts that work while another app is frontmost.
@MainActor
final class HotKeys {
    struct Binding {
        let keyCode: Int
        let modifiers: Int
        let action: @MainActor () -> Void
    }

    private var refs: [EventHotKeyRef] = []
    private var bindings: [UInt32: Binding] = [:]
    private var handler: EventHandlerRef?

    func register(_ list: [Binding]) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { hotKeys.bindings[id.id]?.action() }
            return noErr
        }, 1, &spec, context, &handler)

        for (index, binding) in list.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(binding.keyCode), UInt32(binding.modifiers),
                                             EventHotKeyID(signature: OSType(0x5342_5458), id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                bindings[id] = binding
            }
        }
    }
}
