import 'command_descriptor.dart';
import 'facts.dart';
import 'ui_descriptor.dart';

const _uiFacts = <PatchbayFactSource>{PatchbayFactSource.uiObserved};
const _appFacts = <PatchbayFactSource>{PatchbayFactSource.appRecorded};
const _timeout = PatchbayParameterDescriptor(
  name: 'timeoutMs',
  type: PatchbayParameterType.integer,
  defaultValue: 5000,
);

PatchbayParameterDescriptor _p(
  String name,
  PatchbayParameterType type, {
  bool required = false,
  Object? defaultValue,
  List<Object?> allowedValues = const [],
}) => PatchbayParameterDescriptor(
  name: name,
  type: type,
  required: required,
  defaultValue: defaultValue,
  allowedValues: allowedValues,
);

PatchbayCommandDescriptor _ui(
  String name,
  String summary, {
  PatchbayCommandMode mode = PatchbayCommandMode.immediate,
  PatchbaySideEffect effect = PatchbaySideEffect.appState,
  Set<PatchbayFactSource> facts = _uiFacts,
  List<PatchbayParameterDescriptor> parameters = const [],
  List<PatchbayCliSyntax> cliSyntax = const [],
  Set<String> gates = const {},
}) => PatchbayCommandDescriptor(
  name: name,
  summary: summary,
  plane: PatchbayPlane.flutterUi,
  mode: mode,
  sideEffect: effect,
  factSources: facts,
  parameters: parameters,
  cliSyntax: cliSyntax,
  gates: gates,
);

final patchbayUiTextSetCommandDescriptor = _textDescriptor(
  'ui.text.set',
  'Set a registered Flutter text target without IME semantics.',
  'uiTextSet',
  'set',
  'Replace the text of a registered input target.',
);
final patchbayUiTextEnterCommandDescriptor = _textDescriptor(
  'ui.text.enter',
  'Enter text through the registered Flutter target policy.',
  'uiTextEnter',
  'enter',
  'Type text into a registered input target and submit it.',
);

PatchbayCommandDescriptor _textDescriptor(
  String name,
  String summary,
  String id,
  String verb,
  String cliSummary,
) => _ui(
  name,
  summary,
  parameters: <PatchbayParameterDescriptor>[
    _p('id', PatchbayParameterType.string, required: true),
    _p('generation', PatchbayParameterType.integer, required: true),
    _p('text', PatchbayParameterType.string, required: true),
    _p('inputWasStdin', PatchbayParameterType.boolean),
  ],
  cliSyntax: <PatchbayCliSyntax>[
    PatchbayCliSyntax(
      id: id,
      path: <String>['ui', 'text', verb],
      summary: cliSummary,
      usageSuffix: '<target-id> <generation> [text]',
      positionalParameters: <String>['id', 'generation'],
      nonNegativeParameters: <String>{'generation'},
      trailingParameter: 'text',
      stdinParameter: 'text',
      stdinMarkerParameter: 'inputWasStdin',
    ),
  ],
);

final patchbayUiSemanticsTreeCommandDescriptor = _ui(
  'ui.semantics.tree',
  'Observe the current Flutter Semantics tree.',
  mode: PatchbayCommandMode.readOnly,
  effect: PatchbaySideEffect.none,
  parameters: <PatchbayParameterDescriptor>[
    _p('maxDepth', PatchbayParameterType.integer, defaultValue: 64),
    _p('maxNodes', PatchbayParameterType.integer, defaultValue: 1000),
    _p('inputWasStdin', PatchbayParameterType.boolean),
  ],
  cliSyntax: const <PatchbayCliSyntax>[
    PatchbayCliSyntax(
      id: 'uiSemanticsTree',
      path: <String>['ui', 'semantics', 'tree'],
      summary: 'Read the Patchbay semantics tree.',
      inputMode: PatchbayCliInputMode.mergedJsonObject,
    ),
  ],
);

