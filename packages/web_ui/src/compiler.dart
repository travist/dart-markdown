// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library compiler;

import 'dart:async';
import 'dart:collection' show SplayTreeMap;
import 'dart:json' as json;
import 'package:analyzer_experimental/src/generated/ast.dart' show Directive;
import 'package:csslib/parser.dart' as css;
import 'package:csslib/visitor.dart' show InfoVisitor, StyleSheet;
import 'package:html5lib/dom.dart';
import 'package:html5lib/parser.dart';

import 'analyzer.dart';
import 'code_printer.dart';
import 'codegen.dart' as codegen;
import 'dart_parser.dart';
import 'emitters.dart';
import 'file_system.dart';
import 'file_system/path.dart';
import 'files.dart';
import 'html_cleaner.dart';
import 'html_css_fixup.dart';
import 'info.dart';
import 'messages.dart';
import 'observable_transform.dart' show transformObservables;
import 'options.dart';
import 'refactor.dart';
import 'utils.dart';

/**
 * Parses an HTML file [contents] and returns a DOM-like tree.
 * Note that [contents] will be a [String] if coming from a browser-based
 * [FileSystem], or it will be a [List<int>] if running on the command line.
 *
 * Adds emitted error/warning to [messages], if [messages] is supplied.
 */
Document parseHtml(contents, Path sourcePath, Messages messages) {
  var parser = new HtmlParser(contents, generateSpans: true,
      sourceUrl: sourcePath.toString());
  var document = parser.parse();

  // Note: errors aren't fatal in HTML (unless strict mode is on).
  // So just print them as warnings.
  for (var e in parser.errors) {
    messages.warning(e.message, e.span, file: sourcePath);
  }
  return document;
}

/** Compiles an application written with Dart web components. */
class Compiler {
  final FileSystem fileSystem;
  final CompilerOptions options;
  final List<SourceFile> files = <SourceFile>[];
  final List<OutputFile> output = <OutputFile>[];

  Path _mainPath;
  PathInfo _pathInfo;
  Messages _messages;

  FutureGroup _tasks;
  Set _processed;

  bool _useObservers = false;

  /** Information about source [files] given their href. */
  final Map<Path, FileInfo> info = new SplayTreeMap<Path, FileInfo>();
  final _edits = new Map<LibraryInfo, TextEditTransaction>();

 /**
  * Creates a compiler with [options] using [fileSystem].
  *
  * Adds emitted error/warning messages to [messages], if [messages] is
  * supplied.
  */
  Compiler(this.fileSystem, this.options, this._messages, {String currentDir}) {
    _mainPath = new Path(options.inputFile);
    var mainDir = _mainPath.directoryPath;
    var basePath =
        options.baseDir != null ? new Path(options.baseDir) : mainDir;
    var outputPath =
        options.outputDir != null ? new Path(options.outputDir) : mainDir;

    // Normalize paths - all should be relative or absolute paths.
    bool anyAbsolute = _mainPath.isAbsolute || basePath.isAbsolute ||
        outputPath.isAbsolute;
    bool allAbsolute = _mainPath.isAbsolute && basePath.isAbsolute &&
        outputPath.isAbsolute;
    if (anyAbsolute && !allAbsolute) {
      if (currentDir == null)  {
        _messages.error('internal error: could not normalize paths. Please '
            'make the input, base, and output paths all absolute or relative, '
            'or specify "currentDir" to the Compiler constructor', null);
        return;
      }
      var currentPath = new Path(currentDir);
      if (!_mainPath.isAbsolute) _mainPath = currentPath.join(_mainPath);
      if (!basePath.isAbsolute) basePath = currentPath.join(basePath);
      if (!outputPath.isAbsolute) outputPath = currentPath.join(outputPath);
    }
    _pathInfo = new PathInfo(basePath, outputPath, options.forceMangle);
  }

