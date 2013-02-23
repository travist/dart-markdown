// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library web_ui.observe.reference;

import 'package:web_ui/observe.dart';

/**
 * An observable reference to an value. Use this if you want to store a single
 * value. NOTE: it is generally better to use the `@observable` annotation on
 * your observable class. This class is provided for demonstration purposes, or
 * if you happen to need a single unnamed observable reference.
 */
class ObservableReference<T> {
  Object _observers;
  T _value;

  ObservableReference([T initialValue]) : _value = initialValue;

  T get value {
    if (observeReads) _observers = notifyRead(_observers);
    return _value;
  }

  void set value(T newValue) {
    if (_observers != null && _value != newValue) {
      _observers = notifyWrite(_observers);
    }
    _value = newValue;
  }
}
