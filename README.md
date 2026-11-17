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

`artifacts/` 下的大文件不入 git，由 `deploy/lib/sync.sh` 按 `artifacts/MANIFEST.sha256` 拉取并校验。配置来源三选一：

1. 环境变量 `ARTIFACTS_URL`（`//nas/share/product-release` 或 `file:///mnt/nas/...`）
2. 环境变量 `ARTIFACTS_MOUNT`（已挂载的本地路径）
3. 仓库内 `artifacts/nas.conf`（交付端自行填写，不覆盖）

## 构建端

发布内容由主仓 `rust_crane` 的 `scripts/release-stage.sh` 生成：

```bash
make release-stage PRODUCT=loader          # 单产品
make release-stage ALL=1                   # 全部 5 产品
make release-stage PRODUCT=loader DRY_RUN=1
```

## 版本

`VERSION` 文件由构建端从主仓 `Cargo.toml` 同步；`products/*/manifest.json` 的 `version` 与之一致。
