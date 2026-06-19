#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

source ./gke.conf

# 出力先フォルダの指定
OUTPUT_DIR="./data"
mkdir -p "$OUTPUT_DIR"

DATE=$(date +%Y%m%d)
OUTPUT_FILE="${OUTPUT_DIR}/${DATE}_${CLUSTER_NAME}.csv"

# 標準出力をCSVファイルにリダイレクト
exec > "$OUTPUT_FILE"
echo "Output writing to: $OUTPUT_FILE" >&2

# クラスタ認証取得
echo "Fetching cluster credentials for ${CLUSTER_NAME} in project ${PROJECT_ID}..." >&2
gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE" --project "$PROJECT_ID"

# ヘッダー出力
echo "Name,Namespace,Type,CPU (vCPU),Memory (GiB),Ephemeral Storage (GB),Persistent Disk (GB),Pod,minReplicas,maxReplicas"

TOTAL_COUNT=0
TOTAL_CPU=0
TOTAL_MEM=0

for NAMESPACE in "${NAMESPACES[@]}"; do
  echo "=== Start processing namespace: $NAMESPACE ===" >&2

  KEDA_SCALEDOBJECTS=$(kubectl get scaledobject.keda.sh -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items": []}')
  HPA_LIST=$(kubectl get hpa -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items": []}')

  for TYPE in "${TYPES[@]}"; do
    # ワークロード名取得
    WORKLOAD_NAMES=$(kubectl get "$TYPE" -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    COUNT=0
    TOTAL_NAMES=$(echo "$WORKLOAD_NAMES" | wc -l)

    for NAME in $WORKLOAD_NAMES; do
      COUNT=$((COUNT + 1))
      # 進捗表示
      printf "\r\033[KProcessing %s/%s: %s -> %s" "$COUNT" "$TOTAL_NAMES" "$TYPE" "$NAME" >&2

      JSON=$(kubectl get "$TYPE" "$NAME" -n "$NAMESPACE" -o json)

      # Pod数
      if [ "$TYPE" = "cronjob" ]; then
        POD_COUNT=$(echo "$JSON" | jq -r '.status.active | length // 0')
      else
        POD_COUNT=$(echo "$JSON" | jq -r '.status.replicas // 0')
      fi

      # CPU
      CPU=$(echo "$JSON" | jq -r '[
        (.spec.template?.spec.containers // .spec.jobTemplate?.spec.template.spec.containers // [])[]
        | .resources.requests.cpu // "0"
      ] | map(
          if test("^[0-9]+m$") then
            (sub("m$"; "") | tonumber) / 1000
          elif test("^[0-9]+(\\.[0-9]+)?$") then
            tonumber
          else
            0
          end
        ) | add')

      # Memory
      MEM=$(echo "$JSON" | jq -r '[
        (.spec.template?.spec.containers // .spec.jobTemplate?.spec.template.spec.containers // [])[]
        | .resources.requests.memory // "0Mi"
      ] | map(
          if test("Gi$") then
            (sub("Gi$"; "") | tonumber)
          elif test("Mi$") then
            (sub("Mi$"; "") | tonumber / 1024)
          else
            0
          end
        ) | add')

      # Ephemeral Storage
      EPHEMERAL=$(echo "$JSON" | jq -r '[
        (.spec.template?.spec.containers // .spec.jobTemplate?.spec.template.spec.containers // [])[]
        | .resources.requests["ephemeral-storage"] // "0Mi"
      ] | map(
          if test("Gi$") then
            (sub("Gi$"; "") | tonumber)
          elif test("Mi$") then
            (sub("Mi$"; "") | tonumber / 1024)
          else
            0
          end
        ) | add')

      # Persistent Disk
      PVC_TOTAL=0
      PVC_NAMES=$(echo "$JSON" | jq -r '.spec.template?.spec.volumes[]? | select(.persistentVolumeClaim) | .persistentVolumeClaim.claimName')
      for PVC in $PVC_NAMES; do
        SIZE=$(kubectl get pvc "$PVC" -n "$NAMESPACE" -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "0Gi")
        if [[ "$SIZE" =~ Gi$ ]]; then
          PVC_TOTAL=$((PVC_TOTAL + ${SIZE%Gi}))
        elif [[ "$SIZE" =~ Mi$ ]]; then
          PVC_TOTAL=$((PVC_TOTAL + ${SIZE%Mi} / 1024))
        fi
      done

      # KEDA または 標準HPA から min/maxReplicas を取得
      MIN_REP="-"
      MAX_REP="-"
      MATCHING_SCALED=$(echo "$KEDA_SCALEDOBJECTS" | jq --arg NAME "$NAME" '.items[] | select(.spec.scaleTargetRef.name == $NAME)' 2>/dev/null || true)
      if [[ -n "$MATCHING_SCALED" ]]; then
        MIN_REP=$(echo "$MATCHING_SCALED" | jq -r '.spec.minReplicaCount // "-"')
        MAX_REP=$(echo "$MATCHING_SCALED" | jq -r '.spec.maxReplicaCount // "-"')
      fi

      if [[ "$MIN_REP" == "-" || "$MAX_REP" == "-" ]]; then
        MATCHING_HPA=$(echo "$HPA_LIST" | jq --arg NAME "$NAME" --arg KIND "$TYPE" '.items[] | select(.spec.scaleTargetRef.name == $NAME and (.spec.scaleTargetRef.kind | ascii_downcase) == ($KIND | ascii_downcase))' 2>/dev/null || true)
        if [[ -n "$MATCHING_HPA" ]]; then
          HPA_MIN=$(echo "$MATCHING_HPA" | jq -r '.spec.minReplicas // "1"')
          HPA_MAX=$(echo "$MATCHING_HPA" | jq -r '.spec.maxReplicas // "-"')
          [[ "$MIN_REP" == "-" ]] && MIN_REP=$HPA_MIN
          [[ "$MAX_REP" == "-" ]] && MAX_REP=$HPA_MAX
        fi
      fi

      # CSV出力
      echo "${NAME},${NAMESPACE},${TYPE},${CPU},${MEM},${EPHEMERAL},${PVC_TOTAL},${POD_COUNT},${MIN_REP},${MAX_REP}"

      TOTAL_COUNT=$((TOTAL_COUNT + 1))
      TOTAL_CPU=$(awk "BEGIN {print $TOTAL_CPU + $CPU}")
      TOTAL_MEM=$(awk "BEGIN {print $TOTAL_MEM + $MEM}")
    done
    printf "\r" >&2
    echo "" >&2
  done

  echo "=== Finished processing namespace: $NAMESPACE ===" >&2
done

# 合計値出力
echo -e "\n--- TOTAL ---" >&2
echo "Workloads: $TOTAL_COUNT" >&2
echo "Total CPU (vCPU): $TOTAL_CPU" >&2
echo "Total Memory (GiB): $TOTAL_MEM" >&2
echo "Saved to $OUTPUT_FILE" >&2