  /** Compile the application starting from the given [mainFile]. */
  Future run() {
    if (_mainPath.filename.endsWith('.dart')) {
      _messages.error("Please provide an HTML file as your entry point.",
          null, file: _mainPath);
      return new Future.immediate(null);
    }
    return _parseAndDiscover(_mainPath).then((_) {
      _analyze();
      _transformDart();
      _emit();
    });
  }

  /**
   * Asynchronously parse [inputFile] and transitively discover web components
   * to load and parse. Returns a future that completes when all files are
   * processed.
   */
  Future _parseAndDiscover(Path inputFile) {
    _tasks = new FutureGroup();
    _processed = new Set();
    _processed.add(inputFile);
    _tasks.add(_parseHtmlFile(inputFile).then(_processHtmlFile));
    return _tasks.future;
  }

  bool _shouldProcessFile(SourceFile file) =>
      file != null && _pathInfo.checkInputPath(file.path, _messages);

  void _processHtmlFile(SourceFile file) {
    if (!_shouldProcessFile(file)) return;

    bool isEntryPoint = _processed.length == 1;

    files.add(file);

    var fileInfo = _time('Analyzed definitions', file.path,
        () => analyzeDefinitions(file, _messages, isEntryPoint: isEntryPoint));
    info[file.path] = fileInfo;

    _processImports(fileInfo);

    // Load component files referenced by [file].
    for (var href in fileInfo.componentLinks) {
      if (!_processed.contains(href)) {
        _processed.add(href);
        _tasks.add(_parseHtmlFile(href).then(_processHtmlFile));
      }
    }

    // Load .dart files being referenced in the page.
    var src = fileInfo.externalFile;
    if (src != null && !_processed.contains(src)) {
      _processed.add(src);
      _tasks.add(_parseDartFile(src).then(_processDartFile));
    }

    // Load .dart files being referenced in components.
    for (var component in fileInfo.declaredComponents) {
      var src = component.externalFile;
      if (src != null && !_processed.contains(src)) {
        _processed.add(src);
        _tasks.add(_parseDartFile(src).then(_processDartFile));
      } else if (component.userCode != null) {
        _processImports(component);
      }
    }
  }

  /** Asynchronously parse [path] as an .html file. */
  Future<SourceFile> _parseHtmlFile(Path path) {
    return fileSystem.readTextOrBytes(path).then((source) {
          var file = new SourceFile(path);
          file.document = _time('Parsed', path,
              () => parseHtml(source, path, _messages));
          return file;
        })
        .catchError((e) => _readError(e, path));
  }

  /** Parse [filename] and treat it as a .dart file. */
  Future<SourceFile> _parseDartFile(Path path) {
    return fileSystem.readText(path)
        .then((code) => new SourceFile(path, isDart: true)..code = code)
        .catchError((e) => _readError(e, path));
  }

  SourceFile _readError(error, Path path) {
    _messages.error('exception while reading file, original message:\n $error',
        null, file: path);

    return null;
  }

  void _processDartFile(SourceFile dartFile) {
    if (!_shouldProcessFile(dartFile)) return;

    files.add(dartFile);

    var fileInfo = new FileInfo(dartFile.path);
    info[dartFile.path] = fileInfo;
    fileInfo.inlinedCode =
        parseDartCode(fileInfo.path, dartFile.code, _messages);

    _processImports(fileInfo);
  }

  void _processImports(LibraryInfo library) {
    if (library.userCode == null) return;

    for (var directive in library.userCode.directives) {
      var src = _getDirectivePath(library, directive);
      if (src == null) {
        var uri = directive.uri.value;
        if (uri.startsWith('package:web_ui/observe')) {
          _useObservers = true;
        }
      } else if (!_processed.contains(src)) {
        _processed.add(src);
        _tasks.add(_parseDartFile(src).then(_processDartFile));
      }
    }
  }

