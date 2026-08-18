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
    ];