final patchbayUiSemanticsActionCommandDescriptor = _ui(
  'ui.semantics.action',
  'Invoke an allowed action on an observed Semantics node.',
  parameters: <PatchbayParameterDescriptor>[
    _p('nodeId', PatchbayParameterType.integer, required: true),
    _p('generation', PatchbayParameterType.integer, required: true),
    _p(
      'action',
      PatchbayParameterType.enumeration,
      required: true,
      allowedValues: const <String>[
        'tap',
        'focus',
        'scrollUp',
        'scrollDown',
        'scrollLeft',
        'scrollRight',
        'setText',
      ],
    ),
    _p('text', PatchbayParameterType.string),
    _p('inputWasStdin', PatchbayParameterType.boolean),
  ],
  cliSyntax: const <PatchbayCliSyntax>[
    PatchbayCliSyntax(
      id: 'uiSemanticsAction',
      path: <String>['ui', 'semantics', 'action'],
      summary: 'Dispatch a semantics action against an observed node.',
      usageSuffix: '<node-id> <generation> <action> [text]',
      positionalParameters: <String>['nodeId', 'generation', 'action'],
      nonNegativeParameters: <String>{'nodeId', 'generation'},
      trailingParameter: 'text',
      stdinParameter: 'text',
      stdinMarkerParameter: 'inputWasStdin',
      trailingWhen: PatchbayCliEqualsCondition(
        parameter: 'action',
        value: 'setText',
      ),
    ),
  ],
);

final patchbayUiSemanticsActionByIdentifierCommandDescriptor = _ui(
  'ui.semantics.actionByIdentifier',
  'Resolve a stable Semantics identifier and invoke an allowed action.',
  parameters: <PatchbayParameterDescriptor>[
    _p('identifier', PatchbayParameterType.string, required: true),
    _p('generation', PatchbayParameterType.integer, required: true),
    _p(
      'action',
      PatchbayParameterType.enumeration,
      required: true,
      allowedValues: const <String>[
        'tap',
        'focus',
        'scrollUp',
        'scrollDown',
        'scrollLeft',
        'scrollRight',
        'setText',
      ],
    ),
    _p('text', PatchbayParameterType.string),
    _p('inputWasStdin', PatchbayParameterType.boolean),
  ],
  cliSyntax: const <PatchbayCliSyntax>[
    PatchbayCliSyntax(
      id: 'uiAction',
      path: <String>['ui', 'action'],
      summary: 'Resolve an identifier and dispatch a semantics action.',
      usageSuffix: '<identifier> <generation> <action> [text]',
      positionalParameters: <String>['identifier', 'generation', 'action'],
      nonNegativeParameters: <String>{'generation'},
      trailingParameter: 'text',
      stdinParameter: 'text',
      stdinMarkerParameter: 'inputWasStdin',
      trailingWhen: PatchbayCliEqualsCondition(
        parameter: 'action',
        value: 'setText',
      ),
    ),
  ],
);

final patchbayUiSemanticsTapCommandDescriptor = _ui(
  'ui.semantics.tap',
  'Resolve a stable Semantics identifier and tap it in one request.',
  parameters: <PatchbayParameterDescriptor>[
    _p('identifier', PatchbayParameterType.string, required: true),
    _p('generation', PatchbayParameterType.integer),
  ],
  cliSyntax: const <PatchbayCliSyntax>[
    PatchbayCliSyntax(
      id: 'uiTap',
      path: <String>['ui', 'tap'],
      summary: 'Resolve a semantics identifier and tap it in one request.',
      usageSuffix: '<identifier> [--generation <generation>]',
      positionalParameters: <String>['identifier'],
      optionParameters: <String, String>{'generation': 'generation'},
      nonNegativeParameters: <String>{'generation'},
    ),
  ],
);

final patchbayUiGesturePressHoldCommandDescriptor = _gesture(
  'ui.gesture.pressHold',
  'Press and hold inside a Semantics identifier target.',
  'uiGesturePressHold',
  'press-hold',
  'Press and hold an anchored target.',
  extraParameters: <PatchbayParameterDescriptor>[
    _p('durationMs', PatchbayParameterType.integer, defaultValue: 500),
  ],
  extraOptions: const <String, String>{'durationMs': 'duration-ms'},
  usageSuffix: '<identifier> <generation> --start <json> [--duration-ms <ms>]',
);

final patchbayUiGestureDragCommandDescriptor = _gesture(
  'ui.gesture.drag',
  'Drag through bounded target-local points.',
  'uiGestureDrag',
  'drag',
  'Drag through an anchored target-local path.',
  extraParameters: <PatchbayParameterDescriptor>[
    _p('path', PatchbayParameterType.json, required: true),
    _p('durationMs', PatchbayParameterType.integer, defaultValue: 300),
  ],
  extraOptions: const <String, String>{
    'path': 'gesture-path',
    'durationMs': 'duration-ms',
  },
  usageSuffix:
      '<identifier> <generation> --start <json> --gesture-path <json> '
      '[--duration-ms <ms>]',
);

