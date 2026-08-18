import 'command_descriptor.dart';
import 'facts.dart';
import 'ui_descriptor.dart';

const PatchbayCommandDescriptor patchbayNavigationCatalogCommandDescriptor =
    PatchbayCommandDescriptor(
      name: 'navigation.catalog',
      summary: 'Read the consumer destination catalog.',
      plane: PatchbayPlane.flutterUi,
      mode: PatchbayCommandMode.readOnly,
      sideEffect: PatchbaySideEffect.none,
      factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      cliSyntax: <PatchbayCliSyntax>[
        PatchbayCliSyntax(
          id: 'navigationCatalog',
          path: <String>['navigation', 'catalog'],
          summary: 'List destinations exposed by the running App.',
        ),
      ],
    );

const PatchbayCommandDescriptor patchbayNavigationCurrentCommandDescriptor =
    PatchbayCommandDescriptor(
      name: 'navigation.current',
      summary: 'Read the current settled consumer destination.',
      plane: PatchbayPlane.flutterUi,
      mode: PatchbayCommandMode.readOnly,
      sideEffect: PatchbaySideEffect.none,
      factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      cliSyntax: <PatchbayCliSyntax>[
        PatchbayCliSyntax(
          id: 'navigationCurrent',
          path: <String>['navigation', 'current'],
          summary: 'Read the current destination and revision.',
        ),
      ],
    );

const PatchbayCommandDescriptor patchbayNavigationGoCommandDescriptor =
    PatchbayCommandDescriptor(
      name: 'navigation.go',
      summary: 'go to a cataloged consumer destination.',
      plane: PatchbayPlane.flutterUi,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.appState,
      factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
      parameters: <PatchbayParameterDescriptor>[
        PatchbayParameterDescriptor(
          name: 'destinationId',
          type: PatchbayParameterType.string,
          required: true,
        ),
        PatchbayParameterDescriptor(
          name: 'revision',
          type: PatchbayParameterType.integer,
          required: true,
        ),
        PatchbayParameterDescriptor(
          name: 'timeoutMs',
          type: PatchbayParameterType.integer,
          defaultValue: 5000,
        ),
      ],
      cliSyntax: <PatchbayCliSyntax>[
        PatchbayCliSyntax(
          id: 'navigationGo',
          path: <String>['navigation', 'go'],
          summary: 'Replace navigation state with a destination.',
          usageSuffix: '<destination-id> [--revision <revision>]',
          positionalParameters: <String>['destinationId'],
          optionParameters: <String, String>{
            'revision': 'revision',
            'timeoutMs': 'timeout-ms',
          },
          positiveParameters: <String>{'timeoutMs'},
          fencesNavigationRevision: true,
        ),
      ],
    );

const PatchbayCommandDescriptor patchbayNavigationPushCommandDescriptor =
    PatchbayCommandDescriptor(
      name: 'navigation.push',
      summary: 'push to a cataloged consumer destination.',
      plane: PatchbayPlane.flutterUi,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.appState,
      factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
      parameters: <PatchbayParameterDescriptor>[
        PatchbayParameterDescriptor(
          name: 'destinationId',
          type: PatchbayParameterType.string,
          required: true,
        ),
        PatchbayParameterDescriptor(
          name: 'revision',
          type: PatchbayParameterType.integer,
          required: true,
        ),
        PatchbayParameterDescriptor(
          name: 'timeoutMs',
          type: PatchbayParameterType.integer,
          defaultValue: 5000,
        ),
      ],
      cliSyntax: <PatchbayCliSyntax>[
        PatchbayCliSyntax(
          id: 'navigationPush',
          path: <String>['navigation', 'push'],
          summary: 'Push a cataloged destination.',
          usageSuffix: '<destination-id> [--revision <revision>]',
          positionalParameters: <String>['destinationId'],
          optionParameters: <String, String>{
            'revision': 'revision',
            'timeoutMs': 'timeout-ms',
          },
          positiveParameters: <String>{'timeoutMs'},
          fencesNavigationRevision: true,
        ),
      ],
    );

const PatchbayCommandDescriptor patchbayNavigationBackCommandDescriptor =
    PatchbayCommandDescriptor(
      name: 'navigation.back',
      summary: 'Navigate back through the consumer adapter.',
      plane: PatchbayPlane.flutterUi,
      mode: PatchbayCommandMode.immediate,
      sideEffect: PatchbaySideEffect.appState,
      factSources: <PatchbayFactSource>{PatchbayFactSource.uiObserved},
      parameters: <PatchbayParameterDescriptor>[
        PatchbayParameterDescriptor(
          name: 'revision',
          type: PatchbayParameterType.integer,
          required: true,
        ),
        PatchbayParameterDescriptor(
          name: 'timeoutMs',
          type: PatchbayParameterType.integer,
          defaultValue: 5000,
        ),
      ],
      cliSyntax: <PatchbayCliSyntax>[
        PatchbayCliSyntax(
          id: 'navigationBack',
          path: <String>['navigation', 'back'],
          summary: 'Navigate back from an observed revision.',
          usageSuffix: '[--revision <revision>]',
          optionParameters: <String, String>{
            'revision': 'revision',
            'timeoutMs': 'timeout-ms',
          },
          positiveParameters: <String>{'timeoutMs'},
          fencesNavigationRevision: true,
        ),
      ],
    );

/// Protocol-owned descriptors currently migrated to generated CLI syntax.
const List<PatchbayCommandDescriptor> patchbayProtocolCliCommandDescriptors =
    <PatchbayCommandDescriptor>[
      patchbayNavigationCatalogCommandDescriptor,
      patchbayNavigationCurrentCommandDescriptor,
      patchbayNavigationGoCommandDescriptor,
      patchbayNavigationPushCommandDescriptor,
      patchbayNavigationBackCommandDescriptor,
    ];
