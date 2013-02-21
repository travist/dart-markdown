# Heading 1

## Heading 2

### Heading 3

Lorem ipsum dolor sit amet, consectetur adipiscing elit. In porta vestibulum 
lorem, ac fringilla dui venenatis sit amet. Class aptent taciti sociosqu ad 
litora torquent per conubia nostra, per inceptos himenaeos. Sed justo ligula, 
sagittis id semper ac, viverra varius leo. Vivamus gravida mi id elit commodo 
non luctus dui tempor. In pulvinar viverra dolor, blandit molestie augue 
lobortis in. Suspendisse ac venenatis magna. Donec vitae turpis et ante euismod 
porttitor at ut erat. Nunc euismod, nulla et viverra malesuada, eros metus.

**Dart Classifier**

```dart
class Classification {
  static const NONE = "";
  static const ERROR = "e";
  static const COMMENT = "c";
  static const IDENTIFIER = "i";
  static const KEYWORD = "k";
  static const OPERATOR = "o";
  static const STRING = "s";
  static const NUMBER = "n";
  static const PUNCTUATION = "p";
  static const TYPE_IDENTIFIER = "t";
  static const SPECIAL_IDENTIFIER = "r";
  static const ARROW_OPERATOR = "a";
  static const STRING_INTERPOLATION = 'si';
}
```

**HTML Classifier**

```html
<html><body>
  <div>Hello counter: {{count}}</div>
  <script type="application/dart">
    import 'dart:html';
    import 'package:web_ui/watcher.dart' as watchers;
    int count;
    main() {
      count = 0;
      window.setInterval(() {
        count++;
        watchers.dispatch();
      }, 1000);
    }
  </script>
</body></html>
```
