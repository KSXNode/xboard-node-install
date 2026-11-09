# KSXNode Node Installer

KSXNode 節點安裝腳本與多架構執行檔。

- 支援 `linux/amd64`、`linux/arm64`、`linux/arm/v7`
- 支援 node 模式（單一節點）與 machine 模式（面板動態下發節點）
- 支援 systemd（Debian / Ubuntu 等）、OpenWrt / ImmortalWrt 的 procd，以及
  ASUS / Broadcom 路由器（Asuswrt，`/jffs` 持久化 + `/tmp` 執行）
- 透過 GitHub Releases 下載執行檔，不依賴私有映像倉庫
- 目前最新 Release：`v1.13-hotoutbound`（含出站熱載入，新增 outbound 不需重啟節點）

## 安裝

### Machine 模式

```bash
curl -fsSL https://raw.githubusercontent.com/KSXNode/xboard-node-install/main/install.sh \
  | sudo sh -s -- \
      --mode machine \
      --panel https://panel.example.com \
      --token YOUR_MACHINE_TOKEN \
      --machine-id 1
```

### Node 模式

```bash
curl -fsSL https://raw.githubusercontent.com/KSXNode/xboard-node-install/main/install.sh \
  | sudo sh -s -- \
      --mode node \
      --panel https://panel.example.com \
      --token YOUR_NODE_TOKEN \
      --node-id 1
```

### OpenWrt / ImmortalWrt

以 root 執行（沒有 sudo），並先確定有 `ca-bundle`：

```sh
opkg update && opkg install ca-bundle

wget -qO- https://raw.githubusercontent.com/KSXNode/xboard-node-install/main/install.sh \
  | sh -s -- \
      --mode machine \
      --panel https://panel.example.com \
      --token YOUR_MACHINE_TOKEN \
      --machine-id 1
```

腳本會自動判斷 init 系統：有 `/run/systemd/system` 用 systemd，有 `/etc/rc.common`
用 procd。也可以用 `--service` 指定。

### ASUS / Broadcom 路由器（Asuswrt）

ASUS 原廠韌體沒有 systemd/procd，但 `/jffs` 可持久化。安裝器會把
binary、config 與啟動腳本放到 `/jffs/xboard-node`，執行時解壓到 `/tmp`，
並在 `/data/startup.sh` 寫入開機鉤子：

```sh
wget -qO- https://raw.githubusercontent.com/KSXNode/xboard-node-install/main/install.sh \
  | sh -s -- \
      --mode machine \
      --panel https://panel.example.com \
      --token YOUR_MACHINE_TOKEN \
      --machine-id 1 \
      --domain router.example.com \
      --service asuswrt \
      --ports 7410:7413
```

`--ports` 會把指定埠範圍加入 `iptables INPUT`（可省略）。部分原廠韌體不會
執行 `/data/startup.sh`，此時請在外部主機加一個定時 SSH 看門狗，定期執行
`/jffs/xboard-node/start.sh`。

## 參數

| 參數 | 說明 |
|------|------|
| `--mode node\|machine` | 安裝模式，預設 `node` |
| `--panel URL` | 面板網址 |
| `--token TOKEN` | node token 或 machine token |
| `--node-id ID` | node 模式的節點 ID |
| `--machine-id ID` | machine 模式的機器 ID |
| `--kernel NAME` | 核心類型，預設 `singbox` |
| `--domain DOMAIN` | 憑證網域，預設取面板 hostname |
| `--version TAG` | 指定 Release 版本，預設 `latest` |
| `--service MODE` | `auto`、`systemd`、`procd`、`asuswrt` 或 `none`，預設 `auto` |
| `--ports RANGE` | 僅 Asuswrt：加入 iptables 的埠範圍，例如 `7410:7413` |
| `--force` | 覆蓋既有設定（仍會先備份） |

## 安裝內容

| 路徑 | 用途 |
|------|------|
| `/usr/local/bin/xboard-node` | 節點執行檔 |
| `/etc/xboard-node/config.yml` | 設定檔（權限 600） |
| `/etc/systemd/system/xboard-node.service` | systemd 服務（systemd 主機） |
| `/etc/init.d/xboard-node` | procd 服務（OpenWrt / ImmortalWrt） |
| `/jffs/xboard-node/xboard-node-ARCH.gz` | Asuswrt：持久化壓縮執行檔 |
| `/jffs/xboard-node/config.yml` | Asuswrt：持久化設定（權限 600） |
| `/jffs/xboard-node/start.sh` | Asuswrt：啟動腳本 |
| `/data/startup.sh` | Asuswrt：開機鉤子 |
| `/tmp/xboard-node/` | Asuswrt：執行時 binary、config、日誌 |

## 管理

systemd：

```bash
systemctl status xboard-node
journalctl -u xboard-node -f
systemctl restart xboard-node
```

OpenWrt / ImmortalWrt：

```sh
/etc/init.d/xboard-node status
logread | grep xboard-node
/etc/init.d/xboard-node restart
```

## 版本與執行檔

執行檔放在 GitHub Releases：

<https://github.com/KSXNode/xboard-node-install/releases>

Asset 命名：`xboard-node-amd64.gz`、`xboard-node-arm64.gz`、`xboard-node-armv7.gz`。
每個 Release 附 `checksums.txt`（SHA256）。

要固定版本：

```bash
--version v1.13-hotoutbound
```

## 安全

- 安裝指令含 token，請避免在共用主機上留下 shell history。
- `config.yml` 權限為 `600`，請勿提交或備份到公開位置。
- token 外洩時請立刻在面板重新產生。

## 授權

MIT
