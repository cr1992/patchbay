# 冻结语料：v0.2.0 host

这些文件是**手写冻结的历史 wire**，不是可再生成的 golden——它们描述的那个 host 已经不在本仓
任何一行代码里了，只在某个接入方已发布的 App 里跑着（0.2.0 是当前仍有 consumer pin 的 tag，
见 [兼容矩阵](../../../../../docs/compat-matrix.md)）。

所以：**任何情况下都不要用当前实现「重新生成」这三个文件**。用当前 host 覆写它们，等于把
「新 CLI 还能不能对付老 host」这道闸改成「新 CLI 能不能对付它自己」，那道闸恒绿且毫无意义。

三份语料各自缺什么，正是 0.2.0 那一版真的没有的东西：

| 文件 | 相对今天缺的 |
|---|---|
| `identity.json` | `serverVersion`、`features` |
| `catalog.json` | `catalogDigest` |
| `lifecycle_rejection.json` | `rejection.details.lifecycleState`（0.2.1 才补，见 CHANGELOG） |

消费它们的用例在 [`../../protocol_compat_test.dart`](../../protocol_compat_test.dart)。
真的要新增一份历史语料时，新建目录（如 `legacy_host_v0_3_0/`），不要改这一份。
