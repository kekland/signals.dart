part of 'signals.dart';

/// {@template computed}
/// Data is often derived from other pieces of existing data. The `computed` function lets you combine the values of multiple signals into a new signal that can be reacted to, or even used by additional computeds. When the signals accessed from within a computed callback change, the computed callback is re-executed and its new return value becomes the computed signal's value.
/// 
/// > `Computed` class extends the [`Signal`](/dart/core/signal/) class, so you can use it anywhere you would use a signal.
/// 
/// ```dart
/// import 'package:signals/signals.dart';
/// 
/// final name = signal("Jane");
/// final surname = signal("Doe");
/// 
/// final fullName = computed(() => name.value + " " + surname.value);
/// 
/// // Logs: "Jane Doe"
/// print(fullName.value);
/// 
/// // Updates flow through computed, but only if someone
/// // subscribes to it. More on that later.
/// name.value = "John";
/// // Logs: "John Doe"
/// print(fullName.value);
/// ```
/// 
/// Any signal that is accessed inside the `computed`'s callback function will be automatically subscribed to and tracked as a dependency of the computed signal.
/// 
/// > Computed signals are both lazily evaluated and memoized
/// 
/// ## Force Re-evaluation
/// 
/// You can force a computed signal to re-evaluate by calling its `.recompute` method. This will re-run the computed callback and update the computed signal's value.
/// 
/// ```dart
/// final name = signal("Jane");
/// final surname = signal("Doe");
/// final fullName = computed(() => name.value + " " + surname.value);
/// 
/// fullName.recompute(); // Re-runs the computed callback
/// ```
/// 
/// ## Disposing
/// 
/// ### Auto Dispose
/// 
/// If a computed signal is created with autoDispose set to true, it will automatically dispose itself when there are no more listeners.
/// 
/// ```dart
/// final s = computed(() => 0, autoDispose: true);
/// s.onDispose(() => print('Signal destroyed'));
/// final dispose = s.subscribe((_) {});
/// dispose();
/// final value = s.value; // 0
/// // prints: Signal destroyed
/// ```
/// 
/// A auto disposing signal does not require its dependencies to be auto disposing. When it is disposed it will freeze its value and stop tracking its dependencies.
/// 
/// This means that it will no longer react to changes in its dependencies.
/// 
/// ```dart
/// final s = computed(() => 0);
/// s.dispose();
/// final value = s.value; // 0
/// final b = computed(() => s.value); // 0
/// // b will not react to changes in s
/// ```
/// 
/// You can check if a signal is disposed by calling the `.disposed` method.
/// 
/// ```dart
/// final s = computed(() => 0);
/// print(s.disposed); // false
/// s.dispose();
/// print(s.disposed); // true
/// ```
/// 
/// ### On Dispose Callback
/// 
/// You can attach a callback to a signal that will be called when the signal is destroyed.
/// 
/// ```dart
/// final s = computed(() => 0);
/// s.onDispose(() => print('Signal destroyed'));
/// s.dispose();
/// ```
/// 
/// ## Testing
/// 
/// Testing computed signals is possible by converting a computed to a stream and testing it like any other stream in Dart.
/// 
/// ```dart
/// test('test as stream', () {
///     final a = signal(0);
///     final s = computed(() => a());
///     final stream = s.toStream();
/// 
///     a.value = 1;
///     a.value = 2;
///     a.value = 3;
/// 
///     expect(stream, emitsInOrder([0, 1, 2, 3]));
/// });
/// ```
/// 
/// `emitsInOrder` is a matcher that will check if the stream emits the values in the correct order which in this case is each value after a signal is updated.
/// 
/// You can also override the initial value of a computed signal when testing. This is is useful for mocking and testing specific value implementations.
/// 
/// ```dart
/// test('test with override', () {
///     final a = signal(0);
///     final s = computed(() => a()).overrideWith(-1);
/// 
///     final stream = s.toStream();
/// 
///     a.value = 1;
///     a.value = 2;
///     a.value = 2; // check if skipped
///     a.value = 3;
/// 
///     expect(stream, emitsInOrder([-1, 1, 2, 3]));
/// });
/// ```
/// 
/// `overrideWith` returns a new computed signal with the same global id sets the value as if the computed callback returned it.
/// @link https://dartsignals.dev/dart/core/computed
/// {@endtemplate}
abstract class Computed<T>
    implements ReadonlySignal<T>, TrackedReadonlySignal<T> {
  Iterable<ReadonlySignal> get _allSources;

  @override
  Iterable<_Listenable> get _allTargets;

  /// Call the computed function and return the value
  void recompute();

  void _reset(T? value);

  /// Override the current value with a new value
  Computed<T> overrideWith(T value) {
    this._reset(value);
    return this;
  }
}

