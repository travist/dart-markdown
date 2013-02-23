// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library web_components.src.utils;

import 'dart:async';
import 'dart:isolate';
import 'package:web_ui/src/messages.dart';

/**
 * Converts a string name with hyphens into an identifier, by removing hyphens
 * and capitalizing the following letter. Optionally [startUppercase] to
 * captialize the first letter.
 */
String toCamelCase(String hyphenedName, {bool startUppercase: false}) {
  var segments = hyphenedName.split('-');
  int start = startUppercase ? 0 : 1;
  for (int i = start; i < segments.length; i++) {
    var segment = segments[i];
    if (segment.length > 0) {
      // Character between 'a'..'z' mapped to 'A'..'Z'
      segments[i] = '${segment[0].toUpperCase()}${segment.substring(1)}';
    }
  }
  return segments.join('');
}

/**
 * Invokes [callback], logs how long it took to execute in ms, and returns
 * whatever [callback] returns. The log message will be printed if [printTime]
 * is true.
 */
time(String logMessage, callback(),
     {bool printTime: false, bool useColors: false}) {
  final watch = new Stopwatch();
  watch.start();
  var result = callback();
  watch.stop();
  final duration = watch.elapsedMilliseconds;
  if (printTime) {
    _printMessage(logMessage, duration, useColors);
  }
  return result;
}

/**
 * Invokes [callback], logs how long it takes from the moment [callback] is
 * executed until the future it returns is completed. Returns the future
 * returned by [callback]. The log message will be printed if [printTime]
 * is true.
 */
Future asyncTime(String logMessage, Future callback(),
                 {bool printTime: false, bool useColors: false}) {
  final watch = new Stopwatch();
  watch.start();
  return callback()..then((_) {
    watch.stop();
    final duration = watch.elapsedMilliseconds;
    if (printTime) {
      _printMessage(logMessage, duration, useColors);
    }
  });
}

void _printMessage(String logMessage, int duration, bool useColors) {
  var buf = new StringBuffer();
  buf.write(logMessage);
  for (int i = logMessage.length; i < 60; i++) buf.write(' ');
  buf.write(' -- ');
  if (useColors) {
    buf.write(GREEN_COLOR);
  }
  if (duration < 10) buf.write(' ');
  if (duration < 100) buf.write(' ');
  buf..write(duration)..write(' ms');
  if (useColors) {
    buf.write(NO_COLOR);
  }
  print(buf.toString());
}

// Color constants used for generating messages.
final String GREEN_COLOR = '\u001b[32m';
final String RED_COLOR = '\u001b[31m';
final String MAGENTA_COLOR = '\u001b[35m';
final String NO_COLOR = '\u001b[0m';

/** Find and return the first element in [list] that satisfies [matcher]. */
find(List list, bool matcher(elem)) {
  for (var elem in list) {
    if (matcher(elem)) return elem;
  }
  return null;
}


/** A future that waits until all added [Future]s complete. */
// TODO(sigmund): this should be part of the futures/core libraries.
class FutureGroup {
  const _FINISHED = -1;

  int _pending = 0;
  Future _failedTask;
  final Completer<List> _completer = new Completer<List>();
  final List results = [];

  /** Gets the task that failed, if any. */
  Future get failedTask => _failedTask;

  /**
   * Wait for [task] to complete.
   *
   * If this group has already been marked as completed, you'll get a
   * [FutureAlreadyCompleteException].
   *
   * If this group has a [failedTask], new tasks will be ignored, because the
   * error has already been signaled.
   */
  void add(Future task) {
    if (_failedTask != null) return;
    if (_pending == _FINISHED) throw new StateError("Future already completed");

    _pending++;
    var i = results.length;
    results.add(null);
    task.then((res) {
      results[i] = res;
      if (_failedTask != null) return;
      _pending--;
      if (_pending == 0) {
        _pending = _FINISHED;
        _completer.complete(results);
      }
    }, onError: (e) {
      if (_failedTask != null) return;
      _failedTask = task;
      _completer.completeError(e.error, e.stackTrace);
    });
  }

