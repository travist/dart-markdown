// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * Part of the template compilation that concerns with simplifying HTML trees to
 * emit trimmed simple HTML code.
 */
library html_cleaner;

import 'package:html5lib/dom.dart';
import 'package:csslib/parser.dart' as css;

import 'info.dart';

/** Removes bindings and extra nodes from the HTML assciated with [info]. */
void cleanHtmlNodes(info) => new _HtmlCleaner().visit(info);

/** Remove all MDV attributes; post-analysis these attributes are not needed. */
class _HtmlCleaner extends InfoVisitor {
  ComponentInfo _component = null;

  void visitComponentInfo(ComponentInfo info) {
    // Remove the <element> tag from the tree
    if (info.elemInfo != null) info.elemInfo.node.remove();

    var oldComponent = _component;
    _component = info;
    super.visitComponentInfo(info);
    _component = oldComponent;
  }

  void visitElementInfo(ElementInfo info) {
    var node = info.node;
    info.removeAttributes.forEach(node.attributes.remove);
    info.removeAttributes.clear();

    // Hide all template elements. At the very least, we must do this for
    // template attributes, such as `<td template if="cond">`.
    if (info.hasIfCondition && !info.isTemplateElement) {
      node.attributes['style'] = 'display:none';
    }

    if (info.childrenCreatedInCode) {
      node.nodes.clear();
    }

    if (node.tagName == 'style' && node.attributes.containsKey("scoped") &&
        _component != null) {
      // Remove the style tag we've parsed the CSS.
      node.remove();
    }

    super.visitElementInfo(info);
  }
}
