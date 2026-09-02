// markdown 仓内相对链接检测与绝对化改写。

import 'constants.dart';

final RegExp _inlineLinkPattern = RegExp(
  r'\]\(([^)\s]+)((?:[ \t]+"[^"]*")?)\)',
);
final RegExp _refDefPattern = RegExp(r'^(\[[^\]]+\]:[ \t]*)(\S+)');
final RegExp _htmlHrefPattern = RegExp(r'(href=")([^"]+)(")');
final RegExp _fencePattern = RegExp(r'^[ \t]*(```|~~~)');

/// 是否是「指向仓内的相对路径」。
bool isRelativeRepoLink(String target) {
  if (target.isEmpty) return false;
  if (target.startsWith('#') || target.startsWith('//')) return false;
  return !RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:').hasMatch(target);
}

/// 逐行遍历 markdown 的链接目标，用 [map] 的返回值替换。围栏代码块内不动。
String _mapRepoLinks(String markdown, String Function(String target) map) {
  final List<String> lines = markdown.split('\n');
  var inFence = false;
  for (var index = 0; index < lines.length; index += 1) {
    final String line = lines[index];
    if (_fencePattern.hasMatch(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    var rewritten = line.replaceAllMapped(
      _inlineLinkPattern,
      (match) => '](${map(match.group(1)!)}${match.group(2)})',
    );
    rewritten = rewritten.replaceFirstMapped(
      _refDefPattern,
      (match) => '${match.group(1)}${map(match.group(2)!)}',
    );
    rewritten = rewritten.replaceAllMapped(
      _htmlHrefPattern,
      (match) => '${match.group(1)}${map(match.group(2)!)}${match.group(3)}',
    );
    lines[index] = rewritten;
  }
  return lines.join('\n');
}

/// markdown 里全部指向仓内的相对链接（按出现顺序，含重复）。
List<String> relativeRepoLinks(String markdown) {
  final found = <String>[];
  _mapRepoLinks(markdown, (target) {
    if (isRelativeRepoLink(target)) found.add(target);
    return target;
  });
  return found;
}

/// 把 **仓根视角** 的相对链接改写成绝对 GitHub 地址；锚点跟着路径一起带过去。
String absolutizeRepoLinks(String markdown, {String prefix = repoBlobPrefix}) =>
    _mapRepoLinks(
      markdown,
      (target) => isRelativeRepoLink(target) ? '$prefix$target' : target,
    );
