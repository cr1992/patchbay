import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

void main() {
  test(
    'anchored gesture descriptors freeze names, bounds inputs and CLI paths',
    () {
      final List<PatchbayCommandDescriptor> descriptors =
          <PatchbayCommandDescriptor>[
            patchbayUiGesturePressHoldCommandDescriptor,
            patchbayUiGestureDragCommandDescriptor,
            patchbayUiGestureFlingCommandDescriptor,
          ];

      expect(descriptors.map((descriptor) => descriptor.name), <String>[
        'ui.gesture.pressHold',
        'ui.gesture.drag',
        'ui.gesture.fling',
      ]);
      for (final PatchbayCommandDescriptor descriptor in descriptors) {
        expect(descriptor.plane, PatchbayPlane.flutterUi);
        expect(descriptor.mode, PatchbayCommandMode.immediate);
        expect(descriptor.factSources, <PatchbayFactSource>{
          PatchbayFactSource.uiObserved,
        });
        final Map<String, PatchbayParameterDescriptor> parameters =
            <String, PatchbayParameterDescriptor>{
              for (final PatchbayParameterDescriptor parameter
                  in descriptor.parameters)
                parameter.name: parameter,
            };
        expect(parameters['identifier']?.required, isTrue);
        expect(parameters['generation']?.required, isTrue);
        expect(parameters['start']?.type, PatchbayParameterType.json);
        expect(parameters['start']?.required, isTrue);
        expect(descriptor.cliSyntax, hasLength(1));
        expect(descriptor.cliSyntax.single.path.take(2), <String>[
          'ui',
          'gesture',
        ]);
      }
      expect(
        patchbayUiGestureDragCommandDescriptor.parameters
            .singleWhere((parameter) => parameter.name == 'path')
            .required,
        isTrue,
      );
      expect(
        patchbayUiGestureFlingCommandDescriptor.parameters
            .singleWhere((parameter) => parameter.name == 'velocity')
            .required,
        isTrue,
      );
    },
  );
}
