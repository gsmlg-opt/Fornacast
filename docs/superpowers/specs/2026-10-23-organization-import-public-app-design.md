# 组织导入：公开 API 与 GitHub App 两种入口

状态：用户已批准推荐方案，2026-10-23。实施和验收记录见对应实施计划。

本次入口改造承接已批准的
`2026-10-22-organization-github-app-connection-design.md`，保留该组织连接实现、
现有任务及其凭证来源。这里新增公开访问，并替换旧的组织导入表单。

## 已确认的问题

在 `http://10.100.10.28:4890/organizations/import` 的真实浏览器中：

- 页面仍要求选择 Saved GitHub account 或输入一次性 PAT。
- 凭证的两组输入、本地目标组织的两组输入一直可编辑，都会进入 FormData。
- `ImportController.credential_params/1` 要求未使用的凭证字段为空；
  `new_destination/3`、`existing_destination/2` 对目标组织字段有同样要求。
  切换选项后保留另一组值，会触发通用错误。现有控制器测试明确覆盖这种拒绝。
- 页面资源成功加载，检查时无浏览器控制台错误，也无横向溢出。

公开访问尚未实现：ImportRun 没有公开来源，GitHub Client 始终要求 token，
GitCore 的远程操作也要求凭证。只改入口无法完成匿名导入。

本次匿名请求 GitHub 的公开组织仓库列表返回 HTTP 200，响应限额为每小时
60 次。该限额按 GitHub 响应处理，不能用作可完成大型组织导入的保证。

## 方案选择

推荐：**公开 API + 复用组织级 GitHub App 连接**。

页面只展示两项操作，均不提供个人账号选择器或 token 输入框：

1. **同步公开仓库**：输入 GitHub 组织，选择或创建本地目标组织，匿名发现仓库。
2. **安装并连接 GitHub App**：选择或创建本地组织，进入已有组织级 App 连接，
   按需完成 GitHub 授权及安装，验证组织安装后发现可访问仓库。

App 入口复用已批准的组织级 Device Flow、安装验证与 `organization_device`
执行来源。它使用组织保存的 App user grant，访问仍受 GitHub 授权用户、
App 权限和安装仓库范围约束。产品不要求手动选择或提供个人凭证。
已有可用组织连接直接复用；连接成功后不自动开始同步，保留明确的开始操作。

另一可选方案是**公开 API + 真正的 installation token**。后台可复用现有
InstallationTokenBroker，但当前实例的高级 App 页面报告该模式未配置。
该方案还需服务端 App 私钥、安装归属证明及回调/webhook 接续，修改范围更大。
如果要求后台同步完全独立于 GitHub 用户 grant，应选择此方案，另行细化接入；
不得把现有 Device Flow token 描述成 installation token。

## 页面和交互

- `/organizations/import` 成为两个入口的选择页。
- 各入口使用独立页面/请求，服务端渲染有效表单；禁用 JavaScript 时仍可使用。
- 公开模式只提交 GitHub 组织及一个本地目标，不提交凭证字段。
- 新建和已有目标各自提交明确的数据结构；未选分支不需要发送空占位字段。
  后端继续拒绝矛盾参数，并提供具体字段错误，保留安全的非敏感输入。
- App 模式先确定本地组织，再进入其组织连接流程；安装所属 GitHub 组织
  由验证结果确定，不接受浏览器提交的任意 installation ID 作为绑定证据。
- 安装缺失、授权缺失、权限不足、连接可用分别展示下一步操作。
  仅在唯一合格安装可被安全确定时自动选择，否则由用户选择组织安装。
- 发现结果展示完整仓库列表，默认全选，允许用户调整，再进入现有审核/开始流程。
- 首次导入及后续手动同步复用已有任务、进度、取消、重试和报告。
  定时行为沿用现有配置机制与默认值，不因访问页面而启用。

## 公开来源的后端边界

1. 增加明确的 `public` 来源及 PostgreSQL 约束。该来源不拥有个人 identity、
   token 或加密凭证，不制造空 token、伪造账号或复用其他来源的秘密。
2. ForgeGitHub 提供明确的匿名请求分支，省略 Authorization，继续校验固定域名、
   分页、数据结构、超时、响应大小及请求限流。匿名请求单独使用共享限流桶。
