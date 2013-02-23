// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library html_css_fixup;

import 'dart:json' as json;

import 'package:html5lib/dom.dart';
import 'package:html5lib/dom_parsing.dart';
import 'package:csslib/visitor.dart';

import 'info.dart';
import 'messages.dart';
import 'options.dart';

/**
 *  If processCss is enabled, prefix any component's HTML attributes for id or
 *  class to reference the mangled CSS class name or id.
 *
 *  Adds prefix error/warning messages to [messages], if [messages] is
 *  supplied.
 */
void fixupHtmlCss(FileInfo fileInfo, CompilerOptions opts) {
  // Walk the HTML tree looking for class names or id that are in our parsed
  // stylesheet selectors and making those CSS classes and ids unique to that
  // component.
  if (opts.verbose) print("  CSS fixup ${fileInfo.path.filename}");
  for (var component in fileInfo.declaredComponents) {
    if (component.styleSheet != null) {
      // If polyfill is on prefix component name to all CSS classes and ids
      // referenced in the scoped style.
      var prefix = opts.processCss ? component.tagName : '';
      var knownCss = new IdClassVisitor()..visitTree(component.styleSheet);
      new _HtmlCss(knownCss, prefix, opts).visit(component.element);
    }
  }
}

/** Build list of every CSS class name and id selector in a stylesheet. */
class IdClassVisitor extends Visitor {
  final Set<String> classes = new Set();
  final Set<String> ids = new Set();

  void visitClassSelector(ClassSelector node) {
    classes.add(node.name);
  }

  void visitIdSelector(IdSelector node) {
    ids.add(node.name);
  }
}

/** Build the Dart `_css` list of managled class names. */
Map createCssSimpleSelectors(IdClassVisitor visitedCss, ComponentInfo info,
                     {scopedStyles: true}) {
  Map selectors = {};
  if (visitedCss != null) {
    for (var cssClass in visitedCss.classes) {
      selectors['.$cssClass'] =
          scopedStyles ? '${info.tagName}_$cssClass' : cssClass;
    }
    for (var id in visitedCss.ids) {
      selectors['#$id'] = scopedStyles ? '${info.tagName}_$id' : id;
    }
  }
  return selectors;
}

/**
 * Return a map of simple CSS selectors (class and id selectors) as a Dart map
 * definition.
 */
String createCssSelectorsDefinition(ComponentInfo info, bool cssPolyfill) {
  var cssVisited = new IdClassVisitor();
  if (info.styleSheet != null) cssVisited..visitTree(info.styleSheet);
  var css = json.stringify(createCssSimpleSelectors(cssVisited, info,
      scopedStyles: cssPolyfill));

  return 'static Map<String, String> _css = $css;';
}

/**
 * Mangles an HTML class reference that matches a CSS class name defined in the
 * component's style sheet.
 */
void mangleClassAttribute(Node node, Set<String> classes, String prefix,
                          bool verbose) {
  if (node.attributes.containsKey('class')) {
    var refClasses = node.attributes['class'].trim().split(" ");

    bool changed = false;
    var len = refClasses.length;
    for (var idx = 0; idx < len; idx++) {
      var refClass = refClasses[idx];
      if (classes.contains(refClass)) {
        refClasses[idx] = prefix.length > 0 ? "${prefix}_$refClass" : refClass;
        changed = true;
      }
    }

    if (changed) {
      StringBuffer newClasses = new StringBuffer();
      refClasses.forEach((String className) {
        newClasses.write("${(newClasses.length > 0) ? ' ' : ''}$className");
      });
      var mangledClasses = newClasses.toString();
      if (verbose) {
        print("    class = ${node.attributes['class'].trim()} => "
            "$mangledClasses");
      }
      node.attributes['class'] = mangledClasses;
    }
  }
}

/**
 * Mangles an HTML id reference that matches a CSS id selector name defined in
 * the component's style sheet.
 */
void mangleIdAttribute(Node node, Set<String> ids, String prefix,
                       bool verbose) {
  var id = node.attributes['id'];
  if (id != null && ids.contains(id)) {
    var mangledName = "${prefix}_$id";
    if (verbose) {
      print("    id = ${node.attributes['id'].toString()} => $mangledName");
    }
    node.attributes['id'] = mangledName;
  }
}

// TODO(terry): Consider handling binding where a class or id is mentioned
//              would be nice to automatically map these too.  Shouldn't have
//              to change this binding e.g.,
//
//                class = {{editing ? 'x-editing' : ''}}
//     to
//                class = {{editing ? _cssClass['x-editing'] : ''}}
/** Fixup any declared components HTML with class or id references. */
class _HtmlCss extends TreeVisitor {
  final CompilerOptions _options;

  /** Set of classes and ids defined for this component. */
  final IdClassVisitor _knownCss;

  /** Prefix to apply to each class/id reference. */
  final String _prefix;

  /**
   * Adds emitted error/warning messages to [_messages].
   * [_messages] must not be null.
   */
  _HtmlCss(this._knownCss, this._prefix, this._options);

  void visitElement(Element node) {
    mangleClassAttribute(node, _knownCss.classes, _prefix, _options.verbose);
    mangleIdAttribute(node, _knownCss.ids, _prefix, _options.verbose);
    super.visitElement(node);
  }
}
