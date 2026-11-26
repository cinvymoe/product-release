# 产品发布仓 (product-release)

`rust_crane` 的 **git submodule**，对外发布产品用。只包含出厂交付所需的六类内容：

| # | 内容 | 位置 | 是否入 git |
|---|---|---|---|
| 1 | 平台烧录文件 (arm32 + arm64) | `flash/rk3506/` `flash/rk3568-s962/` | 清单入 git，`update.img`/`*.bin`/`image/` 走制品通道 |
| 2 | 烧录工具 (Linux + Windows) | `tools/linux/` `tools/windows/` | ✅ 入 git |
| 3 | 产品文件 | `products/<product>-<arch>/` | 清单/配置入 git，运行时走制品通道 |
| 4 | 产品自定义文件 (公司 / APN / MQTT) | `custom/` | ✅ 模板入 git |
| 5 | Windows 烧录支持 | `deploy/factory-deploy.ps1` | ✅ 入 git |
| 6 | 只支持 factory 部署 | `deploy/factory-deploy.sh` / `.ps1` | ✅ 入 git |

## 交付流程（交付端只做三步）

```bash
git clone <本仓地址> product-release && cd product-release
./deploy/lib/sync.sh                       # 从内网 NAS 拉大文件并校验 sha256
sudo ./deploy/factory-deploy.sh --product loader     # Linux
```

Windows (PowerShell, **管理员**):

```powershell
.\deploy\factory-deploy.ps1 -Product loader
```

## 目录

```
product-release/
├── flash/                       ① 平台烧录文件（板型目录，镜像走 artifacts/）
│   ├── rk3506/{manifest.toml,parameter.txt,md5sum.txt}      arm32
│   └── rk3568-s962/manifest.toml                            arm64
├── tools/                       ② 烧录工具
│   ├── linux/{upgrade_tool,rkdeveloptool}
│   └── windows/{upgrade_tool_v2.46.zip,RKDevTool-*.zip,DriverAssitant_v5.13.zip}
├── products/<product>-<arch>/   ③ 产品文件（清单入 git，运行时走 artifacts）
│   ├── manifest.json            # 运行时文件清单 (path + sha256)
│   ├── config/                  # 出厂配置快照（不含设备自治件）
│   └── usb/upgrade.sha256       # 最小 USB 升级包的校验值
├── custom/                      ④ 产品自定义（公司 / APN / MQTT 模板）
├── deploy/                      ⑤⑥ 部署脚本
│   ├── factory-deploy.sh        # Linux
│   ├── factory-deploy.ps1       # Windows
│   ├── lib/sync.sh              # 制品通道同步
│   └── device/                  # 设备侧 init 脚本模板
└── artifacts/                   制品通道（.gitignore 整目录，仅留 MANIFEST.sha256）
```

## 产品自定义（公司 / APN / MQTT）

`custom/example/` 是模板，按客户复制一份：

```bash
cp -r custom/example custom/acme
# 改 custom/acme/config/shared/system/company.toml 的 company_id
# 改 custom/acme/config/<product>/<product>_mqtt.toml 的凭据
# 改 custom/acme/apn 的内容
```

部署时带 `--custom acme`（Windows `-Custom acme`），脚本会：

1. 把 `custom/acme/config/` 逐文件覆盖到设备 `config/` 下
2. 把 `custom/acme/apn` 写进设备 `/etc/ec200a-apn`

| 文件 | 作用 | 出厂默认 |
|---|---|---|
| `config/shared/system/company.toml` | 公司标识（`comnav` / `seezol`） | 见 `products/*/config/shared/system/` |
| `config/<product>/*mqtt*.toml` | MQTT 服务器与凭据 | `sz001`（owner 2026-11-17 确认沿用） |
| `apn` | 4G APN | `mobile` |

`custom/<代号>/` 已加入 `.gitignore`（只有 `example/` 入 git），真实凭据不会进仓。

## 制品通道（内网 NAS）

`artifacts/` 下的大文件不入 git，由 `deploy/lib/sync.sh` / `sync.ps1` 按 `artifacts/MANIFEST.sha256` 拉取并校验。配置来源三选一：

1. 环境变量 `ARTIFACTS_URL`（`http://192.168.110.96:8080/product-release` / `//192.168.110.96/product-release` / `file:///mnt/nas/...`）
2. 环境变量 `ARTIFACTS_MOUNT`（已挂载的本地路径）
3. 仓库内 `artifacts/nas.conf`（交付端自行填写，不覆盖）

**默认制品通道 = `192.168.110.96`**。两个脚本都内置了默认值 —— **什么都不配也能直接 sync**（脚本会打印 `使用默认制品通道: …`），只有要换地址时才需要上面三种配置之一。同一份目录对外有两种协议：

| 协议 | 地址 | 说明 |
| --- | --- | --- |
| **HTTP（默认）** | `http://192.168.110.96:8080/product-release` | 只读、匿名，无需任何客户端配置 |
| SMB（可选） | `\\192.168.110.96\product-release` | 只读匿名共享，Linux 走 `smbclient -N` |

**为什么默认走 HTTP**：Windows 10 1709+ / Windows 11 默认 `AllowInsecureGuestAuth = 0`，客户端会直接拒绝匿名 SMB 来宾访问，报「你不能访问此共享文件夹，因为你组织的安全策略阻止未经身份验证的来宾访问」（0x80070569）。这是**客户端策略**，服务端怎么配都绕不过去（实测服务端日志里连一个 session 都没有）。HTTP 没有这层限制。

共享根就是 `artifacts/` 的内容 —— `flash/` 与 `products/` 直接位于共享根下，**不是**仓库根。

## 编码约定（Windows 脚本）

`deploy/factory-deploy.ps1` 与 `deploy/lib/sync.ps1` **必须保存为 UTF-8 with BOM**。

原因：Windows PowerShell 5.1 对无 BOM 的文件按系统 ANSI 代码页（中文机器上是 GBK）解码。
一旦 BOM 丢了，所有中文串会变成 `缂哄皯鍒跺搧鐩綍` 这种乱码，其中某些字节还会变成引号,
把字符串提前截断 → 整份脚本 `ParserError`，报的却是 `缺少右"}"`、`"||"不是有效语句分隔符`
这类完全不相干的错误（2026-11-26 实发）。PowerShell 7 无 BOM 也能读，所以这个坑只在 5.1 上出现。

改脚本时别用会丢 BOM 的编辑器/脚本（例如 `python open(w, encoding='utf-8')` 会丢）。

## 构建端

发布内容由主仓 `rust_crane` 的 `scripts/release-stage.sh` 生成：

```bash
make release-stage PRODUCT=loader          # 单产品
make release-stage ALL=1                   # 全部 5 产品
make release-stage PRODUCT=loader DRY_RUN=1
```

## 版本

`VERSION` 文件由构建端从主仓 `Cargo.toml` 同步；`products/*/manifest.json` 的 `version` 与之一致。
