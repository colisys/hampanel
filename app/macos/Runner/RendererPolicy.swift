import Cocoa
import FlutterMacOS
import Metal
import ObjectiveC

enum RendererPolicy {
  static func install() {
    guard let device = MTLCreateSystemDefaultDevice() ?? MTLCopyAllDevices().first else {
      NSLog("[hampanel] no Metal device available, forcing Skia")
      forceSkia()
      return
    }

    let useImpeller = configuredOverride() ?? device.supportsFamily(.mac2)
    NSLog(
      "[hampanel] renderer=%@ gpu=%@ metalFamily=%@",
      useImpeller ? "impeller" : "skia",
      device.name,
      device.supportsFamily(.mac2) ? "mac2+" : "mac1"
    )

    if !useImpeller {
      forceSkia()
    }
  }

  private static func configuredOverride() -> Bool? {
    (Bundle.main.object(forInfoDictionaryKey: "FLTEnableImpeller") as? NSNumber)?.boolValue
  }

  private static func forceSkia() {
    // Release builds only honor the Info.plist key. The engine reads this
    // Objective-C getter while starting up, so override it when Skia is needed.
    let selector = NSSelectorFromString("enableImpeller")
    guard let method = class_getInstanceMethod(FlutterDartProject.self, selector) else {
      NSLog("[hampanel] FlutterDartProject.enableImpeller is unavailable; Impeller stays enabled")
      return
    }
    let disabled: @convention(block) (AnyObject) -> Bool = { _ in false }
    _ = method_setImplementation(method, imp_implementationWithBlock(disabled))
  }
}
