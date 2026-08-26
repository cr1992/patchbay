import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

const int patchbaySnapshotMaxContainerDepth = 128;
const int patchbaySnapshotMaxExpandedOccurrences = 2 * 1024 * 1024;
const int patchbaySnapshotMaxCanonicalBytes = 4 * 1024 * 1024;

enum PatchbaySnapshotPayloadStage { beforeFreeze, beforeCanonical }

final class PatchbaySnapshotPayloadLimits {
  const PatchbaySnapshotPayloadLimits({
    required this.maxContainerDepth,
    required this.maxExpandedOccurrences,
    required this.maxCanonicalBytes,
    int? maxRunCanonicalBytes,
  }) : assert(maxContainerDepth >= 0),
       assert(maxExpandedOccurrences > 0),
       assert(maxCanonicalBytes > 0),
       assert(maxRunCanonicalBytes == null || maxRunCanonicalBytes > 0),
       assert(
         maxRunCanonicalBytes == null ||
             maxRunCanonicalBytes <= maxCanonicalBytes,
       ),
       _maxRunCanonicalBytes = maxRunCanonicalBytes;

  static const PatchbaySnapshotPayloadLimits production =
      PatchbaySnapshotPayloadLimits(
        maxContainerDepth: patchbaySnapshotMaxContainerDepth,
        maxExpandedOccurrences: patchbaySnapshotMaxExpandedOccurrences,
        maxCanonicalBytes: patchbaySnapshotMaxCanonicalBytes,
      );

  final int maxContainerDepth;
  final int maxExpandedOccurrences;

  /// The safety ceiling from PB-050-01. Crossing it is a provider contract
  /// failure, not a budget the host operator chose.
  final int maxCanonicalBytes;

  final int? _maxRunCanonicalBytes;

  /// The configured per-snapshot budget from PB-050-02, never above
  /// [maxCanonicalBytes]. Crossing it while it is strictly smaller is a
  /// resource rejection the caller can retry against a smaller snapshot.
  int get maxRunCanonicalBytes => _maxRunCanonicalBytes ?? maxCanonicalBytes;

  PatchbaySnapshotPayloadLimits withRunCanonicalBytes(int bytes) =>
      PatchbaySnapshotPayloadLimits(
        maxContainerDepth: maxContainerDepth,
        maxExpandedOccurrences: maxExpandedOccurrences,
        maxCanonicalBytes: maxCanonicalBytes,
        maxRunCanonicalBytes: bytes < maxCanonicalBytes
            ? bytes
            : maxCanonicalBytes,
      );
}

final class PatchbayFrozenSnapshotPayload {
  const PatchbayFrozenSnapshotPayload({
    required this.body,
    required this.canonical,
    required this.canonicalBytes,
  });

  final Map<String, Object?> body;
  final String canonical;

  /// UTF-8 length of [canonical], counted by the bounded sink that produced
  /// it rather than re-encoded afterwards.
  final int canonicalBytes;
}

/// Which budget a payload violation belongs to.
///
/// The two are not interchangeable: [contract] means the App handed the host
/// something it may never accept, while [runBudget] means the snapshot was
/// well formed but larger than the budget this host was configured with.
enum PatchbaySnapshotPayloadViolationKind { contract, runBudget }

final class PatchbaySnapshotPayloadViolation implements Exception {
  PatchbaySnapshotPayloadViolation._(
    this._token,
    Map<String, Object?> details, {
    this.kind = PatchbaySnapshotPayloadViolationKind.contract,
  }) : details = Map<String, Object?>.unmodifiable(details);

  final Object _token;
  final Map<String, Object?> details;
  final PatchbaySnapshotPayloadViolationKind kind;

  bool belongsTo(Object token) => identical(_token, token);
}

final class _SnapshotPayloadFault implements Exception {
  const _SnapshotPayloadFault._(this.details, this.kind);

