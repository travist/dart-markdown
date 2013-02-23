// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library classify_css;

import '../../classify.dart';
import 'package:csslib/parser.dart';
import 'package:source_maps/source_maps.dart';

String classifyCss(String src) {
  var buf = new StringBuffer();
  var file = new File.text("styles.css", src);
  var tokenizer = new Tokenizer(file, src, false);
  var token = tokenizer.next();
  while (token.kind != TokenKind.END_OF_FILE) {
    switch (token.kind) {
      case TokenKind.COMMENT:
        addSpan(buf, Classification.COMMENT, token.text);
      break;
      case TokenKind.IDENTIFIER:
        addSpan(buf, Classification.KEYWORD, token.text);
      break;
      case TokenKind.INTEGER:
      case TokenKind.HEX_INTEGER:
      case TokenKind.DOUBLE:
      case TokenKind.PERCENT:
        addSpan(buf, Classification.NUMBER, token.text);
      break;
      default:
        buf.write(token.text);
    }
    print('> ${token.kind} ${token.text}');
    token = tokenizer.next();
  }
  
  return buf.toString();
}
