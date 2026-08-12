import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

void main() {
  test('navigation DTOs expose destinations without route paths', () {
    final PatchbayDestinationDescriptor descriptor =
        PatchbayDestinationDescriptor(
          id: 'settings.account',
          summary: 'Account settings',
          operations: const <PatchbayNavigationOperation>{
            PatchbayNavigationOperation.go,
            PatchbayNavigationOperation.push,
          },
          gates: const <String>{'debug.navigation'},
        );

    final Map<String, Object?> json = descriptor.toJson();

    expect(json, containsPair('id', 'settings.account'));
    expect(json, isNot(contains(anyOf('route', 'path'))));
    expect(PatchbayDestinationDescriptorWire.fromJson(json).toJson(), json);
  });

  test('ui wait wire DTO round-trips a typed bounded condition', () {
    final PatchbayUiWaitRequest request = PatchbayUiWaitRequest(
      condition: PatchbayUiWaitCondition.navigationDestination,
      timeout: const Duration(seconds: 3),
      destinationId: 'settings',
      revision: 7,
    );

    final PatchbayUiWaitRequestWire wire = request.toWire();

    expect(
      PatchbayUiWaitRequestWire.fromJson(wire.toJson()).toJson(),
      wire.toJson(),
    );
    expect(PatchbayUiWaitRequest.fromWire(wire).condition, request.condition);
  });

  test('ui wait rejects ambiguous field combinations and implicit timeout', () {
    expect(
      () => PatchbayUiWaitRequest(
        condition: PatchbayUiWaitCondition.semanticsMounted,
        timeout: Duration.zero,
        semanticsIdentifier: 'status',
      ),
      throwsArgumentError,
    );
    expect(
      () => PatchbayUiWaitRequest(
        condition: PatchbayUiWaitCondition.semanticsValue,
        timeout: const Duration(seconds: 1),
        semanticsIdentifier: 'status',
      ),
      throwsFormatException,
    );
    expect(
      () => PatchbayUiWaitRequest(
        condition: PatchbayUiWaitCondition.navigationDestination,
        timeout: const Duration(seconds: 1),
        destinationId: '/settings',
      ),
      throwsFormatException,
    );
  });
}