final patchbayUiGestureFlingCommandDescriptor = _gesture(
  'ui.gesture.fling',
  'Fling from a target-local point with normalized velocity.',
  'uiGestureFling',
  'fling',
  'Fling from an anchored target-local point.',
  extraParameters: <PatchbayParameterDescriptor>[
    _p('velocity', PatchbayParameterType.json, required: true),
    _p('durationMs', PatchbayParameterType.integer, defaultValue: 100),
  ],
  extraOptions: const <String, String>{
    'velocity': 'velocity',
    'durationMs': 'duration-ms',
  },
  usageSuffix:
      '<identifier> <generation> --start <json> --velocity <json> '
      '[--duration-ms <ms>]',
);

/// tap 是家族里唯一没有 `durationMs` 的成员：down→up 间隔是实现内部常数，
/// 不进 wire（DG-050-08 复核改判）。它的 `start` 也因此从"路径起点"退化为
/// "唯一那个点"，可缺省到目标中心——默认值必须进 descriptor 而不是只写在
/// 实现里，catalog 是调用方唯一读得到的声明面。两处形状开关都带默认值，
/// 既有三条 descriptor 的字节因此一位不变。
final patchbayUiGestureTapCommandDescriptor = _gesture(
  'ui.gesture.tap',
  'Tap inside a Semantics identifier target through the real pointer '
      'pipeline.',
  'uiGestureTap',
  'tap',
  'Tap an anchored target through the real pointer pipeline.',
  extraParameters: const <PatchbayParameterDescriptor>[],
  extraOptions: const <String, String>{},
  usageSuffix: '<identifier> <generation> [--start <json>]',
  startRequired: false,
  startDefault: const <String, Object?>{'x': 0.5, 'y': 0.5},
  positiveParameters: const <String>{},
);

PatchbayCommandDescriptor _gesture(
  String name,
  String summary,
  String syntaxId,
  String verb,
  String cliSummary, {
  required List<PatchbayParameterDescriptor> extraParameters,
  required Map<String, String> extraOptions,
  required String usageSuffix,
  bool startRequired = true,
  Object? startDefault,
  Set<String> positiveParameters = const <String>{'durationMs'},
}) => _ui(
  name,
  summary,
  parameters: <PatchbayParameterDescriptor>[
    _p('identifier', PatchbayParameterType.string, required: true),
    _p('generation', PatchbayParameterType.integer, required: true),
    _p(
      'start',
      PatchbayParameterType.json,
      required: startRequired,
      defaultValue: startDefault,
    ),
    ...extraParameters,
  ],
  cliSyntax: <PatchbayCliSyntax>[
    PatchbayCliSyntax(
      id: syntaxId,
      path: <String>['ui', 'gesture', verb],
      summary: cliSummary,
      usageSuffix: usageSuffix,
      positionalParameters: const <String>['identifier', 'generation'],
      optionParameters: <String, String>{'start': 'start', ...extraOptions},
      positiveParameters: positiveParameters,
      nonNegativeParameters: const <String>{'generation'},
    ),
  ],
);

