# custom/example — 产品自定义模板

交付时按客户复制一份目录（如 `custom/acme/`），改其中的值，然后：

```bash
sudo ./deploy/factory-deploy.sh --product loader --custom acme      # Linux
.\deploy\factory-deploy.ps1 -Product loader -Custom acme            # Windows
```

部署脚本会把 `custom/<代号>/config/` 逐文件覆盖到设备 `config/` 下，
并把 `custom/<代号>/apn` 的内容写进设备 `/etc/ec200a-apn`。

## 内容

| 文件 | 作用 |
|---|---|
| `config/shared/system/company.toml` | 公司标识（`comnav` / `seezol`） |
| `config/<product>/*mqtt*.toml` | MQTT 服务器与凭据（默认 `sz001`） |
| `apn` | 4G APN（写设备 `/etc/ec200a-apn`，默认 `mobile`） |

## 注意

- 目录里只放**要覆盖的**文件，未提供的保持出厂默认。
- 真实凭据不要提交到本仓；`custom/<代号>/` 已加入 `.gitignore`，只留 `custom/example/`。
