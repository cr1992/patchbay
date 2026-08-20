import Foundation
import XCTest

final class PatchbayPermissionUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testPermissionOperation() throws {
    let environment = ProcessInfo.processInfo.environment
    let operation = try required("PATCHBAY_OPERATION", in: environment)
    let deviceId = try required("PATCHBAY_DEVICE_ID", in: environment)
    let applicationId = try required("PATCHBAY_APPLICATION_ID", in: environment)
    let app = XCUIApplication(bundleIdentifier: applicationId)
    guard app.state != .notRunning else {
      throw RunnerFailure("selected application is not running")
    }

    switch operation {
    case "capabilities":
      try emit(
        PatchbayPermissionContract.capabilities(
          deviceId: deviceId,
          applicationId: applicationId,
          supportsAlertDecisions: supportsCurrentLanguage
        )
      )
    case "reset":
      let permission = try required("PATCHBAY_PERMISSION", in: environment)
      app.resetAuthorizationStatus(for: try protectedResource(permission))
      try emit(
        PatchbayPermissionContract.result(
          deviceId: deviceId,
          applicationId: applicationId,
          permission: permission,
          platformState: "xctestReset",
          state: "notDetermined",
          factSource: "deviceReported"
        )
      )
    case "exercise":
      guard supportsCurrentLanguage else {
        throw RunnerFailure("device language has no verified alert matcher")
      }
      let permission = try required("PATCHBAY_PERMISSION", in: environment)
      let decision = try required("PATCHBAY_DECISION", in: environment)
      let observedState = try handleExpectedAlert(
        app: app,
        permission: permission,
        decision: decision
      )
      try emit(
        PatchbayPermissionContract.result(
          deviceId: deviceId,
          applicationId: applicationId,
          permission: permission,
          decision: decision,
          platformState: "xcuiAlertDecisionObserved",
          state: observedState,
          factSource: "uiObserved"
        )
      )
    default:
      throw RunnerFailure("unsupported operation")
    }
  }

  private var supportsCurrentLanguage: Bool {
    let language = Locale.preferredLanguages.first?.lowercased() ?? ""
    return language.hasPrefix("en") || language.hasPrefix("zh")
  }

  private func protectedResource(_ permission: String) throws -> XCUIProtectedResource {
    switch permission {
    case "camera": return .camera
    case "microphone": return .microphone
    case "locationWhenInUse": return .location
    default: throw RunnerFailure("permission has no XCTest reset resource")
    }
  }

  private func handleExpectedAlert(
    app: XCUIApplication,
    permission: String,
    decision: String
  ) throws -> String {
    app.activate()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let alert = springboard.alerts.firstMatch
    guard alert.waitForExistence(timeout: 10) else {
      throw RunnerFailure("expected system permission alert did not appear")
    }
    let alertText = ([alert.label]
      + alert.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label))
      .map(normalize)
      .joined(separator: " ")
    let permissionTokens: [String] = switch permission {
    case "camera": ["camera", "相机", "相機"]
    case "microphone": ["microphone", "麦克风", "麥克風"]
    case "locationWhenInUse": ["location", "位置"]
    case "notifications": ["notification", "通知"]
    default: []
    }
    guard permissionTokens.map(normalize).contains(where: alertText.contains) else {
      throw RunnerFailure("system alert identity did not match requested permission")
    }

    let expectedLabels: [String] = switch (permission, decision) {
    case (_, "deny"):
      ["Don't Allow", "Don’t Allow", "不允许", "不允許"]
    case ("locationWhenInUse", "allowOnce"):
      ["Allow Once", "允许一次", "允許一次"]
    case ("locationWhenInUse", "allow"):
      ["Allow While Using App", "Allow While Using the App", "使用 App 时允许", "使用 App 期間允許"]
    case (_, "allow"):
      ["Allow", "OK", "允许", "允許", "好"]
    default:
      []
    }
    let normalizedExpected = Set(expectedLabels.map(normalize))
    let matches = alert.buttons.allElementsBoundByIndex.filter {
      normalizedExpected.contains(normalize($0.label))
    }
    guard matches.count == 1 else {
      throw RunnerFailure("permission decision control was not unambiguous")
    }
    matches[0].tap()
    guard !alert.waitForExistence(timeout: 5) else {
      throw RunnerFailure("system permission alert remained after decision")
    }
    return switch decision {
    case "allow": "granted"
    case "allowOnce": "allowOnce"
    case "deny": "denied"
    default: throw RunnerFailure("unsupported permission decision")
    }
  }

  private func required(
    _ key: String,
    in environment: [String: String]
  ) throws -> String {
    guard let value = environment[key], !value.isEmpty else {
      throw RunnerFailure("missing \(key)")
    }
    return value
  }

  private func normalize(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .replacingOccurrences(of: "’", with: "'")
      .filter { !$0.isWhitespace }
      .lowercased()
  }

  private func emit(_ json: String) throws {
    let encoded = Data(json.utf8).base64EncodedString()
    print("PATCHBAY_RESULT=\(encoded)")
  }
}

private struct RunnerFailure: Error, CustomStringConvertible {
  init(_ description: String) { self.description = description }
  let description: String
}
