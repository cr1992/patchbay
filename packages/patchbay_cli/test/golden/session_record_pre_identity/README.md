# 冻结语料：无进程启动身份的会话记录

<!-- patchbay:frozen-corpus -->

本目录冻结的是 PB-050-18（会话存活加进程启动身份）之前，任何 CLI / App 写下的会话记录长
什么样：带 `ownerPid` / `launchId` / `observedAtMs` / `expiresAtMs`，但没有 `processStartTime`。

会话记录的 `schemaVersion` 永远保持 `1`（见 `docs/design.md`「本地会话文件是第三个兼容
面」），新字段一律松读追加，所以这份语料不会因为版本号推进而失效——它验证的正是「读到一条
没有这个字段的老记录，行为必须和升级前完全一样」：进程存活判定继续只看 PID，只在诊断输出
（`identityUnverified`）里多一句「没法核实」，绝不会把一条其实还活着的会话判死。

`record.json` 是手写冻结，不得用当前实现重新生成：重新生成等于把「新 CLI 能不能读老记录」
偷换成「新 CLI 能不能读自己写的东西」，这道闸就废了。
