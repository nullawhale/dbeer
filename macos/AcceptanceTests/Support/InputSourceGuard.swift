import Carbon
import Foundation

// This helper changes no source registration or enabled-source preferences.
// Its only selecting operation restores the exact source recorded by snapshot.
private enum GuardFailure: Error {
    case unavailable
    case invalidProperty
    case sourceUnavailable
    case sourceChanged
    case selectionFailed
}

private func property(_ source: TISInputSource, _ key: CFString) throws -> CFTypeRef {
    guard let pointer = TISGetInputSourceProperty(source, key) else {
        throw GuardFailure.invalidProperty
    }
    return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
}

private func identifier(_ source: TISInputSource) throws -> String {
    let value = try property(source, kTISPropertyInputSourceID)
    guard CFGetTypeID(value) == CFStringGetTypeID() else { throw GuardFailure.invalidProperty }
    let result = unsafeBitCast(value, to: CFString.self) as String
    guard !result.isEmpty else { throw GuardFailure.invalidProperty }
    return result
}

private func flag(_ source: TISInputSource, _ key: CFString) throws -> Bool {
    let value = try property(source, key)
    guard CFGetTypeID(value) == CFBooleanGetTypeID() else { throw GuardFailure.invalidProperty }
    return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
}

private func validateSelectable(_ source: TISInputSource) throws {
    guard try flag(source, kTISPropertyInputSourceIsEnabled),
          try flag(source, kTISPropertyInputSourceIsSelectCapable) else {
        throw GuardFailure.sourceUnavailable
    }
}

private func currentSource() throws -> TISInputSource {
    guard let copied = TISCopyCurrentKeyboardInputSource() else { throw GuardFailure.unavailable }
    return copied.takeRetainedValue()
}

private func enabledSource(withID id: String) throws -> TISInputSource {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let copied = TISCreateInputSourceList(filter, false) else { throw GuardFailure.unavailable }
    let sources = copied.takeRetainedValue()
    guard CFArrayGetCount(sources) == 1,
          let pointer = CFArrayGetValueAtIndex(sources, 0) else {
        throw GuardFailure.sourceUnavailable
    }
    let source = unsafeBitCast(pointer, to: TISInputSource.self)
    guard try identifier(source) == id else { throw GuardFailure.invalidProperty }
    try validateSelectable(source)
    return source
}

private func emit(_ object: [String: String]) throws {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

private func snapshot() throws {
    let original = try currentSource()
    try validateSelectable(original)
    let originalID = try identifier(original)
    guard let copied = TISCopyCurrentASCIICapableKeyboardInputSource() else {
        throw GuardFailure.unavailable
    }
    let ascii = copied.takeRetainedValue()
    try validateSelectable(ascii)
    guard try flag(ascii, kTISPropertyInputSourceIsASCIICapable) else {
        throw GuardFailure.sourceUnavailable
    }
    let asciiID = try identifier(ascii)
    guard try identifier(currentSource()) == originalID else { throw GuardFailure.sourceChanged }
    try emit(["originalID": originalID, "asciiID": asciiID])
}

private func restore(originalID: String, asciiID: String) throws {
    guard !originalID.isEmpty, !asciiID.isEmpty else { throw GuardFailure.invalidProperty }
    let currentID = try identifier(currentSource())
    if currentID == originalID {
        try emit(["status": "alreadyRestored", "currentID": currentID])
        return
    }
    guard currentID == asciiID else { throw GuardFailure.sourceChanged }
    let original = try enabledSource(withID: originalID)
    let ascii = try enabledSource(withID: asciiID)
    guard try flag(ascii, kTISPropertyInputSourceIsASCIICapable) else {
        throw GuardFailure.sourceUnavailable
    }
    // Recheck after lookup so a source changed by the user is left untouched.
    guard try identifier(currentSource()) == asciiID else { throw GuardFailure.sourceChanged }
    guard TISSelectInputSource(original) == noErr else { throw GuardFailure.selectionFailed }
    guard try identifier(currentSource()) == originalID else { throw GuardFailure.selectionFailed }
    try emit(["status": "restored", "currentID": originalID])
}

do {
    let arguments = CommandLine.arguments
    if arguments.count == 2, arguments[1] == "snapshot" {
        try snapshot()
    } else if arguments.count == 4, arguments[1] == "restore" {
        try restore(originalID: arguments[2], asciiID: arguments[3])
    } else {
        FileHandle.standardError.write(Data("Usage: input-source-guard snapshot | restore ORIGINAL_ID ASCII_ID\n".utf8))
        exit(64)
    }
} catch {
    let message: String
    switch error {
    case GuardFailure.sourceChanged:
        message = "Input source changed outside the test; no restoration was attempted."
    case GuardFailure.selectionFailed:
        message = "Recorded input source restoration failed verification."
    default:
        message = "Required enabled, selectable keyboard input source is unavailable."
    }
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
