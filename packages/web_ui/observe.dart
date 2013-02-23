// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * A library for observing changes to observable Dart objects.
 * Similar in spirit to EcmaScript Harmony
 * [Object.observe](http://wiki.ecmascript.org/doku.php?id=harmony:observe), but
 * able to observe expressions and not just objects, so long as the expressions
 * are computed from observable objects.
 *
 * See the [observable] annotation and the [observe] function.
 */
// Note: one intentional difference from Harmony Object.observe is that our
// change batches are tracked on a per-observed expression basis, instead of
// per-observer basis.
// We do this because there is no cheap way to store a pointer on a Dart
// function (Expando uses linear search on the VM: http://dartbug.com/7558).
// This difference means that a given observer will be called with one batch of
// changes for each object it is observing.
library observe;

import 'dart:collection';
// TODO(jmesserly): see if we can switch to Future.immediate. We need it to be
// fast (next microtask) like our version, though.
import 'src/utils.dart' show setImmediate;
import 'observe/list.dart';
import 'observe/map.dart';
import 'observe/reference.dart';
import 'observe/set.dart';

// TODO(jmesserly): support detailed change records on our collections, such as
// INSERT/REMOVE, so we can use them from templates. Unlike normal objects,
// list/map/set can add or remove new observable things at runtime, so it's
// important to provide a way to listen for that.
export 'observe/list.dart';
export 'observe/map.dart';
export 'observe/reference.dart';
export 'observe/set.dart';

// TODO(jmesserly): notifyRead/notifyWrite are only used by people
// implementating advanced observable functionality. They need to be public, but
// ideally they would not be in the top level "observe" library.

/**
 * Use `@observable` to make a class observable. All fields in the class will
 * be transformed to track changes. The overhead will be minimal unless they are
 * actually being observed.
 */
const observable = const Object();

/** Callback fired when an expression changes. */
typedef void ChangeObserver(ChangeNotification e);

/** A function that unregisters the [ChangeObserver]. */
typedef void ChangeUnobserver();

/** A function that computes a value. */
typedef Object ObservableExpression();

/**
 * Test for equality of two objects. For example [Object.==] and [identical]
 * are two kinds of equality tests.
 */
typedef bool EqualityTest(Object a, Object b);

/**
 * A notification of a change to an [ObservableExpression] that is passed to a
 * [ChangeObserver].
 */
// TODO(jmesserly): rename to ChangeRecord?
class ChangeNotification {

  /** Previous value seen on the watched expression. */
  final oldValue;

  /** New value seen on the watched expression. */
  final newValue;

  ChangeNotification(this.oldValue, this.newValue);

  // Note: these two methods are here mainly to make testing easier.
  bool operator ==(other) {
    return other is ChangeNotification && oldValue == other.oldValue &&
        newValue == other.newValue;
  }

  String toString() => 'change from $oldValue to $newValue';
}

/**
 * Observes the [expression] and delivers asynchronous notifications of changes
 * to the [callback].
 *
 * The expression is considered to have changed if the values no longer compare
 * equal via the equality operator. You can perform additional comparisons in
 * the [callback] if desired.
 *
 * Returns a function that can be used to stop observation.
 * Calling this makes it possible for the garbage collector to reclaim memory
 * associated with the observation and prevents further calls to [callback].
 *
 * Because notifications are delivered asynchronously and batched, only a single
 * notification is provided for all changes that were made prior to running
 * callback. Intermediate values of the expression are not saved. Instead,
 * [ChangeNotification.oldValue] represents the value before any changes, and
 * [ChangeNotification.newValue] represents the current value of [expression]
 * at the time that [callback] is called.
 *
 * You can force a synchronous change delivery at any time by calling
 * [deliverChangesSync]. Calling this method if there are no changes has no
 * effect. If changes are delivered by deliverChangesSync, they will not be
 * delivered again asynchronously, unless the value is changed again.
 *
 * Any errors thrown by [expression] and [callback] will be caught and sent to
 * [onObserveUnhandledError].
 */
// TODO(jmesserly): debugName is here to workaround http://dartbug.com/8419.
ChangeUnobserver observe(ObservableExpression expression,
    ChangeObserver callback, [String debugName]) {

  var observer = new _ExpressionObserver(expression, callback, debugName);
  if (!observer._observe()) {
    // If we didn't actually read anything, return a pointer to a no-op
    // function so the observer can be reclaimed immediately.
    return _doNothing;
  }

  return observer._unobserve;
}

/**
 * Converts the [Iterable], [Set] or [Map] to an [ObservableList],
 * [ObservableSet] or [ObservableMap] respectively.
 *
 * The resulting object will contain a shallow copy of the data.
 * If [value] is not one of those collection types, it will be returned
 * unmodified.
 *
 * If [value] is a [Map], the resulting value will use the appropriate kind of
 * backing map: either [HashMap], [LinkedHashMap], or [SplayTreeMap].
 */
toObservable(value) {
  if (value is Map) {
    var createMap = null;
    if (value is SplayTreeMap) {
      createMap = () => new SplayTreeMap();
    } else if (value is LinkedHashMap) {
      createMap = () => new LinkedHashMap();
    }
    return new ObservableMap.from(value, createMap: createMap);
  }
  if (value is Set) return new ObservableSet.from(value);
  if (value is Iterable) return new ObservableList.from(value);
  return value;
}

// Optimizations to avoid extra work if observing const/final data.
void _doNothing() {}

/**
 * The current observer that is tracking reads, or null if we aren't tracking
 * reads. Reads are tracked when executing [_ExpressionObserver._observe].
 */
_ExpressionObserver _activeObserver;

/**
 * True if we are observing reads. This should be checked before calling
 * [notifyRead].
 *
 * Note: this type is used by objects implementing observability.
 * You should not need it if your type is marked `@observable`.
 */
bool get observeReads => _activeObserver != null;

/**
 * Notify the system of a new read. This will add the current change observer
 * to the set of observers for this field.  This should *only* be called when
 * [observeReads] is true, and it will initialize [observers] if it is null.
 * For example:
 *
 *     get foo {
 *       if (observeReads) _fooObservers = notifyRead(_fooObservers);
 *       return _foo;
 *     }
 *
 * Note: this function is used to implement observability.
 * You should not need it if your type is marked `@observable`.
 *
 * See also: [notifyWrite]
 */
Object notifyRead(fieldObservers) {
  // Note: fieldObservers starts null, then a single observer, then a List.
  _activeObserver._wasRead = true;

  // Note: there's some optimization here to avoid allocating an observer list
  // unless we really need it.
  if (fieldObservers == null) {
    return _activeObserver;
  }
  if (fieldObservers is _ExpressionObserver) {
    if (identical(fieldObservers, _activeObserver) || fieldObservers._dead) {
      return _activeObserver;
    }
    return [fieldObservers, _activeObserver];
  }
  return fieldObservers..add(_activeObserver);
}

/**
 * Notify the system of a new write. This will deliver a change notification
 * to the set of observers for this field. This should *only* be called for a
 * non-null list of [observers]. For example:
 *
 *     set foo(value) {
 *       if (_fooObservers != null && _foo != value) {
 *         _fooObservers = notifyWrite(_fooObservers);
 *       }
 *       _foo = value;
 *     }
 *
 * Note: this function is used to implement observability.
 * You should not need it if your type is marked `@observable`.
 *
 * See also: [notifyRead]
 */
Object notifyWrite(Object fieldObservers) {
  if (_pendingWrites == null) {
    _pendingWrites = [];
    setImmediate(deliverChangesSync);
  }
  _pendingWrites.add(fieldObservers);

  // Clear fieldObservers. This will prevent a second notification for this
  // same set of observers on the current event loop. It also frees associated
  // memory. If the item needs to be observed again, that will happen in
  // _ExpressionObserver._deliver.

  // NOTE: ObservableMap depends on this returning null.
  return null;
}

List _pendingWrites;

/**
 * The limit of times we will attempt to deliver a set of pending changes.
 *
 * [deliverChangesSync] will attempt to deliver pending changes until there are
 * no more. If one of the pending changes causes another batch of changes, it
 * will iterate again and increment the iteration counter. Once it reaches
 * this limit it will call [onCircularNotifyLimit].
 *
 * Note that there is no limit to the number of changes per batch, only to the
 * number of iterations.
 */
int circularNotifyLimit = 100;

/**
 * Delivers observed changes immediately. Normally you should not call this
 * directly, but it can be used to force synchronous delivery, which helps in
 * certain cases like testing.
 */
void deliverChangesSync() {
  int iterations = 0;
  while (_pendingWrites != null) {
    var pendingWrites = _pendingWrites;
    _pendingWrites = null;

    // Sort pending observers by order added.
    // TODO(jmesserly): this is here to help our template system, which relies
    // on earlier observers removing later ones to prevent them from firing.
    // See if we can find a better solution at the template level.
    var pendingObservers = new SplayTreeMap<num, _ExpressionObserver>();
    for (var pending in pendingWrites) {
      if (pending is _ExpressionObserver) {
        pendingObservers[pending._id] = pending;
      } else {
        for (var observer in pending) {
          pendingObservers[observer._id] = observer;
        }
      }
    }

    if (iterations++ == circularNotifyLimit) {
      _diagnoseCircularLimit(pendingObservers);
      return;
    }

    // TODO(jmesserly): we are avoiding SplayTreeMap.values because it performs
    // an unnecessary copy. If that gets fixed we can use .values here.
    // https://code.google.com/p/dart/issues/detail?id=8516
    pendingObservers.forEach((id, obs) { obs._deliver(); });
  }
}

/**
 * Attempt to provide diagnostics about what change is causing a loop in
 * observers. Unfortunately it is hard to help the programmer unless they have
 * provided a `debugName` to [observe], as callbacks are hard to debug
 * because of <http://dartbug.com/8419>. However we can print the records that
 * changed which has proved helpful.
 */
void _diagnoseCircularLimit(Map<int, _ExpressionObserver> pendingObservers) {
  // TODO(jmesserly,sigmund): we could do purity checks when running "observe"
  // itself, to detect if it causes writes to happen. I think that case is less
  // common than cycles caused by the notifications though.

  var trace = new StringBuffer('exceeded notifiction limit of '
      '${circularNotifyLimit}, possible '
      'circular reference in observers: ');

  int i = 0;
  pendingObservers.forEach((id, obs) {
    var change = obs._deliver();
    if (change == null || i < 10) return;

    if (i != 0) trace.write(', ');
    trace.write('$obs $change');
    i++;
  });

  // Throw away pending changes to prevent repeating this error.
  _pendingWrites = null;

  onCircularNotifyLimit(trace.toString());
}


class _ExpressionObserver {
  static int _nextId = 0;

  /**
   * The ID indicating creation order. We will call observers in ID order.
   * See the TODO in [deliverChangesSync].
   */
  final int _id = ++_ExpressionObserver._nextId;

  // Note: fields in this class are private because instances of this class are
  // exposed via notifyRead.
  ObservableExpression _expression;

  ChangeObserver _callback;

  /** The last value of this observable. */
  Object _value;

  /**
   * Whether this observer was read at all.
   * If it wasn't read, we can free it immediately.
   */
  bool _wasRead;

  /**
   * The name used for debugging. This will be removed once Dart has
   * better debugging of callbacks.
   */
  String _debugName;

  _ExpressionObserver(this._expression, this._callback, this._debugName);

  /** True if this observer has been unobserved. */
  // Note: any time we call out to user-provided code, they might call
  // unobserve, so we need to guard against that.
  bool get _dead => _callback == null;

  String toString() =>
      _debugName != null ? '<observer $_id: $_debugName>' : '<observer $_id>';

  bool _observe() {
    // If an observe call starts another observation, we need to make sure that
    // the outer observe is tracked correctly.
    var parent = _activeObserver;
    _activeObserver = this;

    _wasRead = false;
    try {
      _value = _expression();
    } catch (e, trace) {
      onObserveUnhandledError(e, trace, _expression);
      _value = null;
    }

    // TODO(jmesserly): should the parent also observe us?
    assert(_activeObserver == this);
    _activeObserver = parent;

    return _wasRead;
  }

  void _unobserve() {
    if (_dead) return;

    // Note: we don't remove ourselves from objects that we are observing.
    // That will happen automatically when those fields are written.
    // Instead, we release our own memory and wait for notifyWrite and
    // deliverChangesSync to do the rest.
    // TODO(jmesserly): this is probably too over-optimized. We'll need to
    // revisit this to provide detailed change records.
    _expression = null;
    _callback = null;
    _value = null;
    _wasRead = null;
    _debugName = null;
  }

  /**
   * _deliver does two things:
   * 1. Evaluate the expression to compute the new value.
   * 2. Invoke observer for this expression.
   *
   * Note: if you mutate a shared value from one observer, future
   * observers will see the updated value. Essentially, we collapse
   * the two change notifications into one.
   *
   * We could split _deliver into two methods, one to compute the new value
   * and another to call observers. But the current order has benefits too: it
   * preserves the invariant that ChangeNotification.newValue equals the current
   * value of the expression.
   */
  ChangeNotification _deliver() {
    if (_dead) return null;

    // Call the expression again to compute the new value, and to get the new
    // list of dependencies.
    var oldValue = _value;
    _observe();

    // Note: whenever we run code we don't control, we need to check _dead again
    // in case they have unobserved this object. This means `_observe`, `==`,
    // need to check.
    if (_dead) return null;

    bool equal;
    try {
      equal = oldValue == _value;
    } catch (e, trace) {
      onObserveUnhandledError(e, trace, null);
      return null;
    }

    if (equal || _dead) return null;

    var change = new ChangeNotification(oldValue, _value);
    try {
      _callback(change);
    } catch (e, trace) {
      onObserveUnhandledError(e, trace, _callback);
    }
    return change;
  }

  // TODO(jmesserly): workaround for terrible VM hash code performance.
  int get hashCode => _id;
}

typedef void CircularNotifyLimitHandler(String message);

/**
 * Function that is called when change notifications get stuck in a circular
 * loop, which can happen if one [ChangeObserver] causes another change to
 * happen, and that change causes another, etc.
 *
 * This is called when [circularNotifyLimit] is reached by
 * [deliverChangesSync]. Circular references are commonly the result of not
 * correctly implementing equality for objects.
 *
 * The default behavior is to print the message.
 */
// TODO(jmesserly): using Logger seems better, but by default it doesn't do
// anything, which leads to unobserved errors.
CircularNotifyLimitHandler onCircularNotifyLimit = (message) => print(message);

/**
 * A function that handles an [error] given the [stackTrace] and [callback] that
 * caused the error.
 */
typedef void ObserverErrorHandler(error, stackTrace, Function callback);

/**
 * Callback to intercept unhandled errors in evaluating an observable.
 * Includes the error, stack trace, and the callback that caused the error.
 * By default it will use [defaultObserveUnhandledError], which prints the
 * error.
 */
ObserverErrorHandler onObserveUnhandledError = defaultObserveUnhandledError;

/** The default handler for [onObserveUnhandledError]. Prints the error. */
void defaultObserveUnhandledError(error, trace, callback) {
  // TODO(jmesserly): using Logger seems better, but by default it doesn't do
  // anything, which leads to unobserved errors.
  // Ideally we could make this show up as an error in the browser's console.
  print('web_ui.observe: unhandled error in callback $callback.\n'
      'error:\n$error\n\nstack trace:\n$trace');
}
