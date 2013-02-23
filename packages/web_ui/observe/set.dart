// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library web_ui.observe.set;

import 'dart:collection';
import 'package:web_ui/observe.dart';

/**
 * Represents an observable set of model values. If any items are added,
 * removed, or replaced, then observers that are registered with
 * [observe] will be notified.
 */
// TODO(jmesserly): ideally this could be based ObservableMap, or Dart
// would have a built in Set<->Map adapter as suggested in
// https://code.google.com/p/dart/issues/detail?id=5603
class ObservableSet<E> extends Collection<E> implements Set<E> {
  final Map<E, Object> _map;
  final Map<E, Object> _observeKey;
  Object _observeLength;

  final MapFactory<E> _createMap;

  /**
   * Creates an observable set, optionally using the provided [createMap]
   * factory to construct a custom map type.
   */
  ObservableSet({MapFactory<E> createMap})
      : _map = createMap != null ? createMap() : new Map<E, Object>(),
        _observeKey = createMap != null ? createMap() : new Map<E, Object>(),
        _createMap = createMap;

  /**
   * Creates an observable set that contains all elements of [other].
   */
  factory ObservableSet.from(Iterable<E> other, {MapFactory<E> createMap}) {
    return new ObservableSet<E>(createMap: createMap)..addAll(other);
  }

  void _notifyReadKey(E key) {
    if (observeReads) _observeKey[key] = notifyRead(_observeKey[key]);
  }

  void _notifyReadAll() {
    if (!observeReads) return;
    _observeLength = notifyRead(_observeLength);
    for (E key in _map.keys) {
      _observeKey[key] = notifyRead(_observeKey[key]);
    }
  }

  void _notifyReadLength() {
    if (observeReads) _observeLength = notifyRead(_observeLength);
  }

  void _notifyWriteLength(int originalLength) {
    if (_observeLength != null && originalLength != _map.length) {
      _observeLength = notifyWrite(_observeLength);
    }
  }

  void _notifyWriteKey(E key) {
    var observer = _observeKey.remove(key);
    if (observer != null) notifyWrite(observer);
  }

  /**
   * Returns true if [value] is in the set.
   */
  bool contains(E value) {
    _notifyReadKey(value);
    return _map.containsKey(value);
  }

  /**
   * Adds [value] into the set. The method has no effect if
   * [value] was already in the set.
   */
  void add(E value) {
    int len = _map.length;
    _map[value] = const Object();
    if (len != _map.length) _notifyWriteKey(value);
    _notifyWriteLength(len);
  }

  /**
   * Removes [value] from the set. Returns true if [value] was
   * in the set. Returns false otherwise. The method has no effect
   * if [value] value was not in the set.
   */
  bool remove(E value) {
    // notifyRead because result depends on if the key already exists
    _notifyReadKey(value);

    int len = _map.length;
    bool result =  _map.remove(value) != null;
    if (len != _map.length) _notifyWriteKey(value);
    _notifyWriteLength(len);
    return result;
  }

  /**
   * Removes all elements in the set.
   */
  void clear() {
    int len = _map.length;
    _map.clear();
    _notifyWriteLength(len);
    _observeKey.values.forEach(notifyWrite);
    _observeKey.clear();
  }

  int get length {
    _notifyReadLength();
    return _map.length;
  }

  bool get isEmpty => length == 0;

  Iterator<E> get iterator => new _ObservableSetIterator<E>(this);

  /**
   * Adds all the elements of the given collection to the set.
   */
  void addAll(Collection<E> collection) => collection.forEach(add);

  /**
   * Removes all the elements of the given collection from the set.
   */
  void removeAll(Collection<E> collection) => collection.forEach(remove);

  /**
   * Returns true if [collection] contains all the elements of this
   * collection.
   */
  bool isSubsetOf(Collection<E> collection) =>
      new Set<E>.from(collection).containsAll(this);

  /**
   * Returns true if this collection contains all the elements of
   * [collection].
   */
  bool containsAll(Collection<E> collection) => collection.every(contains);

  /**
   * Returns a new set which is the intersection between this set and
   * the given collection.
   */
  ObservableSet<E> intersection(Collection<E> collection) {
    var result = new ObservableSet<E>(createMap: _createMap);

    for (E value in collection) {
      if (contains(value)) result.add(value);
    }
    return result;
  }

  String toString() => Collections.collectionToString(this);
}

class _ObservableSetIterator<E> implements Iterator<E> {
  final ObservableSet<E> _set;
  final Iterator<E> _iterator;

  _ObservableSetIterator(ObservableSet<E> set)
      : _set = set, _iterator = set._map.keys.iterator;

  bool moveNext() {
    _set._notifyReadLength();
    return _iterator.moveNext();
  }

  E get current {
    var result = _iterator.current;
    if (result != null) _set._notifyReadKey(result);
    return result;
  }
}
