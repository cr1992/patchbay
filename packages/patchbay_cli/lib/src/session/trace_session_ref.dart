import 'package:args/args.dart';

import 'session_models.dart';
import 'session_resolver.dart';
import 'session_store.dart';
import 'workspace_identity.dart';
import 'workspace_selection.dart';

/// The session a trace may record *before* the command resolves one.
///
/// Deliberately silent whenever the workspace kernel is not already sure:
/// a trace that names a session the command is about to refuse is worse than
/// a trace with no `sessionRef` at all, because it reads as evidence that the
/// command targeted that session. The command's own failure is recorded either
/// way, so nothing is lost by staying quiet here.
Map<String, Object?>? patchbayTraceSessionRef(
  ArgResults parsed, {
  PatchbayWorkspaceIdentityProbe? workspaceProbe,
  PatchbayWorkspaceIdentityAt? workspaceIdentityAt,
}) {
  if (parsed.option('direct-endpoint') != null) {
    return <String, Object?>{
      'mode': 'direct',
      'applicationId': parsed.option('direct-application-id'),
      'appInstanceId': parsed.option('direct-app-instance-id'),
    };
  }
  if (parsed.option('session') case final String sessionId) {
    return <String, Object?>{'mode': 'launcher', 'sessionId': sessionId};
  }
  if (parsed.option('ws-uri') != null) {
    return const <String, Object?>{'mode': 'explicitVmService'};
  }
  final PatchbayWorkspaceSelectionPlan plan =
      PatchbayWorkspaceSelectionKernel.implicit(
        PatchbaySessionResolver(
          store: PatchbaySessionStore(parsed.option('session-dir')),
          workspaceProbe: workspaceProbe,
          workspaceIdentityAt: workspaceIdentityAt,
        ).scope(),
      );
  if (plan.refusal != null || plan.records.length != 1) return null;
  final PatchbaySessionRecord record = plan.records.single;
  return <String, Object?>{
    'mode': 'launcher',
    'sessionId': record.sessionId,
    'applicationId': record.applicationId,
    'appInstanceId': record.appInstanceId,
    'deviceId': record.deviceId,
    'buildMode': record.buildMode,
  };
}
