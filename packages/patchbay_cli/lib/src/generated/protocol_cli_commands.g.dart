// GENERATED CODE - DO NOT MODIFY BY HAND.
// Source: package:patchbay protocol command descriptors.

part of '../command_registry.dart';

const _GeneratedProtocolCommand _navigationCatalogProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayNavigationCatalogCommandDescriptor,
      serviceName: 'navigation.catalog',
      syntaxIndex: 0,
    );

const _GeneratedProtocolCommand _navigationCurrentProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayNavigationCurrentCommandDescriptor,
      serviceName: 'navigation.current',
      syntaxIndex: 0,
    );

const _GeneratedProtocolCommand _navigationGoProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayNavigationGoCommandDescriptor,
      serviceName: 'navigation.go',
      syntaxIndex: 0,
    );

const _GeneratedProtocolCommand _navigationPushProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayNavigationPushCommandDescriptor,
      serviceName: 'navigation.push',
      syntaxIndex: 0,
    );

const _GeneratedProtocolCommand _navigationBackProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayNavigationBackCommandDescriptor,
      serviceName: 'navigation.back',
      syntaxIndex: 0,
    );

final _GeneratedProtocolCommand _uiTextSetProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiTextSetCommandDescriptor,
      serviceName: 'ui.text.set',
      syntaxIndex: 0,
    );

final _GeneratedProtocolCommand _uiTextEnterProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiTextEnterCommandDescriptor,
      serviceName: 'ui.text.enter',
      syntaxIndex: 0,
    );

final _GeneratedProtocolCommand _uiSemanticsTreeProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiSemanticsTreeCommandDescriptor,
      serviceName: 'ui.semantics.tree',
      syntaxIndex: 0,
    );

final _GeneratedProtocolCommand _uiSemanticsActionProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiSemanticsActionCommandDescriptor,
      serviceName: 'ui.semantics.action',
      syntaxIndex: 0,
    );

final _GeneratedProtocolCommand _uiTapProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiSemanticsTapCommandDescriptor,
      serviceName: 'ui.semantics.tap',
      syntaxIndex: 0,
    );

final _GeneratedProtocolCommand _uiWaitSemanticsMountedProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiWaitCommandDescriptor,
      serviceName: 'ui.wait',
      syntaxIndex: 0,
    );

final _GeneratedProtocolCommand _uiWaitSemanticsUnmountedProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiWaitCommandDescriptor,
      serviceName: 'ui.wait',
      syntaxIndex: 1,
    );

final _GeneratedProtocolCommand _uiWaitSemanticsValueProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiWaitCommandDescriptor,
      serviceName: 'ui.wait',
      syntaxIndex: 2,
    );

final _GeneratedProtocolCommand _uiWaitDestinationProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiWaitCommandDescriptor,
      serviceName: 'ui.wait',
      syntaxIndex: 3,
    );

final _GeneratedProtocolCommand _uiWaitTreeRevisionProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiWaitCommandDescriptor,
      serviceName: 'ui.wait',
      syntaxIndex: 4,
    );

final _GeneratedProtocolCommand _uiWaitFrameRevisionProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiWaitCommandDescriptor,
      serviceName: 'ui.wait',
      syntaxIndex: 5,
    );

final _GeneratedProtocolCommand _uiKeepAwakeOnProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiKeepAwakeSetCommandDescriptor,
      serviceName: 'ui.keepAwake.set',
      syntaxIndex: 0,
    );

final _GeneratedProtocolCommand _uiKeepAwakeOffProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiKeepAwakeSetCommandDescriptor,
      serviceName: 'ui.keepAwake.set',
      syntaxIndex: 1,
    );

final _GeneratedProtocolCommand _uiKeepAwakeStatusProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiKeepAwakeStatusCommandDescriptor,
      serviceName: 'ui.keepAwake.status',
      syntaxIndex: 0,
    );

final _GeneratedProtocolCommand _uiInspectOnProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiInspectSelectCommandDescriptor,
      serviceName: 'ui.inspect.select',
      syntaxIndex: 0,
    );

final _GeneratedProtocolCommand _uiInspectOffProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiInspectSelectCommandDescriptor,
      serviceName: 'ui.inspect.select',
      syntaxIndex: 1,
    );

final _GeneratedProtocolCommand _uiInspectStatusProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiInspectStatusCommandDescriptor,
      serviceName: 'ui.inspect.status',
      syntaxIndex: 0,
    );

final _GeneratedProtocolCommand _captureRootProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiCaptureCommandDescriptor,
      serviceName: 'ui.capture',
      syntaxIndex: 0,
    );

final _GeneratedProtocolCommand _captureTargetProtocolCommand =
    _GeneratedProtocolCommand(
      descriptor: patchbayUiCaptureCommandDescriptor,
      serviceName: 'ui.capture',
      syntaxIndex: 1,
    );

final List<PatchbayFriendlyCommandSpec> _patchbayFriendlyCommands =
    <PatchbayFriendlyCommandSpec>[
      for (final PatchbayFriendlyCommand command
          in PatchbayFriendlyCommand.values)
        if (!command.isCompatibilityStub) command,
      _navigationCatalogProtocolCommand,
      _navigationCurrentProtocolCommand,
      _navigationGoProtocolCommand,
      _navigationPushProtocolCommand,
      _navigationBackProtocolCommand,
      _uiTextSetProtocolCommand,
      _uiTextEnterProtocolCommand,
      _uiSemanticsTreeProtocolCommand,
      _uiSemanticsActionProtocolCommand,
      _uiTapProtocolCommand,
      _uiWaitSemanticsMountedProtocolCommand,
      _uiWaitSemanticsUnmountedProtocolCommand,
      _uiWaitSemanticsValueProtocolCommand,
      _uiWaitDestinationProtocolCommand,
      _uiWaitTreeRevisionProtocolCommand,
      _uiWaitFrameRevisionProtocolCommand,
      _uiKeepAwakeOnProtocolCommand,
      _uiKeepAwakeOffProtocolCommand,
      _uiKeepAwakeStatusProtocolCommand,
      _uiInspectOnProtocolCommand,
      _uiInspectOffProtocolCommand,
      _uiInspectStatusProtocolCommand,
      _captureRootProtocolCommand,
      _captureTargetProtocolCommand,
    ];