/// PB-050-17 / DG-050-10：identifier 锚定的 scroll-to-reveal。
///
/// 独立顶层命令，不进 `ui.gesture.*`（那族已冻结为「合成指针事件序列」）也不进
/// `ui.semantics.*`（那族的形状是「派发一个 allowlist 内的 action，返回
/// dispatched」）。它是写操作，因此也不是 `ui.wait` 的一个 condition。
///
/// `direction` 说的是**内容序**而不是屏幕方向：`forward` = 朝 `maxScrollExtent`
/// 前进。落到哪个 `SemanticsAction` 由容器当前暴露的 action 与观察到的位移符号
/// 确定，不由参数字面指定——否则 reverse 列表和横向列表就要求调用方先知道布局
/// 方向。**不存在任何坐标入参**（design.md 非目标红线在本命令上的落点）。
final patchbayUiRevealCommandDescriptor = _ui(
  'ui.reveal',
  'Drive a scroll container until a Semantics identifier is mounted and '
      'exposed.',
  parameters: <PatchbayParameterDescriptor>[
    const PatchbayParameterDescriptor(
      name: 'identifier',
      type: PatchbayParameterType.string,
      required: true,
      summary:
          'Stable Semantics identifier of the target. It does not have to be '
          'mounted yet — that is what this command is for. Do not follow a '
          'reveal with ui.wait semanticsMounted: mounting and exposure both '
          'happen inside this one request, and semanticsMounted is the weaker '
          'of the two checks, so it cannot vouch for a reveal. Success means '
          'Patchbay observed the target exposed under a fixed five-point '
          'sample on the terminating frame; it is not a proof of reachability '
          'and says nothing about the next frame — that is what the returned '
          'generation is for.',
    ),
    const PatchbayParameterDescriptor(
      name: 'container',
      type: PatchbayParameterType.string,
      summary:
          'Semantics identifier anchoring the scroll container to drive. Omit '
          'it only when exactly one candidate container is resolvable.',
    ),
    const PatchbayParameterDescriptor(
      name: 'direction',
      type: PatchbayParameterType.enumeration,
      defaultValue: 'both',
      allowedValues: <String>['forward', 'backward', 'both'],
      summary:
          'Content order, not screen direction: forward moves toward '
          'maxScrollExtent. An explicit direction may spend one reverse probe '
          'step when the container is not resting at either end.',
    ),
    const PatchbayParameterDescriptor(
      name: 'maxSteps',
      type: PatchbayParameterType.integer,
      defaultValue: 40,
      summary:
          'Scroll actions this call may dispatch in total (1..200). It is the '
          'only hard ceiling: lazy-loaded growth resets the stall counter but '
          'never extends this budget.',
    ),
    const PatchbayParameterDescriptor(
      name: 'timeoutMs',
      type: PatchbayParameterType.integer,
      defaultValue: 5000,
      summary:
          'One deadline for the whole call (1..120000), frozen at admission '
          'and never rewritten while escalating outward.',
    ),
  ],
  cliSyntax: const <PatchbayCliSyntax>[
    PatchbayCliSyntax(
      id: 'uiReveal',
      path: <String>['ui', 'reveal'],
      summary:
          'Scroll an identifier into view and report how to reach it next.',
      usageSuffix:
          '<identifier> [--container <identifier>] '
          '[--direction <forward|backward|both>] [--max-steps <n>] '
          '[--timeout-ms <ms>]',
      positionalParameters: <String>['identifier'],
      optionParameters: <String, String>{
        'container': 'container',
        'direction': 'direction',
        'maxSteps': 'max-steps',
        'timeoutMs': 'timeout-ms',
      },
      positiveParameters: <String>{'maxSteps', 'timeoutMs'},
    ),
  ],
);

final patchbayUiWaitCommandDescriptor = _ui(
  'ui.wait',
  'Wait for one bounded Flutter observation condition.',
  mode: PatchbayCommandMode.readOnly,
  effect: PatchbaySideEffect.none,
  parameters: <PatchbayParameterDescriptor>[
    _p(
      'condition',
      PatchbayParameterType.enumeration,
      required: true,
      allowedValues: const <String>[
        'semanticsMounted',
        'semanticsUnmounted',
        'semanticsValue',
        'navigationDestination',
        'treeRevision',
        'frameRevision',
      ],
    ),
    _p(
      'timeoutMs',
      PatchbayParameterType.integer,
      required: true,
      defaultValue: 5000,
    ),
    _p('semanticsIdentifier', PatchbayParameterType.string),
    _p('value', PatchbayParameterType.string),
    _p('destinationId', PatchbayParameterType.string),
    _p('revision', PatchbayParameterType.integer),
  ],
  cliSyntax: <PatchbayCliSyntax>[
    _wait(
      'uiWaitSemanticsMounted',
      'semantics-mounted',
      'Wait for a semantics identifier to mount.',
      'semanticsMounted',
      'semanticsIdentifier',
      '<identifier>',
    ),
    _wait(
      'uiWaitSemanticsUnmounted',
      'semantics-unmounted',
      'Wait for a semantics identifier to unmount.',
      'semanticsUnmounted',
      'semanticsIdentifier',
      '<identifier>',
    ),
    _wait2(
      'uiWaitSemanticsValue',
      'semantics-value',
      'Wait for a semantics value.',
      'semanticsValue',
      <String>['semanticsIdentifier', 'value'],
      '<identifier> <value>',
    ),
    _wait(
      'uiWaitDestination',
      'destination',
      'Wait for a navigation destination.',
      'navigationDestination',
      'destinationId',
      '<destination-id>',
      revisionOption: true,
    ),
    _wait(
      'uiWaitTreeRevision',
      'tree-revision',
      'Wait for the semantics tree revision.',
      'treeRevision',
      'revision',
      '<revision>',
      nonNegative: true,
    ),
    _wait(
      'uiWaitFrameRevision',
      'frame-revision',
      'Wait for the rendered frame revision.',
      'frameRevision',
      'revision',
      '<revision>',
      nonNegative: true,
    ),
  ],
);

