import Foundation

public enum PatchbayPermissionContract {
  public static func capabilities(
    deviceId: String,
    applicationId: String,
    supportsAlertDecisions: Bool
  ) throws -> String {
    func entry(reset: Bool, decisions: [String]) -> [String: Any] {
      var actions = reset ? ["reset"] : []
      if !decisions.isEmpty { actions.append("exercise") }
      return ["actions": actions, "decisions": decisions]
    }
    let common = supportsAlertDecisions ? ["allow", "deny"] : []
    let location = supportsAlertDecisions ? ["allow", "deny", "allowOnce"] : []
    let value: [String: Any] = [
      "deviceId": deviceId,
      "applicationId": applicationId,
      "capabilities": [
        "camera": entry(reset: true, decisions: common),
        "microphone": entry(reset: true, decisions: common),
        "locationWhenInUse": entry(reset: true, decisions: location),
        "notifications": entry(reset: false, decisions: common),
      ],
    ]
    return try encode(value)
  }

  public static func result(
    deviceId: String,
    applicationId: String,
    permission: String,
    decision: String? = nil,
    platformState: String,
    state: String,
    factSource: String
  ) throws -> String {
    var value: [String: Any] = [
      "deviceId": deviceId,
      "applicationId": applicationId,
      "permission": permission,
      "handled": true,
      "platformState": platformState,
      "state": state,
      "factSource": factSource,
    ]
    if let decision { value["decision"] = decision }
    return try encode(value)
  }

  private static func encode(_ value: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
}
