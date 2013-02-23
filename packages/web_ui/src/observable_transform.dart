// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * Code transform for @observable. The core transformation is relatively
 * straightforward, and essentially like an editor refactoring. You can find the
 * core implementation in [transformClass], which is ultimately called by
 * [transformObservables], the entry point to this library.
 */
library observable_transform;

import 'package:analyzer_experimental/src/generated/ast.dart';
import 'package:analyzer_experimental/src/generated/error.dart';
import 'package:analyzer_experimental/src/generated/scanner.dart';
import 'dart_parser.dart';
import 'messages.dart';
import 'refactor.dart';

/**
 * Transform types in Dart [userCode] marked with `@observable` by hooking all
 * field setters, and notifying the observation system of the change. If the
 * code was changed this returns true, otherwise returns false. Modified code
 * can be found in [userCode.code].
 *
 * Note: there is no special checking for transitive immutability. It is up to
 * the rest of the observation system to handle check for this condition and
 * handle it appropriately. We do not want to violate reference equality of
 * any fields that are set into the object.
 */
TextEditTransaction transformObservables(DartCodeInfo userCode) {
  if (userCode == null || userCode.compilationUnit == null) return null;
  var transaction = new TextEditTransaction(userCode.code, userCode.sourceFile);
  transformCompilationUnit(userCode.compilationUnit, transaction);
  return transaction;
}

void transformCompilationUnit(CompilationUnit unit, TextEditTransaction code) {
  bool observeAll = unit.directives.any(
      (d) => d is LibraryDirective && hasObservable(d));

  for (var declaration in unit.declarations) {
    if (declaration is ClassDeclaration) {
      transformClass(declaration, code, observeAll);
    } else if (declaration is TopLevelVariableDeclaration) {
      if (observeAll || hasObservable(declaration)) {
        transformTopLevelField(declaration, code);
      }
    }
  }
}

/** True if the code has the `@observable` annotation. */
bool hasObservable(AnnotatedNode node) {
  // TODO(jmesserly): this isn't correct if observable has been imported
  // with a prefix, or cases like that. We should technically be resolving, but
  // that is expensive.
  return node.metadata.any((m) => m.name.name == 'observable' &&
      m.constructorName == null && m.arguments == null);
}

void transformClass(ClassDeclaration cls, TextEditTransaction code,
    bool observeAll) {

  observeAll = observeAll || hasObservable(cls);

  var changedFields = new Set<String>();
  for (var member in cls.members) {
    if (member is FieldDeclaration) {
      if (observeAll || hasObservable(member)) {
        transformClassFields(member, code, changedFields);
      }
    }
  }

  if (changedFields.length == 0) return;

  // Fix initializers, because they aren't allowed to call the setter.
  for (var member in cls.members) {
    if (member is ConstructorDeclaration) {
      fixConstructor(member, code, changedFields);
    }
  }
}

bool hasKeyword(Token token, Keyword keyword) =>
    token is KeywordToken && (token as KeywordToken).keyword == keyword;

String getOriginalCode(TextEditTransaction code, ASTNode node) =>
    code.original.substring(node.offset, node.end);

void transformTopLevelField(TopLevelVariableDeclaration field,
    TextEditTransaction code) {
  transformFields(field.variables, code, field.offset, field.end);
}

void transformClassFields(FieldDeclaration member, TextEditTransaction code,
    Set<String> changedFields) {

  transformFields(member.fields, code, member.offset, member.end,
      isStatic: hasKeyword(member.keyword, Keyword.STATIC),
      changedFields: changedFields);
}


void fixConstructor(ConstructorDeclaration ctor, TextEditTransaction code,
    Set<String> changedFields) {

  // Fix normal initializers
  for (var initializer in ctor.initializers) {
    if (initializer is ConstructorFieldInitializer) {
      var field = initializer.fieldName;
      if (changedFields.contains(field.name)) {
        code.edit(field.offset, field.end, '__\$${field.name}');
      }
    }
  }

  // Fix "this." initializer in parameter list. These are tricky:
  // we need to preserve the name and add an initializer.
  // Preserving the name is important for named args, and for dartdoc.
  // BEFORE: Foo(this.bar, this.baz) { ... }
  // AFTER:  Foo(bar, baz) : __$bar = bar, __$baz = baz { ... }

  var thisInit = [];
  for (var param in ctor.parameters.parameters) {
    if (param is FieldFormalParameter) {
      var name = param.identifier.name;
      if (changedFields.contains(name)) {
        thisInit.add(name);
        // Remove "this." but keep everything else.
        code.edit(param.thisToken.offset, param.period.end, '');
      }
    }
  }

  if (thisInit.length == 0) return;

  // TODO(jmesserly): smarter formatting with indent, etc.
  var inserted = thisInit.map((i) => '__\$$i = $i').join(', ');

  int offset;
  if (ctor.separator != null) {
    offset = ctor.separator.end;
    inserted = ' $inserted,';
  } else {
    offset = ctor.parameters.end;
    inserted = ' : $inserted';
  }

  code.edit(offset, offset, inserted);
}

void transformFields(VariableDeclarationList fields, TextEditTransaction code,
    int begin, int end, {bool isStatic: false, Set<String> changedFields}) {

  if (hasKeyword(fields.keyword, Keyword.CONST) ||
      hasKeyword(fields.keyword, Keyword.FINAL)) {
    return;
  }

  var indent = guessIndent(code.original, begin);
  var replace = new StringBuffer();

  // Unfortunately "var" doesn't work in all positions where type annotations
  // are allowed, such as "var get name". So we use "dynamic" instead.
  var type = 'dynamic';
  if (fields.type != null) {
    type = getOriginalCode(code, fields.type);
  }

  var mod = isStatic ? 'static ' : '';

  for (var field in fields.variables) {
    var initializer = '';
    if (field.initializer != null) {
      initializer = ' = ${getOriginalCode(code, field.initializer)}';
    }

    var name = field.name.name;

    if (replace.length > 0) replace.write('\n\n$indent');
    replace.write('''
${mod}$type __\$$name$initializer;
${mod}Object __obs\$$name;
${mod}$type get $name {
  if (autogenerated.observeReads) {
    __obs\$$name = autogenerated.notifyRead(__obs\$$name);
  }
  return __\$$name;
}
${mod}set $name($type value) {
  if (__obs\$$name != null && __\$$name != value) {
    __obs\$$name = autogenerated.notifyWrite(__obs\$$name);
  }
  __\$$name = value;
}'''.replaceAll('\n', '\n$indent'));

    if (changedFields != null) changedFields.add(name);
  }

  code.edit(begin, end, '$replace');
}
