Quill markdown library
========================

This is a standalone version of the [Quill][Quill] markdown library. It 
parses markdown and converts it to HTML.


Installation
------------

Add this to your `pubspec.yaml` (or create it):
```yaml
dependencies:
  markdown: any
```
Then run the [Pub Package Manager][pub] (comes with the Dart SDK):

    pub install

Usage
-----

```dart
import 'package:markdown/markdown.dart' show markdownToHtml;

main() {
  print(markdownToHtml('Hello *Markdown*'));
}
```

Version 0.4 adds support for GitHub style triple backtick code blocks, with 
built in Dart syntax coloring. Custom classifiers can be added using a syntax list:

```dart
import 'package:markdown/markdown.dart';

main() {
  List<InlineSyntax> nyanSyntax =
      [new TextSyntax('nyan', sub: '~=[,,_,,]:3')];
  print(markdownToHtml('nyan', inlineSyntaxes: nyanSyntax));
}
```

[Quill]: http://code.google.com/p/dart/source/browse/trunk/dart/sdk/lib/_internal/dartdoc