class _Computed<T> extends Computed<T> implements _Listenable {
  final ComputedCallback<T> _compute;

  @override
  final bool autoDispose;

  @override
  bool disposed = false;

  @override
  final int globalId;

  @override
  final String? debugLabel;

  @override
  _Node? _sources;

  int _globalVersion;

  @override
  int _flags;

  Object? _error;

  late T _value, _previousValue, _initialValue;

  final SignalEquality<T>? equality;

  @override
  bool operator ==(Object other) {
    return other is Signal<T> && value == other.value;
  }

  @override
  int get hashCode {
    return Object.hashAll([
      globalId.hashCode,
      value.hashCode,
    ]);
  }

  @override
  Iterable<ReadonlySignal> get _allSources sync* {
    _Node? root = _sources;
    for (var node = root; node != null; node = node._nextSource) {
      yield node._source;
    }
  }

  @override
  Iterable<_Listenable> get _allTargets sync* {
    _Node? root = _targets;
    for (var node = root; node != null; node = node._nextTarget) {
      yield node._target;
    }
  }

  _Computed(
    ComputedCallback<T> compute, {
    this.debugLabel,
    this.equality,
    this.autoDispose = false,
  })  : _compute = compute,
        _version = 0,
        _globalVersion = globalVersion - 1,
        _flags = OUTDATED,
        brand = identifier,
        globalId = ++_lastGlobalId {
    _onComputedCreated(this);
  }

  @override
  bool _refresh() {
    this._flags &= ~NOTIFIED;

    if ((this._flags & RUNNING) != 0) {
      return false;
    }

    // If this computed signal has subscribed to updates from its dependencies
    // (TRACKING flag set) and none of them have notified about changes (OUTDATED
    // flag not set), then the computed value can't have changed.
    if ((this._flags & (OUTDATED | TRACKING)) == TRACKING) {
      return true;
    }
    this._flags &= ~OUTDATED;

    if (this._globalVersion == globalVersion) {
      return true;
    }
    this._globalVersion = globalVersion;

    // Mark this computed signal running before checking the dependencies for value
    // changes, so that the RUNNING flag can be used to notice cyclical dependencies.
    this._flags |= RUNNING;
    final needsUpdate = _needsToRecompute(this);
    if (_version > 0 && !needsUpdate) {
      this._flags &= ~RUNNING;
      return true;
    }

    final prevContext = _evalContext;
    try {
      _prepareSources(this);
      _evalContext = this;
      final value = _compute();
      final equality = this.equality ?? ((a, b) => a == b);
      if ((this._flags & HAS_ERROR) != 0 || needsUpdate || _version == 0) {
        if (_version == 0) {
          _previousValue = value;
          _initialValue = value;
        } else {
          _previousValue = _value;
        }
        if (_version == 0 || !equality(_value, value)) {
          _value = value;
          _onComputedUpdated(this, this._value);
          _flags &= ~HAS_ERROR;
          _version++;
        }
      }
    } catch (err) {
      _error = err;
      _flags |= HAS_ERROR;
      _version++;
    }
    _evalContext = prevContext;
    _cleanupSources(this);
    _flags &= ~RUNNING;
    return true;
  }