PatchbayCliSyntax _wait(
  String id,
  String leaf,
  String summary,
  String condition,
  String parameter,
  String usage, {
  bool revisionOption = false,
  bool nonNegative = false,
}) => _wait2(
  id,
  leaf,
  summary,
  condition,
  <String>[parameter],
  usage,
  revisionOption: revisionOption,
  nonNegative: nonNegative,
);
PatchbayCliSyntax _wait2(
  String id,
  String leaf,
  String summary,
  String condition,
  List<String> positionals,
  String usage, {
  bool revisionOption = false,
  bool nonNegative = false,
}) => PatchbayCliSyntax(
  id: id,
  path: <String>['ui', 'wait', leaf],
  summary: summary,
  usageSuffix: usage,
  positionalParameters: positionals,
  optionParameters: <String, String>{
    'timeoutMs': 'timeout-ms',
    if (revisionOption) 'revision': 'revision',
  },
  positiveParameters: const <String>{'timeoutMs'},
  nonNegativeParameters: nonNegative ? <String>{'revision'} : const <String>{},
  fixedArguments: <String, Object?>{'condition': condition},
);

final patchbayUiKeepAwakeSetCommandDescriptor = _ui(
  'ui.keepAwake.set',
  'Hold the screen awake under a bounded lease, or release it.',
  facts: _appFacts,
  parameters: <PatchbayParameterDescriptor>[
    _p('enabled', PatchbayParameterType.boolean, required: true),
    const PatchbayParameterDescriptor(
      name: 'leaseMs',
      type: PatchbayParameterType.integer,
      defaultValue: 600000,
      summary:
          'Lease for this engagement; the App releases on its own when it '
          'runs out. Only valid with enabled: true.',
    ),
  ],
  cliSyntax: const <PatchbayCliSyntax>[
    PatchbayCliSyntax(
      id: 'uiKeepAwakeOn',
      path: <String>['ui', 'keep-awake', 'on'],
      summary: 'Ask the App to hold the screen awake for one bounded lease.',
      usageSuffix: '[--lease-ms <ms>]',
      optionParameters: <String, String>{'leaseMs': 'lease-ms'},
      positiveParameters: <String>{'leaseMs'},
      omitOptionDefaults: <String>{'leaseMs'},
      fixedArguments: <String, Object?>{'enabled': true},
    ),
    PatchbayCliSyntax(
      id: 'uiKeepAwakeOff',
      path: <String>['ui', 'keep-awake', 'off'],
      summary:
          'Release the keep-awake hold now, without waiting for the lease.',
      fixedArguments: <String, Object?>{'enabled': false},
    ),
  ],
);
final patchbayUiKeepAwakeStatusCommandDescriptor = _ui(
  'ui.keepAwake.status',
  'Read the keep-awake hold the App is currently bookkeeping.',
  mode: PatchbayCommandMode.readOnly,
  effect: PatchbaySideEffect.none,
  facts: _appFacts,
  cliSyntax: const <PatchbayCliSyntax>[
    PatchbayCliSyntax(
      id: 'uiKeepAwakeStatus',
      path: <String>['ui', 'keep-awake', 'status'],
      summary:
          'Read whether the App is holding the screen awake, and for how much longer.',
    ),
  ],
);

