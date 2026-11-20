import Darwin
import Foundation
import ObjectiveC
import WebKit

/// A page-level transport fence, not JavaScript object deletion. These selectors
/// are WKPreferences SPI (WebKit-7614.4.6.0.5, iOS 11.3+); absence or an unknown
/// ABI refuses HTML rendering. No preference from another viewer is borrowed.
@MainActor
enum HTMLPreviewRTCPolicy {
    enum Failure: Error { case unavailable }

    static func makePreferences() throws -> WKPreferences {
        let preferences = WKPreferences()
        let setter = NSSelectorFromString("_setPeerConnectionEnabled:")
        let getter = NSSelectorFromString("_peerConnectionEnabled")
        guard preferences.responds(to: setter), preferences.responds(to: getter),
              let type = object_getClass(preferences),
              let setterMethod = class_getInstanceMethod(type, setter),
              let getterMethod = class_getInstanceMethod(type, getter),
              method_getNumberOfArguments(setterMethod) == 3,
              method_getNumberOfArguments(getterMethod) == 2,
              returnType(setterMethod) == "v",
              argumentType(setterMethod, 0) == "@", argumentType(setterMethod, 1) == ":",
              argumentType(getterMethod, 0) == "@", argumentType(getterMethod, 1) == ":",
              let encoding = argumentType(setterMethod, 2),
              returnType(getterMethod) == encoding else { throw Failure.unavailable }

        let setImplementation = method_getImplementation(setterMethod)
        let getImplementation = method_getImplementation(getterMethod)
        switch encoding {
        case "B":
            // Modern Objective-C BOOL is C _Bool, not an object for perform().
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            let set = unsafeBitCast(setImplementation, to: Setter.self)
            let get = unsafeBitCast(getImplementation, to: Getter.self)
            set(preferences, setter, false)
            guard !get(preferences, getter) else { throw Failure.unavailable }
        case "c":
            // Older Objective-C BOOL encodings use signed char. Never call that
            // implementation through the _Bool function-pointer signature.
            typealias Setter = @convention(c) (AnyObject, Selector, Int8) -> Void
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int8
            let set = unsafeBitCast(setImplementation, to: Setter.self)
            let get = unsafeBitCast(getImplementation, to: Getter.self)
            set(preferences, setter, 0)
            guard get(preferences, getter) == 0 else { throw Failure.unavailable }
        default:
            throw Failure.unavailable
        }
        return preferences
    }

    private static func returnType(_ method: Method) -> String {
        let encoding = method_copyReturnType(method)
        defer { free(encoding) }
        return String(cString: encoding)
    }

    private static func argumentType(_ method: Method, _ index: UInt32) -> String? {
        guard let encoding = method_copyArgumentType(method, index) else { return nil }
        defer { free(encoding) }
        return String(cString: encoding)
    }
}
