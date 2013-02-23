// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library web_ui.observe.list;

import 'dart:collection';
import 'package:web_ui/observe.dart';

// TODO(jmesserly): this should extend the real list implementation.
// See http://dartbug.com/2600. The workaround was to copy+paste lots of code
// from the VM.
/**
 * Represents an observable list of model values. If any items are added,
 * removed, or replaced, then observers that are registered with
 * [observe] will be notified.
 */
class ObservableList<E> extends Collection<E> implements List<E> {
  /** The inner [List<E>] with the actual storage. */
  final List<E> _list;

  final List<Object> _observeIndex;
  Object _observeLength;

  /**
   * Creates an observable list of the given [length].
   *
   * If no [length] argument is supplied an extendable list of
   * length 0 is created.
   *
   * If a [length] argument is supplied, a fixed size list of that
   * length is created.
   */
  ObservableList([int length = 0])
      : _list = new List<E>(length),
        _observeIndex = new List<Object>(length);

  /**
   * Creates an observable list with the elements of [other]. The order in
   * the list will be the order provided by the iterator of [other].
   */
  factory ObservableList.from(Iterable<E> other) =>
      new ObservableList<E>()..addAll(other);

  Iterator<E> get iterator => new ListIterator<E>(this);

  int get length {
    if (observeReads) _observeLength = notifyRead(_observeLength);
    return _list.length;
  }

  set length(int value) {
    if (length == value) return;

    if (_observeLength != null) _observeLength = notifyWrite(_observeLength);

    // If we are shrinking the list, explicitly null out items so we track
    // the change to those items.
    for (int i = value; i < _list.length; i++) {
      this[i] = null;
    }
    _observeIndex.length = value;
    _list.length = value;
  }

  E operator [](int index) {
    if (observeReads) _observeIndex[index] = notifyRead(_observeIndex[index]);
    return _list[index];
  }

  operator []=(int index, E value) {
    var observer = _observeIndex[index];
    var oldValue = _list[index];
    if (observer != null && oldValue != value) {
      _observeIndex[index] = notifyWrite(observer);
    }
    _list[index] = value;
  }

  void add(E value) {
    if (_observeLength != null) _observeLength = notifyWrite(_observeLength);
    _list.add(value);
    _observeIndex.add(null);
  }

  // ---------------------------------------------------------------------------
  // Note: below this comment, methods are either:
  //   * redirect to Arrays
  //   * redirect to Collections
  //   * copy+paste from VM GrowableObjectArray.
  // The general idea is to have these methods operate in terms of our primitive
  // methods above, so they correctly track reads/writes.
  // ---------------------------------------------------------------------------

  bool remove(E item) {
    int i = indexOf(item);
    if (i == -1) return false;
    removeAt(i);
    return true;
  }

  // TODO(jmesserly): This should be on List, to match removeAt.
  // See http://code.google.com/p/dart/issues/detail?id=5375
  void insertAt(int index, E item) => insertRange(index, 1, item);

  bool contains(E item) => IterableMixinWorkaround.contains(_list, item);

  E get first => this[0];

  E removeLast() {
    var len = length - 1;
    var elem = this[len];
    length = len;
    return elem;
  }

  int indexOf(E element, [int start = 0]) =>
      Arrays.indexOf(this, element, start, length);

  int lastIndexOf(E element, [int start]) =>
      Arrays.lastIndexOf(this, element, start);

  ObservableList<E> getRange(int start, int length)  {
    if (length == 0) return [];
    Arrays.rangeCheck(this, start, length);
    List list = new ObservableList<E>(length);
    Arrays.copy(this, start, list, 0, length);
    return list;
  }

  bool get isEmpty => length == 0;

  E get last => this[length - 1];

  void addLast(E value) => add(value);

  void addAll(Iterable<E> collection) {
    for (E elem in collection) {
      add(elem);
    }
  }

  void sort([compare = Comparable.compare]) =>
      IterableMixinWorkaround.sortList(this, compare);

  Iterable<E> get reversed => IterableMixinWorkaround.reversedList(this);

  void clear() {
    this.length = 0;
  }

  E removeAt(int index) {
    if (index is! int) throw new ArgumentError(index);
    E result = this[index];
    int newLength = this.length - 1;
    Arrays.copy(this,
                index + 1,
                this,
                index,
                newLength - index);
    this.length = newLength;
    return result;
  }

  void setRange(int start, int length, List<E> from, [int startFrom = 0]) {
    Arrays.copy(from, startFrom, this, start, length);
  }

  void removeRange(int start, int length) {
    if (length == 0) {
      return;
    }
    Arrays.rangeCheck(this, start, length);
    Arrays.copy(this,
                start + length,
                this,
                start,
                this.length - length - start);
    this.length = this.length - length;
  }

  void insertRange(int start, int length, [E initialValue]) {
    if (length == 0) {
      return;
    }
    if ((length < 0) || (length is! int)) {
      throw new ArgumentError("invalid length specified $length");
    }
    if (start < 0 || start > this.length) {
      throw new RangeError.value(start);
    }
    var oldLength = this.length;
    this.length = oldLength + length;  // Will expand if needed.
    Arrays.copy(this,
                start,
                this,
                start + length,
                oldLength - start);
    for (int i = start; i < start + length; i++) {
      this[i] = initialValue;
    }
  }

  String toString() => Collections.collectionToString(this);
}

// TODO(jmesserly): copy+paste from collection-dev
/**
 * Iterates over a [List] in growing index order.
 */
class ListIterator<E> implements Iterator<E> {
  final List<E> _list;
  final int _length;
  int _position;
  E _current;

  ListIterator(List<E> list)
      : _list = list, _position = -1, _length = list.length;

  bool moveNext() {
    if (_list.length != _length) {
      throw new ConcurrentModificationError(_list);
    }
    int nextPosition = _position + 1;
    if (nextPosition < _length) {
      _position = nextPosition;
      _current = _list[nextPosition];
      return true;
    }
    _current = null;
    return false;
  }

  E get current => _current;
}
