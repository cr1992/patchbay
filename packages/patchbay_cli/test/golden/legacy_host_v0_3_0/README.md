# 冻结语料：v0.3.0 host

<!-- patchbay:frozen-corpus -->

这两个文件是 **0.3.0 定版时由真实 host 生成、随后冻结**的协议面，与 `legacy_host_v0_2_0/` 的手写
语料来源不同，但同样**不可再生成**：0.3.0 已经发布并被接入方 pin 住，它的 identity 与 catalog 是
历史事实，不是当前实现的投影。

上面那行标记是 `release_prep` 的机读判据。没有它时，`release_prep --version 0.3.0 --check` 会拿
今天的 `host_surface.json` 重新渲染这两个文件并报漂移，`--apply` 会直接覆写——那等于把「0.4.0 的
CLI 还能不能读 0.3.0 的 host」这道闸改成「CLI 能不能读它自己」，闸恒绿且毫无意义。

冻结时的来源可核对：`8ce6f55`（PB-040-18）落地本目录，当时的
`packages/patchbay/test/golden/host_surface.json` 与 `patchbay-v0.3.0` tag 上的同一文件逐字节一致。

| 文件 | 相对今天的差别 |
|---|---|
| `identity.json` | 缺 0.4.0 新增的 feature capabilities：`snapshotRevisionDiff`、`snapshotSelectors` |
| `catalog.json` | 目前与今天逐字节相同——surface golden 的示例 catalog 只有 `domain.ping`。相同不等于可再生成：目录形状此后任何一次变化都会连它一起改写 |

消费它们的用例在 [`../../protocol_compat_test.dart`](../../protocol_compat_test.dart) 的「版本化兼容
语料可被当前 CLI 读取」一组——该组按目录名自动发现语料，新增历史版本时不必改测试代码。

新增下一版语料时新建目录（如 `legacy_host_v0_4_0/`），并在该版发布后立刻补上本标记；不要改这一份。