  factory _SnapshotPayloadFault.invalid({
    required String failure,
    required String path,
    String? type,
  }) => _SnapshotPayloadFault._(<String, Object?>{
    'reason': 'snapshotPayloadInvalid',
    'failure': failure,
    'path': path,
    if (type != null) 'type': type,
  }, PatchbaySnapshotPayloadViolationKind.contract);

  factory _SnapshotPayloadFault.tooLarge({
    required String path,
    required String limitKind,
    required int limit,
    required int observed,
  }) => _SnapshotPayloadFault._(<String, Object?>{
    'reason': 'snapshotPayloadInvalid',
    'failure': 'payloadTooLarge',
    'path': path,
    'limitKind': limitKind,
    'limit': limit,
    'observed': observed,
  }, PatchbaySnapshotPayloadViolationKind.contract);

  /// The configured per-snapshot budget was crossed.
  ///
  /// Only the two counters travel: a path or a canonical excerpt would leak
  /// snapshot content into a resource answer.
  factory _SnapshotPayloadFault.runBudget({
    required int limit,
    required int observed,
  }) => _SnapshotPayloadFault._(<String, Object?>{
    'encodedBytesAtLeast': observed,
    'maxSnapshotBytes': limit,
  }, PatchbaySnapshotPayloadViolationKind.runBudget);

  final Map<String, Object?> details;
  final PatchbaySnapshotPayloadViolationKind kind;
}

final class PatchbaySnapshotPayloadFreezer {
  const PatchbaySnapshotPayloadFreezer({
    this.limits = PatchbaySnapshotPayloadLimits.production,
    this.testStageHook,
  });

  final PatchbaySnapshotPayloadLimits limits;
  final void Function(PatchbaySnapshotPayloadStage stage)? testStageHook;

  PatchbayFrozenSnapshotPayload freeze(
    Object? source, {
    Object? violationToken,
  }) {
    final Object token = violationToken ?? Object();
    try {
      testStageHook?.call(PatchbaySnapshotPayloadStage.beforeFreeze);
      final Object? frozen = _SnapshotFreezingTraversal(limits).freeze(source);
      if (frozen is! Map<String, Object?>) {
        throw _SnapshotPayloadFault.invalid(
          failure: 'unsupportedType',
          path: r'$',
          type: frozen.runtimeType.toString(),
        );
      }
      testStageHook?.call(PatchbaySnapshotPayloadStage.beforeCanonical);
      final Uint8List canonical = _CanonicalJsonWriter(limits).encode(frozen);
      return PatchbayFrozenSnapshotPayload(
        body: frozen,
        canonical: utf8.decode(canonical),
        canonicalBytes: canonical.length,
      );
    } on _SnapshotPayloadFault catch (error) {
      throw PatchbaySnapshotPayloadViolation._(
        token,
        error.details,
        kind: error.kind,
      );
    } on Object catch (error) {
      throw PatchbaySnapshotPayloadViolation._(token, <String, Object?>{
        'reason': 'snapshotPayloadInvalid',
        'failure': 'unsupportedType',
        'path': r'$',
        'type': error.runtimeType.toString(),
      });
    }
  }
}

final class _SnapshotFreezingTraversal {
  _SnapshotFreezingTraversal(this.limits) : _bytes = _BoundedByteSink(limits);

  final PatchbaySnapshotPayloadLimits limits;
  final _BoundedByteSink _bytes;
  final Set<Object> _ancestry = HashSet<Object>.identity();
  final List<_FreezeFrame> _frames = <_FreezeFrame>[];
  var _expandedOccurrences = 0;

