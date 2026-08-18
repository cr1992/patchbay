package dev.patchbay.permissions

import android.os.Bundle
import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import org.json.JSONObject
import org.junit.Test

/** Consumer seam for one OS/version-specific permission matcher. */
interface PatchbayPermissionDialogMatcher {
  /**
   * Bind the system window to targetPackage + permission before returning a
   * control. Localized text and screen coordinates are forbidden.
   */
  fun expectedDecisionControl(
    device: UiDevice,
    targetPackage: String,
    permission: String,
    decision: String,
  ): UiObject2?
}

/**
 * Source template: compile in an explicitly installed Android test APK.
 * A generic matcher is deliberately absent because the permission controller
 * exposes no stable cross-version permission identity.
 */
abstract class PatchbayPermissionRunner {
  protected abstract val matcher: PatchbayPermissionDialogMatcher

  @Test fun handleExpectedPermissionDialog() {
    val args = InstrumentationRegistry.getArguments()
    val target = args.getString("targetPackage") ?: failClosed("missing targetPackage")
    val permission = args.getString("permission") ?: failClosed("missing permission")
    val decision = args.getString("decision") ?: failClosed("missing decision")
    val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
    val control = matcher.expectedDecisionControl(device, target, permission, decision)
      ?: failClosed("expected permission dialog identity did not match")
    control.click()
    device.waitForIdle()
    val payload = JSONObject(mapOf("targetPackage" to target, "permission" to permission, "decision" to decision, "handled" to true)).toString()
    val encoded = Base64.encodeToString(payload.toByteArray(), Base64.NO_WRAP)
    InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply { putString("stream", "PATCHBAY_RESULT=$encoded\n") })
  }

  private fun failClosed(message: String): Nothing = throw AssertionError(message)
}