  @override
  void _subscribe(_Node node) {
    if (_targets == null) {
      _flags |= OUTDATED | TRACKING;

      // A computed signal subscribes lazily to its dependencies when the it
      // gets its first subscriber.
      for (var node = _sources; node != null; node = node._nextSource) {
        node._source._subscribe(node);
      }
    }
    _SignalBase.__subscribe(this, node);
  }

  @override
  void _unsubscribe(_Node node) {
    // Only run the unsubscribe step if the computed signal has any subscribers.
    if (_targets != null) {
      _SignalBase.__unsubscribe(this, node);

      // Computed signal unsubscribes from its dependencies when it loses its last subscriber.
      // This makes it possible for unreferences subgraphs of computed signals to get garbage collected.
      if (_targets == null) {
        _flags &= ~TRACKING;

        for (var node = _sources; node != null; node = node._nextSource) {
          node._source._unsubscribe(node);
        }
      }
    }
    if (autoDispose && _allTargets.isEmpty) {
      dispose();
    }
  }

  @override
  void recompute() {
    this.value;
    _previousValue = _value;
    this._value = _compute();
  }

  @override
  void _notify() {
    if (!((_flags & NOTIFIED) != 0)) {
      _flags |= OUTDATED | NOTIFIED;

      for (var node = _targets; node != null; node = node._nextTarget) {
        node._target._notify();
      }
    }
  }

  @override
  T peek() {
    if (!_refresh()) {
      _cycleDetected();
    }
    if ((_flags & HAS_ERROR) != 0) {
      throw _error!;
    }
    return _value;
  }

  @override
  T get() => value;

  @override
  T get value {
    if (disposed) {
      print(
          'computed warning: [$globalId|$debugLabel] has been read after disposed');
      return this._value;
    }

    if ((_flags & RUNNING) != 0) {
      _cycleDetected();
    }
    final node = _addDependency(this);
    _refresh();
    if (node != null) {
      node._version = _version;
    }
    if ((_flags & HAS_ERROR) != 0) {
      throw _error!;
    }
    return this._value;
  }

  @override
  T get previousValue => this._previousValue;

  @override
  T call() => this.value;

  @override
  String toString() => '$value';

  @override
  T toJson() => value;

  @override
  _Node? _node;

  @override
  _Node? _targets;

  @override
  int _version;

  final Symbol brand;

  @override
  EffectCleanup subscribe(void Function(T value) fn) {
    return _SignalBase.__signalSubscribe(this, fn);
  }

  final _disposeCallbacks = <void Function()>{};

  @override
  EffectCleanup onDispose(void Function() cleanup) {
    _disposeCallbacks.add(cleanup);

    return () {
      _disposeCallbacks.remove(cleanup);
    };
  }

  @override
  void dispose() {
    if (disposed) return;
    for (final cleanup in _disposeCallbacks) {
      cleanup();
    }
    _disposeCallbacks.clear();
    _flags |= DISPOSED;
    disposed = true;
  }

  @override
  T get initialValue => _initialValue;

  @override
  void _reset(T? value) {
    _refresh();
    _value = value ?? _initialValue;
    _previousValue = value ?? _initialValue;
  }
}

/// A callback that is executed inside a computed.
typedef ComputedCallback<T> = T Function();