  Object? freeze(Object? source) {
    _PendingValue? pending = _PendingValue(source, _SnapshotPath.root, 0);
    _CompletedValue? completed;
    while (true) {
      if (pending != null) {
        final Object? value = pending.value;
        if (value is Map<Object?, Object?>) {
          _startContainer(value, pending.path, pending.depth, isMap: true);
          pending = null;
        } else if (value is List<Object?>) {
          _startContainer(value, pending.path, pending.depth, isMap: false);
          pending = null;
        } else {
          _writeScalar(value, pending.path);
          completed = _CompletedValue(value);
          pending = null;
        }
      }

      if (completed != null) {
        if (_frames.isEmpty) return completed.value;
        _frames.last.accept(completed.value);
        completed = null;
      }

      while (pending == null && completed == null) {
        if (_frames.isEmpty) {
          throw StateError('snapshot traversal ended without a root value');
        }
        final _FreezeFrame frame = _frames.last;
        final _PendingValue? next = frame.next(this);
        if (next != null) {
          pending = next;
          break;
        }
        _frames.removeLast();
        _bytes.currentPath = frame.path.value;
        _bytes.add(frame.isMap ? _closeMap : _closeList);
        _ancestry.remove(frame.source);
        completed = _CompletedValue(frame.complete());
      }
    }
  }

  void _startContainer(
    Object source,
    _SnapshotPath path,
    int depth, {
    required bool isMap,
  }) {
    if (depth > limits.maxContainerDepth) {
      throw _SnapshotPayloadFault.invalid(
        failure: 'nestingTooDeep',
        path: path.value,
      );
    }
    if (!_ancestry.add(source)) {
      throw _SnapshotPayloadFault.invalid(
        failure: 'cycleDetected',
        path: path.value,
      );
    }
    _bytes.currentPath = path.value;
    _bytes.add(isMap ? _openMap : _openList);
    _countOccurrence(path);
    _frames.add(
      isMap
          ? _MapFreezeFrame(source as Map<Object?, Object?>, path, depth)
          : _ListFreezeFrame(source as List<Object?>, path, depth),
    );
  }

  void _writeScalar(Object? value, _SnapshotPath path) {
    if (value is double && !value.isFinite) {
      throw _SnapshotPayloadFault.invalid(
        failure: 'nonFiniteNumber',
        path: path.value,
      );
    }
    if (value != null && value is! bool && value is! num && value is! String) {
      throw _SnapshotPayloadFault.invalid(
        failure: 'unsupportedType',
        path: path.value,
        type: value.runtimeType.toString(),
      );
    }
    _bytes.currentPath = path.value;
    _writeJsonScalar(_bytes, value);
    _countOccurrence(path);
  }

  void _writeMapKey(
    _SnapshotPath parentPath,
    String key, {
    required bool first,
  }) {
    final _SnapshotPath path = parentPath.objectKey(key);
    _bytes.currentPath = path.value;
    if (!first) _bytes.add(_comma);
    _writeJsonScalar(_bytes, key);
    _bytes.add(_colon);
    _countOccurrence(path);
  }

  void _writeListSeparator(_SnapshotPath path, {required bool first}) {
    _bytes.currentPath = path.value;
    if (!first) _bytes.add(_comma);
  }

  Never nonStringKey(_SnapshotPath parentPath, Object? key) {
    throw _SnapshotPayloadFault.invalid(
      failure: 'nonStringKey',
      path: parentPath.value,
      type: key.runtimeType.toString(),
    );
  }

  void _countOccurrence(_SnapshotPath path) {
    final int observed = _expandedOccurrences + 1;
    if (observed > limits.maxExpandedOccurrences) {
      throw _SnapshotPayloadFault.tooLarge(
        path: path.value,
        limitKind: 'expandedNodes',
        limit: limits.maxExpandedOccurrences,
        observed: observed,
      );
    }
    _expandedOccurrences = observed;
  }
}

abstract base class _FreezeFrame {
  _FreezeFrame(this.source, this.path, this.depth);

  final Object source;
  final _SnapshotPath path;
  final int depth;
  bool get isMap;
  _PendingValue? next(_SnapshotFreezingTraversal traversal);
  void accept(Object? value);
  Object complete();
}

final class _MapFreezeFrame extends _FreezeFrame {
  _MapFreezeFrame(Map<Object?, Object?> source, _SnapshotPath path, int depth)
    : _entries = source.entries.iterator,
      super(source, path, depth);

