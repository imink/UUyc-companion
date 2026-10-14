# RustDesk 审计 API 部署准备

**当前只提供配置，没有部署服务，也没有为伴侣实现 API 读取。** 不再推进通过 macOS 辅助功能窗口识别 RustDesk 设备的方案；现有 UU 路径和 RustDesk 本地 IPC 计数逻辑保持不变。

目标是在未来的 Linux 服务器上运行官方 `hbbs`（ID/会合）、`hbbr`（中继）和社区 `lejianwen/rustdesk-api`（管理与审计）。不修改 RustDesk 客户端源码，但部署完成后需要用户配置两端客户端的服务器地址与公钥，尤其是**被控 Mac 的 API Server**。只部署 API 并不会自动获取当前公共服务器上的历史或实时连接。

## 配置与网络边界

需要 Docker Engine、Compose v2、可访问的服务器地址、API 域名，以及宿主机上的 HTTPS 反向代理。本目录使用已确认存在的镜像标签 `rustdesk/rustdesk-server:1.1.16` 和 `lejianwen/rustdesk-api:v2.7`，不使用 `latest`；标签仍可能被上游替换，正式投产前应核对镜像并固定 digest。本配置未在容器环境运行验证。

| 服务 | 端口 | 默认访问范围 |
| --- | --- | --- |
| hbbs | TCP 21115、21116；UDP 21116 | `127.0.0.1`，需显式改成服务器可达地址 |
| hbbr | TCP 21117 | 同上 |
| API | TCP 21114 | 始终只绑定宿主 `127.0.0.1` |
| HTTPS 代理 | TCP 443；证书签发可能需要 TCP 80 | 后续单独配置，限制可信来源 |

不启用 Web Client，不开放 21118/21119，不自动放行防火墙、不挂载 Docker socket、不使用特权容器。`server-data` 保存服务端密钥和状态，`api-data` 保存 SQLite；API 容器不挂载服务端私钥卷。

**不能直接把 API 暴露到公网：** v2.7 的 `/api/audit/conn` 和 `/api/audit/file` 注册在 `RustAuth` 中间件之前，接收端没有客户端身份鉴权。HTTPS 只加密传输，不能防止允许访问该接口的人伪造事件。必须通过可信来源 IP 白名单或受控 VPN 限制入口，且不能把这些日志视为不可伪造的身份凭证。动态网络设备应先具备受控 VPN 等访问路径，不应为了接入手机将白名单改为所有地址。

`Caddyfile.example` 供**直接安装在宿主机**的 Caddy 参考，默认仅允许 loopback，其他来源返回 403。部署时替换域名，并将被控 Mac、需要访问 API 的控制端和管理员的可信出口 IP/VPN 网段加到 `@trusted`。不要将 Caddy 再置于其他代理后而仍假定 `remote_ip` 是真实客户端；多级代理需要单独设计可信代理边界。此文件不会由 Compose 自动加载。

## 后续部署步骤（本次未执行）

以下命令仅在准备好的 Linux 服务器、此目录内由管理员执行。

1. 复制环境样例，保护文件，填写真实域名、API HTTPS URL 和绑定地址。`.env` 已被 Git 忽略，不要提交令牌或实际连接数据。

   ```bash
   cp .env.example .env
   chmod 600 .env
   ```

2. 准备 DNS、宿主防火墙和可信来源限制。先验证配置，再只启动 ID/中继服务。此阶段保留公钥占位值即可，**不要启动 API**。

   ```bash
   docker compose config --quiet
   docker compose up -d hbbr hbbs
   docker compose cp hbbs:/root/id_ed25519.pub ./id_ed25519.pub
   cat id_ed25519.pub
   ```

   官方镜像基于 scratch，没有 shell 或 cat，因此使用 `compose cp` 导出公钥。若公钥尚未生成，检查 `docker compose logs hbbs`，不要自行生成替代值。将输出的**公钥**填入 `.env` 的 `RUSTDESK_PUBLIC_KEY`，不是同目录的私钥文件。保留服务端卷，后续重启不要重建密钥。

3. 完成 HTTPS 代理配置及来源限制后启动 API。确认 `.env` 中没有 `example.invalid` 或 `REPLACE_` 占位值。

   ```bash
   docker compose config --quiet
   docker compose up -d api
   docker compose ps
   docker compose logs --tail=100 api
   ```

   从受信任网络访问 `https://<API域名>/_admin/`，依据实际版本的初始化日志/提示完成管理员登录，并立即设置独有的强密码。初始化日志可能包含密码，不要将日志公开或提交到仓库。关闭公开注册与 Swagger 不等于关闭管理 API，仍需保护入口。

4. 在 Mac 和控制端 RustDesk 的网络设置中配置 ID Server、Relay Server、Key、API Server。API Server 填 `https://<API域名>`，不加 `/api`。客户端与自建服务器的 key 必须相同；先保存旧设置方便回退。不要在本次现有远控会话中无人值守地更换服务器配置。

5. 从控制端重新建立一条到 Mac 的桌面连接，在后台检查连接日志：目标 ID 是 Mac，来源 ID/名称是控制端；正常断开后应补齐结束时间。再进行下方验收，不应只凭后台可打开宣布接入完成。