/// {@template computed}
/// Data is often derived from other pieces of existing data. The `computed` function lets you combine the values of multiple signals into a new signal that can be reacted to, or even used by additional computeds. When the signals accessed from within a computed callback change, the computed callback is re-executed and its new return value becomes the computed signal's value.
/// 
/// > `Computed` class extends the [`Signal`](/dart/core/signal/) class, so you can use it anywhere you would use a signal.
/// 
/// ```dart
/// import 'package:signals/signals.dart';
/// 
/// final name = signal("Jane");
/// final surname = signal("Doe");
/// 
/// final fullName = computed(() => name.value + " " + surname.value);
/// 
/// // Logs: "Jane Doe"
/// print(fullName.value);
/// 
/// // Updates flow through computed, but only if someone
/// // subscribes to it. More on that later.
/// name.value = "John";
/// // Logs: "John Doe"
/// print(fullName.value);
/// ```
/// 
/// Any signal that is accessed inside the `computed`'s callback function will be automatically subscribed to and tracked as a dependency of the computed signal.
/// 
/// > Computed signals are both lazily evaluated and memoized
/// 
/// ## Force Re-evaluation
/// 
/// You can force a computed signal to re-evaluate by calling its `.recompute` method. This will re-run the computed callback and update the computed signal's value.
/// 
/// ```dart
/// final name = signal("Jane");
/// final surname = signal("Doe");
/// final fullName = computed(() => name.value + " " + surname.value);
/// 
/// fullName.recompute(); // Re-runs the computed callback
/// ```
/// 
/// ## Disposing
/// 
/// ### Auto Dispose
/// 
/// If a computed signal is created with autoDispose set to true, it will automatically dispose itself when there are no more listeners.
/// 
/// ```dart
/// final s = computed(() => 0, autoDispose: true);
/// s.onDispose(() => print('Signal destroyed'));
/// final dispose = s.subscribe((_) {});
/// dispose();
/// final value = s.value; // 0
/// // prints: Signal destroyed
/// ```
/// 
/// A auto disposing signal does not require its dependencies to be auto disposing. When it is disposed it will freeze its value and stop tracking its dependencies.
/// 
/// This means that it will no longer react to changes in its dependencies.
/// 
/// ```dart
/// final s = computed(() => 0);
/// s.dispose();
/// final value = s.value; // 0
/// final b = computed(() => s.value); // 0
/// // b will not react to changes in s
/// ```
/// 
/// You can check if a signal is disposed by calling the `.disposed` method.
/// 
/// ```dart
/// final s = computed(() => 0);
/// print(s.disposed); // false
/// s.dispose();
/// print(s.disposed); // true
/// ```
/// 
/// ### On Dispose Callback
/// 
/// You can attach a callback to a signal that will be called when the signal is destroyed.
/// 
/// ```dart
/// final s = computed(() => 0);
/// s.onDispose(() => print('Signal destroyed'));
/// s.dispose();
/// ```
/// 
/// ## Testing
/// 
/// Testing computed signals is possible by converting a computed to a stream and testing it like any other stream in Dart.
/// 
/// ```dart
/// test('test as stream', () {
///     final a = signal(0);
///     final s = computed(() => a());
///     final stream = s.toStream();
/// 
///     a.value = 1;
///     a.value = 2;
///     a.value = 3;
/// 
///     expect(stream, emitsInOrder([0, 1, 2, 3]));
/// });
/// ```
/// 
/// `emitsInOrder` is a matcher that will check if the stream emits the values in the correct order which in this case is each value after a signal is updated.
/// 
/// You can also override the initial value of a computed signal when testing. This is is useful for mocking and testing specific value implementations.
/// 
/// ```dart
/// test('test with override', () {
///     final a = signal(0);
///     final s = computed(() => a()).overrideWith(-1);
/// 
///     final stream = s.toStream();
/// 
///     a.value = 1;
///     a.value = 2;
///     a.value = 2; // check if skipped
///     a.value = 3;
/// 
///     expect(stream, emitsInOrder([-1, 1, 2, 3]));
/// });
/// ```
/// 
/// `overrideWith` returns a new computed signal with the same global id sets the value as if the computed callback returned it.
/// @link https://dartsignals.dev/dart/core/computed
/// {@endtemplate}
Computed<T> computed<T>(
  ComputedCallback<T> compute, {
  String? debugLabel,
  SignalEquality<T>? equality,
  bool autoDispose = false,
}) {
  return _Computed<T>(
    compute,
    debugLabel: debugLabel,
    equality: equality,
    autoDispose: autoDispose,
  );
}