  final Iterator<MapEntry<Object?, Object?>> _entries;
  final Map<String, Object?> _output = <String, Object?>{};
  String? _key;
  var _first = true;

  @override
  bool get isMap => true;

  @override
  _PendingValue? next(_SnapshotFreezingTraversal traversal) {
    if (!_entries.moveNext()) return null;
    final MapEntry<Object?, Object?> entry = _entries.current;
    final Object? rawKey = entry.key;
    if (rawKey is! String) traversal.nonStringKey(path, rawKey);
    _key = rawKey;
    traversal._writeMapKey(path, rawKey, first: _first);
    _first = false;
    return _PendingValue(entry.value, path.objectKey(rawKey), depth + 1);
  }

  @override
  void accept(Object? value) {
    _output[_key!] = value;
    _key = null;
  }

  @override
  Object complete() => Map<String, Object?>.unmodifiable(_output);
}

final class _ListFreezeFrame extends _FreezeFrame {
  _ListFreezeFrame(List<Object?> source, _SnapshotPath path, int depth)
    : _items = source.iterator,
      super(source, path, depth);

  final Iterator<Object?> _items;
  final List<Object?> _output = <Object?>[];
  var _index = 0;

  @override
  bool get isMap => false;

  @override
  _PendingValue? next(_SnapshotFreezingTraversal traversal) {
    if (!_items.moveNext()) return null;
    final _SnapshotPath childPath = path.listIndex(_index++);
    traversal._writeListSeparator(childPath, first: _index == 1);
    return _PendingValue(_items.current, childPath, depth + 1);
  }

  @override
  void accept(Object? value) => _output.add(value);

  @override
  Object complete() => List<Object?>.unmodifiable(_output);
}

final class _CanonicalJsonWriter {
  _CanonicalJsonWriter(PatchbaySnapshotPayloadLimits limits)
    : _sink = _BoundedByteSink(limits, retainBytes: true);

  final _BoundedByteSink _sink;

  Uint8List encode(Object? root) {
    final List<_CanonicalFrame> frames = <_CanonicalFrame>[];
    Object? pending = root;
    var pendingPath = _SnapshotPath.root;
    var hasPending = true;
    while (true) {
      if (hasPending) {
        final Object? value = pending;
        _sink.currentPath = pendingPath.value;
        if (value is Map<String, Object?>) {
          _sink.add(_openMap);
          frames.add(_CanonicalMapFrame(value, pendingPath));
        } else if (value is List<Object?>) {
          _sink.add(_openList);
          frames.add(_CanonicalListFrame(value, pendingPath));
        } else {
          _writeJsonScalar(_sink, value);
        }
        hasPending = false;
      }

      while (!hasPending) {
        if (frames.isEmpty) return _sink.takeBytes();
        final _CanonicalFrame frame = frames.last;
        final _CanonicalNext? next = frame.next(_sink);
        if (next != null) {
          pending = next.value;
          pendingPath = next.path;
          hasPending = true;
          break;
        }
        frames.removeLast();
        _sink.currentPath = frame.path.value;
        _sink.add(frame.isMap ? _closeMap : _closeList);
      }
    }
  }
}

abstract base class _CanonicalFrame {
  _SnapshotPath get path;
  bool get isMap;
  _CanonicalNext? next(_BoundedByteSink sink);
}

final class _CanonicalMapFrame extends _CanonicalFrame {
  _CanonicalMapFrame(this.source, this.path)
    : _keys = source.keys.toList(growable: false)..sort();

  final Map<String, Object?> source;
  @override
  final _SnapshotPath path;
  final List<String> _keys;
  var _index = 0;

  @override
  bool get isMap => true;