  Future<List> get future => _completer.future;
}


/**
 * Escapes [text] for use in a Dart string.
 * [single] specifies single quote `'` vs double quote `"`.
 * [triple] indicates that a triple-quoted string, such as `'''` or `"""`.
 */
String escapeDartString(String text, {bool single: true, bool triple: false}) {
  // Note: don't allocate anything until we know we need it.
  StringBuffer result = null;

  for (int i = 0; i < text.length; i++) {
    int code = text.codeUnitAt(i);
    var replace = null;
    switch (code) {
      case 92/*'\\'*/: replace = r'\\'; break;
      case 36/*r'$'*/: replace = r'\$'; break;
      case 34/*'"'*/:  if (!single) replace = r'\"'; break;
      case 39/*"'"*/:  if (single) replace = r"\'"; break;
      case 10/*'\n'*/: if (!triple) replace = r'\n'; break;
      case 13/*'\r'*/: if (!triple) replace = r'\r'; break;

      // Note: we don't escape unicode characters, under the assumption that
      // writing the file in UTF-8 will take care of this.

      // TODO(jmesserly): do we want to replace any other non-printable
      // characters (such as \f) for readability?
    }

    if (replace != null && result == null) {
      result = new StringBuffer(text.substring(0, i));
    }

    if (result != null) result.write(replace != null ? replace : text[i]);
  }

  return result == null ? text : result.toString();
}

const _LF = 10;
bool _isWhitespace(int charCode) {
  switch (charCode) {
    case 9:  // '\t'
    case _LF: // '\n'
    case 12: // '\f'
    case 13: // '\r'
    case 32: // ' '
      return true;
  }
  return false;
}


/**
 * Trims or compacts the leading/trailing white spaces of [text]. If the leading
 * spaces contain no line breaks, then all spaces are merged into a single
 * space. Similarly, for trailing spaces. These are examples of what this
 * function would return on a given input:
 *
 *       trimOrCompact('  x  ')          => ' x '
 *       trimOrCompact('\n\n  x  \n')    => 'x'
 *       trimOrCompact('\n\n  x       ') => 'x '
 *       trimOrCompact('\n\n  ')         => ''
 *       trimOrCompact('      ')         => ' '
 *       trimOrCompact(' \nx ')          => ' x '
 *       trimOrCompact('  x\n ')         => ' x'
 */
String trimOrCompact(String text) {
  int first = 0;
  int len = text.length;
  int last = len - 1;
  bool hasLineBreak = false;

  while (first < len) {
    var ch = text.codeUnitAt(first);
    if (!_isWhitespace(ch)) break;
    if (ch == _LF) hasLineBreak = true;
    first++;
  }

  // If we just have spaces, return either an empty string or a single space
  if (first > last) return hasLineBreak || text.isEmpty ? '' : ' ';

  // Include a space in the output if there was a line break.
  if (first > 0 && !hasLineBreak) first--;

  hasLineBreak = false;
  while (last > 0) {
    var ch = text.codeUnitAt(last);
    if (!_isWhitespace(ch)) break;
    if (ch == _LF) hasLineBreak = true;
    last--;
  }

  if (last < len - 1 && !hasLineBreak) last++;
  if (first == 0 && last == len - 1) return text;
  return text.substring(first, last + 1);
}

// TODO(jmesserly): this should exist in dart:isolates
/**
 * Adds an event to call [callback], so the event loop will call this after the
 * current stack has unwound.
 */
void setImmediate(void callback()) {
  var port = new ReceivePort();
  port.receive((msg, sendPort) {
    port.close();
    callback();
  });
  port.toSendPort().send(null);
}

/** Iterates through an infinite sequence, starting from zero. */
class IntIterator implements Iterator<int> {
  int _next = -1;

  int get current => _next < 0 ? null : _next;

  bool moveNext() {
    _next++;
    return true;
  }
}