  Path _getDirectivePath(LibraryInfo libInfo, Directive directive) {
    var uri = directive.uri.value;
    if (uri.startsWith('dart:')) return null;

    if (uri.startsWith('package:')) {
      // Don't process our own package -- we'll implement @observable manually.
      if (uri.startsWith('package:web_ui/')) return null;

      return _mainPath.directoryPath.join(new Path('packages'))
          .join(new Path(uri.substring(8)));
    } else {
      return libInfo.inputPath.directoryPath.join(new Path(uri));
    }
  }

  /**
   * Transform Dart source code.
   * Currently, the only transformation is [transformObservables].
   * Calls _emitModifiedDartFiles to write the transformed files.
   */
  void _transformDart() {
    var libraries = _findAllDartLibraries();

    var transformed = [];
    for (var library in libraries) {
      var transaction = transformObservables(library.userCode);
      if (transaction != null) {
        _edits[library] = transaction;
        if (transaction.hasEdits) {
          // TODO(jmesserly): what about ObservableList/Map/Set?
          _useObservers = true;
          transformed.add(library);
        }
      }
    }

    _findModifiedDartFiles(libraries, transformed);

    libraries.forEach(_fixImports);

    _emitModifiedDartFiles(libraries);
  }

  /**
   * Finds all Dart code libraries.
   * Each library will have [LibraryInfo.inlinedCode] that is non-null.
   * Also each inlinedCode will be unique.
   */
  List<LibraryInfo> _findAllDartLibraries() {
    var libs = <LibraryInfo>[];
    void _addLibrary(LibraryInfo lib) {
      if (lib.inlinedCode != null) libs.add(lib);
    }

    for (var sourceFile in files) {
      var file = info[sourceFile.path];
      _addLibrary(file);
      file.declaredComponents.forEach(_addLibrary);
    }

    // Assert that each file path is unique.
    assert(_uniquePaths(libs));
    return libs;
  }

  bool _uniquePaths(List<LibraryInfo> libs) {
    var seen = new Set();
    for (var lib in libs) {
      if (seen.contains(lib.inlinedCode)) {
        throw new StateError('internal error: '
            'duplicate user code for ${lib.inputPath}. Files were: $files');
      }
      seen.add(lib.inlinedCode);
    }
    return true;
  }

  /**
   * Queue modified Dart files to be written.
   * This will not write files that are handled by [WebComponentEmitter] and
   * [MainPageEmitter].
   */
  void _emitModifiedDartFiles(List<LibraryInfo> libraries) {
    for (var lib in libraries) {
      // Components will get emitted by WebComponentEmitter, and the
      // entry point will get emitted by MainPageEmitter.
      // So we only need to worry about other .dart files.
      if (lib.modified && lib is FileInfo &&
          lib.htmlFile == null && !lib.isEntryPoint) {
        var transaction = _edits[lib];

        // Save imports that were modified by _fixImports.
        for (var d in lib.userCode.directives) {
          transaction.edit(d.offset, d.end, d.toString());
        }

        var pos = lib.userCode.directivesEnd;
        // TODO(sigmund): maybe don't generate this new import? the user already
        // had to import @observable, so we could take advantage of that to add
        // also notifyRead/notifyWrite.
        transaction.edit(pos, pos,
            "\nimport 'package:web_ui/observe.dart' as autogenerated;");
        _emitFileAndSourceMaps(lib, transaction.commit(), lib.inputPath);
      }
    }
  }

  /**
   * This method computes which Dart files have been modified, starting
   * from [transformed] and marking recursively through all files that import
   * the modified files.
   */
  void _findModifiedDartFiles(List<LibraryInfo> libraries,
      List<FileInfo> transformed) {

    if (transformed.length == 0) return;

    // Compute files that reference each file, then use this information to
    // flip the modified bit transitively. This is a lot simpler than trying
    // to compute it the other way because of circular references.
    for (var library in libraries) {
      for (var directive in library.userCode.directives) {
        var importPath = _getDirectivePath(library, directive);
        if (importPath == null) continue;

        var importInfo = info[importPath];
        if (importInfo != null) {
          importInfo.referencedBy.add(library);
        }
      }
    }

    // Propegate the modified bit to anything that references a modified file.
    void setModified(LibraryInfo library) {
      if (library.modified) return;
      library.modified = true;
      library.referencedBy.forEach(setModified);
    }
    transformed.forEach(setModified);

    for (var library in libraries) {
      // We don't need this anymore, so free it.
      library.referencedBy = null;
    }
  }