  @override
  _CanonicalNext? next(_BoundedByteSink sink) {
    if (_index >= _keys.length) return null;
    if (_index > 0) sink.add(_comma);
    final String key = _keys[_index++];
    _writeJsonScalar(sink, key);
    sink.add(_colon);
    return _CanonicalNext(source[key], path.objectKey(key));
  }
}

final class _CanonicalListFrame extends _CanonicalFrame {
  _CanonicalListFrame(this.source, this.path);

  final List<Object?> source;
  @override
  final _SnapshotPath path;
  var _index = 0;

  @override
  bool get isMap => false;

  @override
  _CanonicalNext? next(_BoundedByteSink sink) {
    if (_index >= source.length) return null;
    if (_index > 0) sink.add(_comma);
    final int index = _index++;
    return _CanonicalNext(source[index], path.listIndex(index));
  }
}

final class _BoundedByteSink extends ByteConversionSinkBase {
  _BoundedByteSink(this._limits, {bool retainBytes = false})
    : _builder = retainBytes ? BytesBuilder(copy: false) : null;

  final PatchbaySnapshotPayloadLimits _limits;
  final BytesBuilder? _builder;
  var _length = 0;
  String currentPath = r'$';

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  @override
  void close() => addSlice(const <int>[], 0, 0, true);

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    final int count = end - start;
    final int projected = _length + count;
    final int runBytes = _limits.maxRunCanonicalBytes;
    if (projected > runBytes) {
      // The smaller budget always decides, so the answer does not depend on
      // how the encoder happened to chunk this write. The PB-050-01 ceiling
      // only speaks when it *is* the effective budget.
      if (runBytes >= _limits.maxCanonicalBytes) {
        throw _SnapshotPayloadFault.tooLarge(
          path: currentPath,
          limitKind: 'canonicalBytes',
          limit: _limits.maxCanonicalBytes,
          observed: _limits.maxCanonicalBytes + 1,
        );
      }
      throw _SnapshotPayloadFault.runBudget(
        limit: runBytes,
        observed: projected,
      );
    }
    _length += count;
    _builder?.add(chunk.sublist(start, end));
  }

  Uint8List takeBytes() => _builder?.takeBytes() ?? Uint8List(0);
}

final class _NonClosingByteSink extends ByteConversionSinkBase {
  _NonClosingByteSink(this.target);

  final _BoundedByteSink target;

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  @override
  void close() {}

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    target.addSlice(chunk, start, end, false);
  }
}

void _writeJsonScalar(_BoundedByteSink sink, Object? value) {
  final ByteConversionSink output = _NonClosingByteSink(sink);
  final ChunkedConversionSink<Object?> input = JsonUtf8Encoder()
      .startChunkedConversion(output);
  input.add(value);
  input.close();
}

final class _SnapshotPath {
  const _SnapshotPath._(this.value, this._appendable);

  static const _SnapshotPath root = _SnapshotPath._(r'$', true);

  final String value;
  final bool _appendable;

  _SnapshotPath objectKey(String key) {
    if (!_appendable) return this;
    if (key.length <= 128 && _simplePathKey.hasMatch(key)) {
      return _SnapshotPath._('$value.$key', true);
    }
    return _SnapshotPath._(value, false);
  }

  _SnapshotPath listIndex(int index) =>
      _appendable ? _SnapshotPath._('$value[$index]', true) : this;
}

final RegExp _simplePathKey = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

final class _PendingValue {
  const _PendingValue(this.value, this.path, this.depth);

  final Object? value;
  final _SnapshotPath path;
  final int depth;
}

final class _CompletedValue {
  const _CompletedValue(this.value);

  final Object? value;
}

final class _CanonicalNext {
  const _CanonicalNext(this.value, this.path);

  final Object? value;
  final _SnapshotPath path;
}

const List<int> _openMap = <int>[0x7b];
const List<int> _closeMap = <int>[0x7d];
const List<int> _openList = <int>[0x5b];
const List<int> _closeList = <int>[0x5d];
const List<int> _comma = <int>[0x2c];
const List<int> _colon = <int>[0x3a];
