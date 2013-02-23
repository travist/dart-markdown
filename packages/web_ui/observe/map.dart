// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library web_ui.observe.map;

import 'dart:collection';
import 'package:web_ui/observe.dart';
import 'list.dart';

typedef Map<K, dynamic> MapFactory<K>();

// TODO(jmesserly): this needs to be faster. We currently require multiple
// lookups per key to get the old value. Most likely this needs to be based on
// a modified HashMap source code.
/**
 * Represents an observable map of model values. If any items are added,
 * removed, or replaced, then observers that are registered with
 * [observe] will be notified.
 */
class ObservableMap<K, V> implements Map<K, V> {
  final Map<K, V> _map;
  final Map<K, Object> _observeKey;
  Object _observeLength;
  _ObservableMapKeyIterable<K, V> _keys;
  _ObservableMapValueIterable<K, V> _values;

  /**
   * Creates an observable map, optionally using the provided factory
   * [createMap] to construct a custom map type.
   */
  ObservableMap({MapFactory<K> createMap})
      : _map = createMap != null ? createMap() : new Map<K, V>(),
        _observeKey = createMap != null ? createMap() : new Map<K, Object>() {
    _keys = new _ObservableMapKeyIterable<K, V>(this);
    _values = new _ObservableMapValueIterable<K, V>(this);
  }

  /** Creates a new observable map using a [LinkedHashMap]. */
  ObservableMap.linked() : this(createMap: () => new LinkedHashMap());

  /**
   * Creates an observable map that contains all key value pairs of [other].
   */
  factory ObservableMap.from(Map<K, V> other, {MapFactory<K> createMap}) {
    var result = new ObservableMap<K, V>(createMap: createMap);
    other.forEach((K key, V value) { result[key] = value; });
    return result;
  }


  Iterable<K> get keys => _keys;

  Iterable<V> get values => _values;

  int get length {
    _notifyReadLength();
    return _map.length;
  }

  bool get isEmpty => length == 0;

  void _notifyReadKey(K key) {
    if (observeReads) _observeKey[key] = notifyRead(_observeKey[key]);
  }

  void _notifyReadLength() {
    if (observeReads) _observeLength = notifyRead(_observeLength);
  }

  void _notifyReadAll() {
    if (!observeReads) return;
    _observeLength = notifyRead(_observeLength);
    for (K key in _map.keys) {
      _observeKey[key] = notifyRead(_observeKey[key]);
    }
  }

  void _notifyWriteLength(int originalLength) {
    if (_observeLength != null && originalLength != _map.length) {
      _observeLength = notifyWrite(_observeLength);
    }
  }

  void _notifyWriteKey(K key) {
    var observer = _observeKey.remove(key);
    if (observer != null) notifyWrite(observer);
  }

  bool containsValue(V value) {
    _notifyReadAll();
    return _map.containsValue(value);
  }

  bool containsKey(K key) {
    _notifyReadKey(key);
    return _map.containsKey(key);
  }

  V operator [](K key) {
    _notifyReadKey(key);
    return _map[key];
  }

  void operator []=(K key, V value) {
    int len = _map.length;
    V oldValue = _map[key];
    _map[key] = value;
    // Note: if length changed, it means the key was added, so we need to
    // _notifyWriteKey. Also _notifyWriteLength will check if length changed.
    if (len != _map.length || oldValue != value) {
      _notifyWriteKey(key);
      _notifyWriteLength(len);
    }
  }

  V putIfAbsent(K key, V ifAbsent()) {
    // notifyRead because result depends on if the key already exists
    _notifyReadKey(key);

    int len = _map.length;
    V result = _map.putIfAbsent(key, ifAbsent);
    // Note: if length changed, it means the key was added, so we need to
    // _notifyWriteKey. Also _notifyWriteLength will check if length changed.
    if (len != _map.length) {
      _notifyWriteKey(key);
      _notifyWriteLength(len);
    }
    return result;
  }

  V remove(K key) {
    // notifyRead because result depends on if the key already exists
    _notifyReadKey(key);

    int len = _map.length;
    V result =  _map.remove(key);
    if (len != _map.length) {
      _notifyWriteKey(key);
      _notifyWriteLength(len);
    }
    return result;
  }

  void clear() {
    int len = _map.length;
    _map.clear();
    _notifyWriteLength(len);
    _observeKey.values.forEach(notifyWrite);
    _observeKey.clear();
  }

  void forEach(void f(K key, V value)) {
    _notifyReadAll();
    _map.forEach(f);
  }

  String toString() => Maps.mapToString(this);
}

class _ObservableMapKeyIterable<K, V> extends Iterable<K> {
  final ObservableMap<K, V> _map;
  _ObservableMapKeyIterable(this._map);

  Iterator<K> get iterator => new _ObservableMapKeyIterator<K, V>(_map);
}

class _ObservableMapKeyIterator<K, V> implements Iterator<K> {
  final ObservableMap<K, V> _map;
  final Iterator<K> _keys;

  _ObservableMapKeyIterator(ObservableMap<K, V> map)
      : _map = map,
        _keys = map._map.keys.iterator;

  bool moveNext() {
    _map._notifyReadLength();
    return _keys.moveNext();
  }

  K get current {
    var key = _keys.current;
    if (key != null) _map._notifyReadKey(key);
    return key;
  }
}


class _ObservableMapValueIterable<K, V> extends Iterable<V> {
  final ObservableMap<K, V> _map;
  _ObservableMapValueIterable(this._map);

  Iterator<V> get iterator => new _ObservableMapValueIterator<K, V>(_map);
}

class _ObservableMapValueIterator<K, V> implements Iterator<V> {
  final ObservableMap<K, V> _map;
  final Iterator<K> _keys;
  final Iterator<V> _values;

  _ObservableMapValueIterator(ObservableMap<K, V> map)
      : _map = map,
        _keys = map._map.keys.iterator,
        _values = map._map.values.iterator;

  bool moveNext() {
    _map._notifyReadLength();
    bool moreKeys = _keys.moveNext();
    bool moreValues = _values.moveNext();
    if (moreKeys != moreValues) {
      throw new StateError('keys and values should be the same length');
    }
    return moreValues;
  }

  V get current {
    var key = _keys.current;
    if (key != null) _map._notifyReadKey(key);
    return _values.current;
  }
}
