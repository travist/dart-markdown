// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * A doubly-linked list, adapted from DoubleLinkedQueueEntry in
 * sdk/lib/collection/queue.dart.
 */
// TODO(jmesserly): this should be in a shared pkg somewhere. Surely I am not
// the only person who will want to use a linked list :)
library linked_list;

/**
 * An entry in a doubly linked list. It contains a pointer to the next
 * entry, the previous entry, and the boxed value.
 */
class LinkedListNode<E> {
  LinkedListNode<E> _previous;
  LinkedListNode<E> _next;
  LinkedList<E> _list;
  E _value;

  LinkedListNode._(E e, this._list) {
    _value = e;
  }

  void _link(LinkedListNode<E> p, LinkedListNode<E> n) {
    if (_list != null) _list._length++;
    _next = n;
    _previous = p;
    p._next = this;
    n._previous = this;
  }

  LinkedListNode<E> append(E e) =>
      new LinkedListNode<E>._(e, _list).._link(this, _next);

  LinkedListNode<E> prepend(E e) =>
    new LinkedListNode<E>._(e, _list).._link(_previous, this);

  void remove() {
    if (_list != null) _list._length--;
    if (_previous != null) _previous._next = _next;
    if (_next != null) _next._previous = _previous;
    _next = null;
    _previous = null;
    _list = null;
  }

  LinkedListNode<E> get _nonSentinel => this;

  LinkedListNode<E> get previous =>
      _previous == null ? null : _previous._nonSentinel;

  LinkedListNode<E> get next =>
      _next == null ? null : _next._nonSentinel;

  E get value => _value;

  set value(E e) => _value = e;
}

/**
 * A sentinel in a double linked list is used to manipulate the list
 * at both ends. A double linked list has exactly one sentinel, which
 * is the only entry when the list is constructed. Initially, a
 * sentinel has its next and previous entry point to itself. A
 * sentinel does not box any user value.
 */
class LinkedListSentinel<E> extends LinkedListNode<E> {
  LinkedListSentinel() : super._(null, null) {
    _link(this, this);
  }

  void remove() {
    throw new StateError("Empty list");
  }

  LinkedListNode<E> get _nonSentinel => null;

  void set value(E e) {
    throw new StateError("Empty list");
  }

  E get value {
    throw new StateError("Empty list");
  }
}

class LinkedList<E> extends Iterable<E> {
  LinkedListSentinel<E> _sentinel = new LinkedListSentinel<E>();
  int get length => _length;
  int _length = 0;

  LinkedList() {
    _sentinel._list = this;
  }

  LinkedListNode<E> add(E e) => _sentinel.prepend(e);
  LinkedListNode<E> addLast(E e) => _sentinel.prepend(e);
  LinkedListNode<E> addFirst(E e) => _sentinel.append(e);
  void addAll(Iterable<E> e) => e.forEach(add);

  Iterator<E> get iterator => new LinkedListIterator<E>(this);
}

class LinkedListIterator<E> implements Iterator<E> {
  // Use a copy to support mutations where the current node, as well as any
  // number of subsequent nodes are removed.
  List<LinkedListNode<E>> _copy;
  LinkedList<E> _list;
  int _pos = -1;

  LinkedListIterator(this._list) {
    _copy = new List<LinkedListNode<E>>.fixedLength(_list.length);
    int i = 0;
    var node = _list._sentinel.next;
    while (node != null) {
      _copy[i++] = node;
      node = node.next;
    }
  }

  E get current =>
      (_pos >= 0 && _pos < _copy.length) ? _copy[_pos].value : null;

  bool moveNext() {
    do {
      _pos++;
      // Skip nodes that no longer are part of the list.
    } while (_pos < _copy.length && _copy[_pos]._list != _list);
    return _pos < _copy.length;
  }
}
