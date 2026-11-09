# KSXNode Node Installer

KSXNode 節點安裝腳本與多架構執行檔。

- 支援 `linux/amd64`、`linux/arm64`、`linux/arm/v7`
- 支援 node 模式（單一節點）與 machine 模式（面板動態下發節點）
- 透過 GitHub Releases 下載執行檔，不依賴私有映像倉庫

## 安裝

### Machine 模式

```bash
curl -fsSL https://raw.githubusercontent.com/KSXNode/xboard-node-install/main/install.sh \
  | sudo bash -s -- \
      --mode machine \
      --panel https://panel.example.com \
      --token YOUR_MACHINE_TOKEN \
      --machine-id 1
```

### Node 模式

```bash
curl -fsSL https://raw.githubusercontent.com/KSXNode/xboard-node-install/main/install.sh \
  | sudo bash -s -- \
      --mode node \
      --panel https://panel.example.com \
      --token YOUR_NODE_TOKEN \
      --node-id 1
```

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
| `--force` | 覆蓋既有設定（仍會先備份） |

## 安裝內容

| 路徑 | 用途 |
|------|------|
| `/usr/local/bin/xboard-node` | 節點執行檔 |
| `/etc/xboard-node/config.yml` | 設定檔（權限 600） |
| `/etc/systemd/system/xboard-node.service` | systemd 服務 |

## 管理

```bash
systemctl status xboard-node
journalctl -u xboard-node -f
systemctl restart xboard-node
```

## 版本與執行檔

執行檔放在 GitHub Releases：

<https://github.com/KSXNode/xboard-node-install/releases>

Asset 命名：`xboard-node-amd64.gz`、`xboard-node-arm64.gz`、`xboard-node-armv7.gz`。

## 安全

- 安裝指令含 token，請避免在共用主機上留下 shell history。
- `config.yml` 權限為 `600`，請勿提交或備份到公開位置。
- token 外洩時請立刻在面板重新產生。

## 授權

MIT