  void _fixImports(LibraryInfo library) {
    var fileOutputPath = _pathInfo.outputLibraryPath(library);

    // Fix imports. Modified files must use the generated path, otherwise
    // we need to make the path relative to the input.
    for (var directive in library.userCode.directives) {
      var importPath = _getDirectivePath(library, directive);
      if (importPath == null) continue;
      var importInfo = info[importPath];
      if (importInfo == null) continue;

      String newUri;
      if (importInfo.modified) {
        // Use the generated URI for this file.
        newUri = _pathInfo.relativePath(library, importInfo).toString();
      } else {
        // Get the relative path to the input file.
        newUri = _pathInfo.transformUrl(library.inputPath, directive.uri.value);
      }
      directive.uri = createStringLiteral(newUri);
    }
  }

  /** Run the analyzer on every input html file. */
  void _analyze() {
    var uniqueIds = new IntIterator();
    for (var file in files) {
      if (file.isDart) continue;
      _time('Analyzed contents', file.path, () =>
          analyzeFile(file, info, uniqueIds, _messages));
    }
  }

  /** Emit the generated code corresponding to each input file. */
  void _emit() {
    for (var file in files) {
      if (file.isDart) continue;
      _time('Codegen', file.path, () {
        var fileInfo = info[file.path];
        cleanHtmlNodes(fileInfo);
        _processStylesheet(fileInfo, options: options);
        fixupHtmlCss(fileInfo, options);
        _emitComponents(fileInfo);
        if (fileInfo.isEntryPoint) {
          _emitMainDart(file);
          _emitMainHtml(file);
        }
      });
    }
  }

  /** Emit the main .dart file. */
  void _emitMainDart(SourceFile file) {
    var fileInfo = info[file.path];
    var printer = new MainPageEmitter(fileInfo)
        .run(file.document, _pathInfo, _edits[fileInfo]);
    _emitFileAndSourceMaps(fileInfo, printer, fileInfo.inputPath);
  }

  /** Generate an html file with the (trimmed down) main html page. */
  void _emitMainHtml(SourceFile file) {
    var fileInfo = info[file.path];

    var bootstrapName = '${file.path.filename}_bootstrap.dart';
    var bootstrapPath = file.path.directoryPath.append(bootstrapName);
    var bootstrapOutPath = _pathInfo.outputPath(bootstrapPath, '');
    output.add(new OutputFile(bootstrapOutPath, codegen.bootstrapCode(
          _pathInfo.relativePath(new FileInfo(bootstrapPath), fileInfo),
          _useObservers)));

    var document = file.document;
    bool dartLoaderFound = false;
    for (var script in document.queryAll('script')) {
      var src = script.attributes['src'];
      if (src != null && src.split('/').last == 'dart.js') {
        dartLoaderFound = true;
        break;
      }
    }

    // http://dvcs.w3.org/hg/webcomponents/raw-file/tip/spec/templates/index.html#css-additions
    document.head.nodes.insertAt(0, parseFragment(
        '<style>template { display: none; }</style>'));

    if (!dartLoaderFound) {
      document.body.nodes.add(parseFragment(
          '<script type="text/javascript" src="packages/browser/dart.js">'
          '</script>\n'));
    }
    document.body.nodes.add(parseFragment(
      '<script type="application/dart" src="${bootstrapOutPath.filename}">'
      '</script>'
    ));

    for (var link in document.head.queryAll('link')) {
      if (link.attributes["rel"] == "components") {
        link.remove();
      }
    }

    _addAutoGeneratedComment(file);
    output.add(new OutputFile(_pathInfo.outputPath(file.path, '.html'),
        document.outerHtml, source: file.path));
  }