3. GitCore 增加显式匿名 Git 拉取能力，保留远程地址和操作校验，禁止读取
   操作环境中的隐式个人凭证。认证操作仍要求其原有有效凭证。
4. 发现和执行只接受公开仓库，记录不可变组织/仓库 ID；执行及发布前重新核验
   来源和公开状态。分页未完成不能报告完整组织清单。
5. 限额耗尽时展示可恢复的等待状态和下次尝试时间，使用已有队列/恢复机制；
   不静默换用已保存账号，不把未完成清单当成最终结果。
6. 保持当前任务所需的 Git、元数据及 LFS 完整性要求。公开仓库所需资源若仍
   要求授权，明确失败并引导用户选择 App；不跳过必需内容后报告成功。
7. ForgeMirrors 拥有后续同步配置，ForgeImports 负责一次性导入任务。
   扩展已有配置/任务的来源分派、版本和执行授权，不另建同步调度器。
   公开任务依赖当前组织配置、目标权限、版本及租约，不依赖个人凭证。

## 保持的约束

- 本地用户登录及组织管理权限仍然必需；不扩大目标组织访问权限。
- 保持当前从 GitHub 拉入的内容范围，不启用新的 GitHub 回写功能。
- 保留个人 PAT、组织 Device Flow 和高级 installation-token 配置、历史任务。
  已记录任务保持原来源；切换来源沿用现有 busy 拒绝和版本隔离。
- 不重置租约，不取消或重放现有同步，不启动竞争写入者。
- 保留当前 force-push、ref 删除、私有仓库隐藏及发布完整性限制。
- 保留工作区已有未提交修改；本次不包含提交、发布或服务重启。

## 验收

- 两个入口均无个人账号选择器和 token 输入；目标切换无残留字段冲突。
  验证服务端表单、错误保留，以及禁用 JavaScript 的完整路径。
- 公开请求的 REST/Git/LFS 路径不发送或借用个人凭证；私有仓库、可见性变化、
  限额、错误分页及不完整资源不能产生虚假成功。
- 使用真实本地公开 Git 测试仓库验证匿名拉取、发布及后续 fast-forward；
  PostgreSQL 覆盖来源约束、恢复、权限和来源切换。
- App 路径复用组织连接测试，覆盖未授权、未安装、权限不足、安装范围和就绪态。
  不影响旧任务和其他本地组织的连接。
- 运行改动范围内的 PostgreSQL 测试、格式检查及必要的编译/资产构建。
  对准确 LAN 地址验证实际 DOM、请求、控制台及桌面/移动端表单。
- 区分匿名公开 API 请求成功、完整公开导入成功、真实 App 授权/安装验证和
  完整 App 同步成功。当前已完成本地实现、范围内测试和隔离浏览器验收；
  GitHub 测试客户端与真实本地 Git 的证据不代表真实 GitHub 完整导入或 App 授权。

实施结果：相关测试共 465 项通过；范围内格式检查、完整重新编译的
warnings-as-errors 检查和资产构建通过。真实 Chrome 覆盖桌面入口、移动端
390px、禁用 JavaScript 的公开发现与 App 入口提交、目标切换和公开同步暂停/恢复。
准确 LAN 地址检查时仍运行旧表单；本次未重启、部署或发起真实用户同步。
各项证据及限制见对应实施计划。工程说明保存为 Agent Note
`0812f701-015b-45d4-bad9-4730d789ae72`，标签 `project=fornacast`。

## 主要代码位置

- `apps/fornacast_web/lib/fornacast_web/controllers/import_controller.ex`
- `apps/fornacast_web/lib/fornacast_web/controllers/import_html/organization.html.heex`
- `apps/forge_imports/lib/forge_imports/{discovery,discovery_worker,import_run,credential_provider}.ex`
- `apps/forge_imports/lib/forge_imports/organization_github_connection.ex`
- `apps/forge_mirrors/lib/forge_mirrors/{pat_configuration,installation_intents}.ex`
- `apps/forge_github/lib/forge_github/client.ex`
- `apps/git_core/lib/git_core/remote.ex` 与对应本地 Rust NIF 请求类型
- `apps/fornacast/priv/repo/migrations/` 中的来源约束

对应的控制器/HTML、discovery、credential provider、repository worker、
迁移持久化、GitHub client 和 GitCore remote 测试为本次验证边界。
