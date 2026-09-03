import 'package:patchbay/patchbay.dart';
import 'package:patchbay/patchbay_protocol.dart';
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

  test('ui.gesture.tap freezes its shape: no durationMs, optional start with '
      'a declared centre default', () {
    final PatchbayCommandDescriptor descriptor =
        patchbayUiGestureTapCommandDescriptor;

    expect(descriptor.name, 'ui.gesture.tap');
    expect(descriptor.plane, PatchbayPlane.flutterUi);
    expect(descriptor.mode, PatchbayCommandMode.immediate);
    expect(descriptor.sideEffect, PatchbaySideEffect.appState);
    expect(descriptor.factSources, <PatchbayFactSource>{
      PatchbayFactSource.uiObserved,
    });

    // 恰好三个参数：间隔是实现内部常数，`durationMs` 对 tap 是未知 key，
    // 它不出现在参数表就是这条契约的机检形态。
    expect(descriptor.parameters.map((parameter) => parameter.name), <String>[
      'identifier',
      'generation',
      'start',
    ]);
    final Map<String, PatchbayParameterDescriptor> parameters =
        <String, PatchbayParameterDescriptor>{
          for (final PatchbayParameterDescriptor parameter
              in descriptor.parameters)
            parameter.name: parameter,
        };
    expect(parameters['identifier']?.required, isTrue);
    expect(parameters['generation']?.required, isTrue);
    expect(parameters['start']?.type, PatchbayParameterType.json);
    expect(parameters['start']?.required, isFalse);
    // 默认值必须以 object 形式进 descriptor：catalog 是调用方唯一读得到的
    // 声明面，默认藏在实现里等于没有声明。
    expect(parameters['start']?.defaultValue, <String, Object?>{
      'x': 0.5,
      'y': 0.5,
    });

    expect(descriptor.cliSyntax, hasLength(1));
    final PatchbayCliSyntax syntax = descriptor.cliSyntax.single;
    expect(syntax.path, <String>['ui', 'gesture', 'tap']);
    expect(syntax.positionalParameters, <String>['identifier', 'generation']);
    expect(syntax.optionParameters, <String, String>{'start': 'start'});
    expect(syntax.positiveParameters, isEmpty);
    expect(syntax.usageSuffix, '<identifier> <generation> [--start <json>]');
  });

  test('the tap descriptor wire decodes strictly and its object default '
      'keeps the canonical digest order-independent', () {
    final Map<String, Object?> json = patchbayUiGestureTapCommandDescriptor
        .toJson();

    // catalog 行 = 严格 wire 核心 + 追加字段（对 tap 只有
    // weakConfirmationCompletes）。0.4.1 复刻 reader 的字段集不变是全 catalog
    // 兼容套件的事；这里冻结 tap 自己没有引入任何新字段，且 object 形态的
    // `start` 默认值能被严格参数解码逐字节往返。
    final Map<String, Object?> core = Map<String, Object?>.of(json)
      ..remove('weakConfirmationCompletes');
    final PatchbayCommandDescriptorWire wire =
        PatchbayCommandDescriptorWire.fromJson(core);
    expect(wire.name, 'ui.gesture.tap');
    expect(wire.toJson(), core);

    // object 形态的参数默认值是 gesture 家族首例：canonical JSON 对 map
    // 递归排序，catalog digest 必须与书写顺序无关。
    final Object? reordered = _reverseKeys(json);
    expect(
      PatchbayCatalogDigest.ofCommands(<Object?>[json]).value,
      PatchbayCatalogDigest.ofCommands(<Object?>[reordered]).value,
    );
  });
}

Object? _reverseKeys(Object? value) => switch (value) {
  final Map<String, Object?> map => <String, Object?>{
    for (final String key in map.keys.toList().reversed)
      key: _reverseKeys(map[key]),
  },
  final List<Object?> list => <Object?>[
    for (final Object? item in list) _reverseKeys(item),
  ],
  _ => value,
};
