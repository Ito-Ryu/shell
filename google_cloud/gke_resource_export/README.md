# GKE ワークロード情報収集ツール

このツールは、指定した GKE（Google Kubernetes Engine）クラスタ内の各ワークロードの構成とリソース要求量を自動で収集し、容量設計やコスト最適化、不要リソースの棚卸しに役立つCSVレポートを出力するスクリプトである。

Standard クラスタだけでなく、**Autopilot クラスタにも対応**している。

---

## 1. 取得できるデータ（何を取得したいか）

スクリプトを実行すると、対象の Namespace にデプロイされているすべての **Deployment、StatefulSet、CronJob** から、以下の情報を自動的に収集する。

| 取得項目 | 単位 | 説明 |
| :--- | :--- | :--- |
| **ワークロード名 / Namespace / Type** | - | リソース名、デプロイ先、リソースの種類 |
| **CPU / Memory (要求量)** | vCPU / GiB | コンテナ全体で要求（Request）しているCPUとメモリの合計値 |
| **Ephemeral Storage (要求量)** | GB | コンテナ全体で要求している一時ストレージの合計値 |
| **Persistent Disk (永続ディスク)** | GB | ワークロードがマウントしている PVC (Persistent Volume Claim) の合計容量 |
| **Pod 数 (レプリカ数)** | 個 | 現在稼働中（Active）の Pod 数 |
| **minReplicas / maxReplicas** | 個 | オートスケーラー設定（**KEDA** または **標準HPA**）による最小・最大レプリカ数 |

---

## 2. 前提条件

### 必要なコマンドツール
本スクリプトの実行には、以下のコマンドがインストールされている必要がある。
*   `gcloud` (Google Cloud SDK)
*   `kubectl` (Kubernetes CLI)
*   `jq` (JSON解析ツール)
*   `awk`, `bc` (計算処理用)

### 必要な GCP IAM 権限（クラスタ接続・閲覧用）
対象の GKE クラスタに接続してリソース情報を取得するために、実行する Google アカウント（またはサービスアカウント）に**以下のいずれか、もしくは同等の IAM 権限**が付与されている必要がある。

*   **Kubernetes Engine 閲覧者 (`roles/container.viewer`)**
    *   クラスタ内のリソース（Deployment、HPA、ScaledObject、Pod、PVC など）を `kubectl get` で読み取るために必要となる。
*   **Kubernetes Engine クラスター閲覧者 (`roles/container.clusterViewer`)**
    *   クラスタの資格情報（credentials）を `gcloud container clusters get-credentials` で取得するために必要となる。

*(※ 情報を取得するだけであれば `roles/container.viewer` の付与を推奨する)*

---

## 3. 利用手順

### ステップ 1: 設定ファイルの準備 (`gke.conf`)
実行するディレクトリに `gke.conf` を作成し、接続先クラスタと対象の Namespace・種類を設定する。

```bash
# gke.conf の設定例
PROJECT_ID="test-project"
CLUSTER_NAME="test-cluster"
ZONE="asia-northeast1"
NAMESPACES=("test-namespace" "another-namespace")
TYPES=("deployment" "cronjob")
```

### ステップ 2: gcloud アカウント・プロジェクトの準備
スクリプトを実行する端末で、あらかじめ適切な認証を通しておく。

```bash
# 適切なアカウントをセット
gcloud config set account <YOUR_MAIL_ADDRESS>

# 対象プロジェクトをセット
gcloud config set project <PROJECT_ID>
```

### ステップ 3: スクリプトの実行
スクリプトに実行権限を与え、実行する。

```bash
# 権限の付与 (初回のみ)
chmod +x gke_resource_exporter.sh

# スクリプトの実行
./gke_resource_exporter.sh
```

### ステップ 4: 出力結果の確認
実行が完了すると、自動的にその日の日付とクラスタ名を組み合わせた CSV ファイルが **`data` フォルダ内** に生成される（フォルダがない場合は自動的に作成される）。

*   **出力ファイル名:** `data/YYYYMMDD_クラスタ名.csv` （例：`data/20260619_test-cluster.csv`）
*   **コンソール表示:** 進行状況（`Processing...`）や完了時のリソース合計サマリーは画面にリアルタイムで出力される。