升级前停止写入并备份 `api-data`、`server-data` 和代理配置，备份包含私钥/个人信息，必须限制访问。`docker compose down` 保留卷；不要使用 `down -v`。回退时恢复客户端旧服务器设置，伴侣现有 IPC 统一尺寸档仍独立于此 API。

## 已核对的读取契约

这些是社区 **v2.7** 的接口，不是 RustDesk Server Pro 的接口，不能混用 Pro 的令牌或 `audits.py`。

- 查询：`GET /api/admin/audit_conn/list?page=1&page_size=100&peer_id=<Mac-ID>`。
- 鉴权：请求头 **`api-token`**；需要通过该服务后台登录取得有效令牌，并具有管理员权限。该路由没有已核实的只读令牌能力，不要把全权限管理员令牌直接分发给所有伴侣客户端。后续正式集成需决定受限的服务端读取网关或可接受的凭据边界，本次不增加网关。
- 正常响应：`code == 0`，记录位于 `data.list`。部分失败返回 HTTP 200，但业务 `code != 0`；不能只检查 HTTP 状态。必须处理令牌失效、权限错误、超时和分页。
- `peer_id` 是被控端，`from_peer` / `from_name` 是控制端 ID / 名称；另外有 `conn_id`、`session_id`、`type`、`close_time`、`uuid`。服务端 `peer_id` 查询使用 `LIKE`，读取方还必须做**精确 ID 匹配**。
- `new` 事件先建记录，授权后的更新再填写来源与类型，`close` 事件更新 `close_time`。未授权记录也可能已有默认 `type = 0`，所以单凭 `type == 0` 或 `close_time == 0` 都不能认定已授权桌面连接。类型映射须与实际客户端版本和实测事件共同确认。
- `session_id` 在此版本先按 `float64` 解析再转字符串，大整数可能损失精度；不能把它当作绝对可靠的唯一关联键。需要综合被控设备、记录 ID、连接 ID、时间和生命周期判断，跨重启不复用旧身份。

## 不是完整的实时会话列表

客户端崩溃、网络中断、事件延迟/丢失可能导致开始或结束记录缺失。没有结束时间只能表示“尚未收到 close”，不能证明仍在线。服务端按被控 ID 和连接 ID 查找并更新历史记录，也不能假定连接 ID 跨进程重启唯一。

后续伴侣应继续用本机 IPC 检测桌面会话活动，API 仅提供身份关联候选；**计数恰好相等也不能证明身份一致**，尤其是连接数保持 1 但控制端已经换人的场景。关联不明确时显示未知、不沿用旧 peer 自动选择尺寸、不用旧审计记录维持物理屏关闭。不能将轮询成功或设备在线状态当作会话仍在线。

API 不报告 iPhone 的实际视口或屏幕分辨率。后续如实现按 `from_peer` 配置，仍需用户预填尺寸；名称和平台都不等于手机型号或屏幕尺寸。本次没有改动伴侣的设置、显示所有权或 watchdog，也没有宣称已完成 API 自动适配。

## 部署后必须验收

| 场景 | 核对内容 |
| --- | --- |
| 已授权桌面 | IPC 计数增加；日志补齐正确双方 ID、来源名称和类型 |
| 等待授权、拒绝 | 不因初始审计记录或默认类型误认已授权桌面 |
| 文件、终端、转发、摄像头 | 核对真实类型；不得触发桌面尺寸选择 |
| 正常断开 | IPC 归零、日志收到 close；记录两者延迟 |
| 崩溃、断网、服务重启 | 缺失/迟到 close 不得留下虚假的当前身份 |
| A 断开后 B 接入、计数始终为 1 | 不复用 A 的身份；验证事件关联能力 |
| 多连接、分页、ID 子串碰撞 | 精确过滤被控 ID，不漏记录、不误配设备 |
| API 403、业务错误、超时 | 明确报错，不把失败当作空列表或断开 |
| 非可信来源 | HTTPS 入口拒绝访问，21114 不可远程直连 |
| UU 与 RustDesk 同时活动 | 未来 API 集成仍需保留合并 owner/watchdog 回归 |

目前只核对公开源码、镜像标签及本地配置结构。未部署、未验证 TLS/容器启动/客户端上报，也未在当前 Mac 安装 Docker。

## 上游依据

- [API 项目与部署说明](https://github.com/lejianwen/rustdesk-api/tree/v2.7)
- [配置字段](https://github.com/lejianwen/rustdesk-api/blob/v2.7/conf/config.yaml)
- [查询路由及权限](https://github.com/lejianwen/rustdesk-api/blob/v2.7/http/router/admin.go)
- [api-token 鉴权](https://github.com/lejianwen/rustdesk-api/blob/v2.7/http/middleware/admin.go)
- [审计上报路由](https://github.com/lejianwen/rustdesk-api/blob/v2.7/http/router/api.go)
- [审计事件处理](https://github.com/lejianwen/rustdesk-api/blob/v2.7/http/controller/api/audit.go)
- [查询过滤](https://github.com/lejianwen/rustdesk-api/blob/v2.7/http/controller/admin/audit.go)
- [字段模型](https://github.com/lejianwen/rustdesk-api/blob/v2.7/model/audit.go)与[输入转换](https://github.com/lejianwen/rustdesk-api/blob/v2.7/http/request/api/audit.go)
- [官方 ID/中继服务器](https://github.com/rustdesk/rustdesk-server/tree/1.1.16)