  /** Emits the Dart code for all components in [fileInfo]. */
  void _emitComponents(FileInfo fileInfo) {
    for (var component in fileInfo.declaredComponents) {
      var printer = new WebComponentEmitter(fileInfo, _messages)
          .run(component, _pathInfo, _edits[component]);
      _emitFileAndSourceMaps(component, printer, component.externalFile);
    }
  }

  /**
   * Emits a file that was created using [CodePrinter] and it's corresponding
   * source map file.
   */
  void _emitFileAndSourceMaps(
      LibraryInfo lib, CodePrinter printer, Path inputPath) {
    var path = _pathInfo.outputLibraryPath(lib);
    var dir = path.directoryPath;
    printer.add('\n//@ sourceMappingURL=${path.filename}.map');
    printer.build(path.toString());
    output.add(new OutputFile(path, printer.text, source: inputPath));
    // Fix-up the paths in the source map file
    var sourceMap = json.parse(printer.map);
    var urls = sourceMap['sources'];
    for (int i = 0; i < urls.length; i++) {
      urls[i] = new Path(urls[i]).relativeTo(dir).toString();
    }
    output.add(new OutputFile(dir.append('${path.filename}.map'),
          json.stringify(sourceMap)));
  }

  _time(String logMessage, Path path, callback(), {bool printTime: false}) {
    var message = new StringBuffer();
    message.write(logMessage);
    for (int i = (60 - logMessage.length - path.filename.length); i > 0 ; i--) {
      message.write(' ');
    }
    message.write(path.filename);
    return time(message.toString(), callback,
        printTime: options.verbose || printTime);
  }

  void _addAutoGeneratedComment(SourceFile file) {
    var document = file.document;

    // Insert the "auto-generated" comment after the doctype, otherwise IE will
    // go into quirks mode.
    int commentIndex = 0;
    DocumentType doctype = find(document.nodes, (n) => n is DocumentType);
    if (doctype != null) {
      commentIndex = document.nodes.indexOf(doctype) + 1;
      // TODO(jmesserly): the html5lib parser emits a warning for missing
      // doctype, but it allows you to put it after comments. Presumably they do
      // this because some comments won't force IE into quirks mode (sigh). See
      // this link for more info:
      //     http://bugzilla.validator.nu/show_bug.cgi?id=836
      // For simplicity we emit the warning always, like validator.nu does.
      if (doctype.tagName != 'html' || commentIndex != 1) {
        _messages.warning('file should start with <!DOCTYPE html> '
            'to avoid the possibility of it being parsed in quirks mode in IE. '
            'See http://www.w3.org/TR/html5-diff/#doctype',
            doctype.sourceSpan, file: file.path);
      }
    }
    document.nodes.insertAt(commentIndex, parseFragment(
        '\n<!-- This file was auto-generated from ${file.path}. -->\n'));
  }
}

/** Parse all stylesheet for polyfilling assciated with [info]. */
void _processStylesheet(info, {CompilerOptions options : null}) {
  new _ProcessCss(options).visit(info);
}

/** Post-analysis of style sheet; parsed ready for emitting with polyfill. */
class _ProcessCss extends InfoVisitor {
  final CompilerOptions options;

  _ProcessCss(this.options);

  // TODO(terry): Add --checked when fully implemented and error handling too.
  StyleSheet _parseCss(String cssInput, CompilerOptions option) =>
      css.parse(cssInput, options:
        [option.warningsAsErrors ? '--warnings_as_errors' : '', 'memory']);

  void visitComponentInfo(ComponentInfo info) {
    if (!info.cssSource.isEmpty) {
      info.styleSheet = _parseCss(info.cssSource.toString(), options);
      info.cssSource = null;    // Once CSS parsed original not needed.
    }

    super.visitComponentInfo(info);
  }
}
