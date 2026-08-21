import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';

import 'registry/command_spec.dart';
import 'registry/friendly_command_registry.dart';
import 'registry/friendly_commands.dart';
import 'sensitive_input.dart';

// 只导出拆分前就公开的符号；ArgumentDecoder 与 FriendlyCommandRegistryResolver
// 是拆分产物，属于内部实现。
export 'registry/command_spec.dart'
    show
        PatchbayArtifactDisposition,
        PatchbayCommandDeclarationSource,
        PatchbayCommandTarget,
        PatchbayFriendlyCommandSpec,
        PatchbayFriendlyInvocation;
export 'registry/friendly_commands.dart';

part 'generated/protocol_cli_commands.g.dart';

/// Complete CLI syntax table and resolution facade.
abstract final class PatchbayFriendlyCommandRegistry {
  /// Complete CLI syntax table: explicit local commands plus generated
  /// protocol-owned commands.
  static List<PatchbayFriendlyCommandSpec> get commands =>
      _patchbayFriendlyCommands;

  /// Resolves [words] against the declaration table.
  static PatchbayFriendlyInvocation? resolve(
    List<String> words,
    ArgResults options, {
    String Function() readSensitiveInput = readSensitiveStdinLine,
  }) => FriendlyCommandRegistryResolver.resolve(
    allCommands: _patchbayFriendlyCommands,
    words: words,
    options: options,
    readSensitiveInput: readSensitiveInput,
  );

  /// The declaration [words] name, without touching arguments or stdin.
  static PatchbayFriendlyCommandSpec? specFor(List<String> words) =>
      FriendlyCommandRegistryResolver.match(
        canonicalPath(words),
        _patchbayFriendlyCommands,
      );

  /// Rewrites [words] into the declared spelling of the same command.
  static List<String> canonicalPath(List<String> words) =>
      FriendlyCommandRegistryResolver.canonicalPath(
        words,
        _patchbayFriendlyCommands,
      );

  /// CLI options accepted by [spec].
  static Set<String> allowedOptions(PatchbayFriendlyCommandSpec spec) =>
      FriendlyCommandRegistryResolver.allowedOptions(spec);
}
