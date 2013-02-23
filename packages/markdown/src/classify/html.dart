// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library classify_html;

import '../../classify.dart';
//import 'dart.dart';
//import 'css.dart';
import 'package:html5lib/src/token.dart';
import 'package:html5lib/src/tokenizer.dart';

String classifyHtml(String src) {
  var out = new StringBuffer();
  var tokenizer = new HtmlTokenizer(src, 'utf8', true, true, true, true);
  var syntax = '';
  
  while (tokenizer.moveNext()) {
    var token = tokenizer.current;
    var classification = Classification.NONE;
    
    switch (token.kind)
    {
      case TokenKind.characters:
        var chars = token.span.text;
//        if (syntax == 'dart') {
//          chars = classifyDart(chars);
//        } else 
//        if (syntax == 'css') {
//          chars = classifyCss(chars);
//        } else {
          chars = escapeHtml(chars);
//        }
        out.write(chars);
        syntax = '';
      continue;
      case TokenKind.comment:
        classification = Classification.COMMENT;
      break;
      case TokenKind.doctype:
        classification = Classification.COMMENT;
      break;
        
      case TokenKind.startTag:
        addTag(out, token);
        if (token.name == 'script') {
          token.data.forEach((pair) {
            if (pair[0] == 'type' && pair[1] == 'application/dart') {
              syntax = 'dart';
            }
          });
        } else if (token.name == 'style') {
          syntax = 'css';
        }
      continue;
      
      case TokenKind.endTag:
        addTag(out, token);
      continue;
      
      case TokenKind.parseError:
        classification = Classification.ERROR;
      break;
      case TokenKind.spaceCharacters:
        classification = Classification.NONE;
      break;
    }
    var str = escapeHtml(token.span.text);
    out.write('<span class="$classification">$str</span>');
  }
  
  return out.toString();
}

final _RE_ATTR = new RegExp(r'( +[\w\-]+)( *= *)?(".+?")?');

String addTag(StringBuffer buf, TagToken token) {
  var start = token.kind == TokenKind.endTag ? 2 : 1;
  var end = token.selfClosing ? 2 : 1;
  var text = token.span.text;
  
  // Add the start of the tag.
  buf.write(escapeHtml(text.substring(0, start)));
  
  // Add the tag name.
  addSpan(buf, Classification.TYPE_IDENTIFIER, token.name);
  
  // Add the tag attributes.
  var content = text.substring(start, text.length - end);
  _RE_ATTR.allMatches(content).forEach((match) {
    addSpan(buf, Classification.KEYWORD, match[1]);
    if (match[2] != null) buf.write(match[2]);
    if (match[3] != null) {
      addSpan(buf, Classification.STRING, match[3]);
    }
  });
  
  // Add the end of the tag.
  buf.write(escapeHtml(text.substring(text.length - end, text.length)));
}
