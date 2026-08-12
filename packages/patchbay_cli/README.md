# Patchbay CLI（试点）

当前 executable 已跑通 VM Service `identity`、动态 `catalog`、领域 `snapshot`、
`exec`/`job` 与 Flutter 文本操作纵切。
试点阶段显式传 VM Service URI：

```text
dart run bin/patchbay.dart --ws-uri <uri> --json identity
dart run bin/patchbay.dart --ws-uri <uri> --json catalog
dart run bin/patchbay.dart --ws-uri <uri> --json snapshot
dart run bin/patchbay.dart --ws-uri <uri> --json exec device.list
dart run bin/patchbay.dart --ws-uri <uri> --json --args '{"level": 20}' exec command.volume
dart run bin/patchbay.dart --ws-uri <uri> --json --wait exec session.connect
dart run bin/patchbay.dart --ws-uri <uri> --json ui text enter <target-id> <generation> <text>
```

敏感参数对象只走 `--stdin`，普通输出和错误不打印 VM Service URI。会话文件发现、
launcher machine protocol 与 stale session 清理仍按
`docs/decisions/patchbay-design.md` 的 v0.1 后续批次实现；本试点不把显式
`--ws-uri` 宣称成最终会话模型。
