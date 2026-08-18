import XCTest

/// Consumer-owned XCUITest seam. Patchbay intentionally supplies no generic
/// alert matcher: XCTest does not expose a stable permission identity, and
/// matching localized button text or coordinates would violate the contract.
public protocol PatchbayPermissionAlertMatcher {
  func handleExpectedAlert(app: XCUIApplication, permission: String, decision: String) throws -> String
}

public enum PatchbayPermissionContract {
  public static func result(deviceId: String, applicationId: String, permission: String, decision: String, platformState: String, state: String) throws -> String {
    let value: [String: Any] = ["deviceId": deviceId, "applicationId": applicationId, "permission": permission, "decision": decision, "handled": true, "platformState": platformState, "state": state]
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
}