final patchbayUiInspectSelectCommandDescriptor = _ui(
  'ui.inspect.select',
  'Turn the widget inspector select mode on or off, under a lease.',
  facts: _appFacts,
  parameters: <PatchbayParameterDescriptor>[
    const PatchbayParameterDescriptor(
      name: 'enabled',
      type: PatchbayParameterType.boolean,
      required: true,
      summary: 'Whether taps on the device select widgets.',
    ),
    const PatchbayParameterDescriptor(
      name: 'ttlMs',
      type: PatchbayParameterType.integer,
      defaultValue: 300000,
      summary:
          'Lease for an enable; the App restores the switch when it expires '
          'without a renewal. Only valid with enabled=true.',
    ),
  ],
  cliSyntax: const <PatchbayCliSyntax>[
    PatchbayCliSyntax(
      id: 'uiInspectOn',
      path: <String>['ui', 'inspect', 'on'],
      summary:
          'Turn widget select mode on for a lease, then it restores itself.',
      usageSuffix: '[--ttl-ms <ms>]',
      optionParameters: <String, String>{'ttlMs': 'ttl-ms'},
      positiveParameters: <String>{'ttlMs'},
      omitOptionDefaults: <String>{'ttlMs'},
      fixedArguments: <String, Object?>{'enabled': true},
    ),
    PatchbayCliSyntax(
      id: 'uiInspectOff',
      path: <String>['ui', 'inspect', 'off'],
      summary: 'Turn widget select mode off and release the lease.',
      fixedArguments: <String, Object?>{'enabled': false},
    ),
  ],
);
final patchbayUiInspectStatusCommandDescriptor = _ui(
  'ui.inspect.status',
  'Read the on-device widget inspector select-mode switch.',
  mode: PatchbayCommandMode.readOnly,
  effect: PatchbaySideEffect.none,
  facts: _appFacts,
  cliSyntax: const <PatchbayCliSyntax>[
    PatchbayCliSyntax(
      id: 'uiInspectStatus',
      path: <String>['ui', 'inspect', 'status'],
      summary: 'Read the widget select-mode switch and its lease.',
    ),
  ],
);

final patchbayUiCaptureCommandDescriptor = _ui(
  'ui.capture',
  'Capture a bounded Flutter repaint boundary as a PNG blob.',
  mode: PatchbayCommandMode.readOnly,
  effect: PatchbaySideEffect.none,
  parameters: <PatchbayParameterDescriptor>[
    _p('targetId', PatchbayParameterType.string),
    _p('generation', PatchbayParameterType.integer),
    _p('pixelRatio', PatchbayParameterType.number, defaultValue: 1),
    _timeout,
    // 随 !54 进入 main：命令受理后再观察这么多 Flutter 帧才取证，范围 1..120。
    _p('afterFrames', PatchbayParameterType.integer, defaultValue: 1),
  ],
  cliSyntax: const <PatchbayCliSyntax>[
    PatchbayCliSyntax(
      id: 'captureRoot',
      path: <String>['capture', 'root'],
      summary: 'Capture the Flutter root repaint boundary.',
      usageSuffix: '--output <path>',
      optionParameters: <String, String>{
        'pixelRatio': 'pixel-ratio',
        'timeoutMs': 'timeout-ms',
        'afterFrames': 'after-frames',
      },
      positiveParameters: <String>{'timeoutMs', 'afterFrames'},
      artifactDisposition: PatchbayCliArtifactDisposition.payloadBlob,
    ),
    PatchbayCliSyntax(
      id: 'captureTarget',
      path: <String>['capture', 'target'],
      summary: 'Capture a registered Flutter UI target.',
      usageSuffix: '<target-id> <generation> --output <path>',
      positionalParameters: <String>['targetId', 'generation'],
      optionParameters: <String, String>{
        'pixelRatio': 'pixel-ratio',
        'timeoutMs': 'timeout-ms',
        'afterFrames': 'after-frames',
      },
      positiveParameters: <String>{'timeoutMs', 'afterFrames'},
      nonNegativeParameters: <String>{'generation'},
      artifactDisposition: PatchbayCliArtifactDisposition.payloadBlob,
    ),
  ],
);

final List<PatchbayCommandDescriptor> patchbayUiProtocolCliCommandDescriptors =
    <PatchbayCommandDescriptor>[
      patchbayUiTextSetCommandDescriptor,
      patchbayUiTextEnterCommandDescriptor,
      patchbayUiSemanticsTreeCommandDescriptor,
      patchbayUiSemanticsActionCommandDescriptor,
      patchbayUiSemanticsActionByIdentifierCommandDescriptor,
      patchbayUiSemanticsTapCommandDescriptor,
      patchbayUiGesturePressHoldCommandDescriptor,
      patchbayUiGestureDragCommandDescriptor,
      patchbayUiGestureFlingCommandDescriptor,
      patchbayUiGestureTapCommandDescriptor,
      patchbayUiRevealCommandDescriptor,
      patchbayUiWaitCommandDescriptor,
      patchbayUiKeepAwakeSetCommandDescriptor,
      patchbayUiKeepAwakeStatusCommandDescriptor,
      patchbayUiInspectSelectCommandDescriptor,
      patchbayUiInspectStatusCommandDescriptor,
      patchbayUiCaptureCommandDescriptor,
    ];
