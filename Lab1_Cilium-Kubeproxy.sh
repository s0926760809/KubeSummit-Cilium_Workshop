#!/bin/bash

# ==============================================================================
# GCP Cilium 實驗環境 - 全自動化部署腳本 (參數化版本)
# 使用方法:
# 1. 開啟 GCP Cloud Shell
# 2. 將此腳本儲存為檔案 (例如: deploy-cilium.sh)
# 3. 給予執行權限: chmod +x deploy-cilium.sh
# 4. 執行腳本並指定 VM 數量: ./deploy-cilium.sh <VM數量>
# ==============================================================================

# --- 參數處理 ---
VM_COUNT=${1:-1}

# 驗證參數
if ! [[ "$VM_COUNT" =~ ^[0-9]+$ ]] || [ "$VM_COUNT" -lt 1 ] || [ "$VM_COUNT" -gt 10 ]; then
    echo "錯誤：VM 數量必須是 1-10 之間的數字。"
    echo "使用方法: $0 <VM數量>"
    exit 1
fi

# --- 腳本設定 ---
set -e
export PROJECT_ID=$(gcloud config get-value project)
export REGION="asia-east1"
export ZONE="asia-east1-a"
export MACHINE_TYPE="e2-standard-4"
export IMAGE_PROJECT="ubuntu-os-cloud"
export IMAGE_FAMILY="ubuntu-2204-lts"
export DISK_SIZE="50GB"
export DISK_TYPE="pd-ssd"
export VM_PREFIX="cilium-lab-kp"
export LAB_TAG="cilium-lab"
export TAGS="http-server,https-server,${LAB_TAG}"

# 動態產生 VM 名稱陣列
VM_NAMES=()
for i in $(seq 1 $VM_COUNT); do
    VM_NAMES+=("${VM_PREFIX}-${i}")
done

# --- 函式：顯示標題 ---
print_header() {
    echo ""
    echo "======================================================================"
    echo " $1"
    echo "======================================================================"
    echo ""
}

# --- 顯示部署資訊 ---
print_header "部署資訊"
echo "專案 ID: $PROJECT_ID"
echo "區域: $REGION"
echo "可用區: $ZONE"
echo "VM 數量: $VM_COUNT"
echo "VM 名稱: ${VM_NAMES[@]}"
echo "將套用的 Tag: $TAGS"
echo ""
read -p "確認要繼續部署嗎？(y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "取消部署。"
    exit 0
fi

# --- 步驟 1: 建立防火牆規則 (若不存在) ---
print_header "步驟 1: 檢查並設定 GCP 防火牆規則..."

if [ -z "$PROJECT_ID" ]; then
    echo "錯誤：無法取得 GCP 專案 ID。請執行: gcloud config set project YOUR_PROJECT_ID"
    exit 1
fi

if ! gcloud compute regions list --limit=1 &>/dev/null; then
    echo "錯誤：無法存取 Compute Engine API。請確認 API 已啟用且您有足夠權限。"
    exit 1
fi

# 建立專屬 SSH 規則
SSH_RULE_NAME="allow-ssh-for-cilium-lab"
echo "檢查專屬 SSH 防火牆規則 '$SSH_RULE_NAME'..."
if ! gcloud compute firewall-rules describe $SSH_RULE_NAME --project=$PROJECT_ID &>/dev/null; then
    echo "建立防火牆規則 '$SSH_RULE_NAME'..."
    gcloud compute firewall-rules create $SSH_RULE_NAME \
        --project=$PROJECT_ID \
        --network=default \
        --allow=tcp:22 \
        --source-ranges=0.0.0.0/0 \
        --target-tags=${LAB_TAG} \
        --description="Allow SSH access for Cilium Lab VMs"
fi

# 建立實驗所需端口的規則
FW_LAB_PORTS_NAME="allow-cilium-lab-access-ports"
echo "檢查防火牆規則 '$FW_LAB_PORTS_NAME'..."
if ! gcloud compute firewall-rules describe $FW_LAB_PORTS_NAME --project=$PROJECT_ID &>/dev/null; then
    echo "建立防火牆規則: $FW_LAB_PORTS_NAME..."
    gcloud compute firewall-rules create $FW_LAB_PORTS_NAME \
        --project=$PROJECT_ID \
        --allow tcp:30012,tcp:30090,tcp:30030,tcp:30093,tcp:6443 \
        --source-ranges 0.0.0.0/0 \
        --description="Access ports for Cilium Lab services" \
        --target-tags=$LAB_TAG
fi

echo "✅ 防火牆規則檢查完成。"

# --- 步驟 2: 產生要在 VM 上執行的安裝腳本 ---
print_header "步驟 2: 產生 VM 內部安裝腳本..."
cat << 'EOF' > install_on_vm_kp.sh
#!/bin/bash
set -ex

echo "--- [VM內部] 開始更新系統與安裝基礎工具 ---"
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y \
    curl wget apt-transport-https ca-certificates gnupg lsb-release \
    jq net-tools htop 

echo "--- [VM內部] 開始安裝 Docker ---"
# ** 修正 #1: 重新手動輸入此區塊以移除不可見的特殊字元 **
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
# ** 修正結束 **
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER

echo "--- [VM內部] 開始安裝 kubectl, kind, helm, cilium-cli ---"
# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
# Install Kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.22.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
# Install Cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

echo "=== Ubuntu 22.04 優化設定 ==="

# 增加檔案描述符限制，以支援大量連線和檔案操作
sudo sysctl -w fs.file-max=1048576

# 增加 inotify 限制，改善檔案系統監控能力 (例如 Kubelet)
sudo sysctl -w fs.inotify.max_user_watches=1048576
sudo sysctl -w fs.inotify.max_user_instances=8192

# 增加記憶體映射區域數量，對容器化應用和資料庫很重要
sudo sysctl -w vm.max_map_count=262144

# 開啟 BPF JIT (Just-In-Time) 編譯器以提升 eBPF 程式效能
sudo sysctl -w net.core.bpf_jit_enable=1
# 先確保 BPF 檔案系統已掛載
sudo mount -t bpf bpf /sys/fs/bpf/ 2>/dev/null || true

echo "系統核心參數已優化。"

echo "--- [VM內部] 產生 Kind 叢集設定檔 ---"
cat << EOK > kind-config.yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  kubeProxyMode: "iptables"
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    maxPods: 200
- role: worker
  kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    maxPods: 150
- role: worker
  kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    maxPods: 150
- role: worker
  kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    maxPods: 150
EOK

echo "--- [VM內部] 使用 Kind 建立 K8s 叢集 ---"
sudo /usr/local/bin/kind create cluster --config=kind-config.yaml

echo "--- [VM內部] 設定 kubectl 設定檔 ---"
mkdir -p $HOME/.kube
sudo cp /root/.kube/config $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl cluster-info

# ** 修正 #2: 簡化 Cilium 安裝指令，避免與後續的 Prometheus 安裝衝突 **

echo "--- [VM內部] 安裝 Cilium ---"
# 
CONTROLLER_IP=$(kubectl get node -o wide --no-headers | grep control-plane | awk '{print $6}')

cilium install \
  --version=1.17.6 \
  --set k8sServiceHost=$CONTROLLER_IP \
  --set k8sServicePort=6443 \
  --set routingMode=native \
  --set kubeProxyReplacement=false \
  --set autoDirectNodeRoutes=true \
  --set ipv4NativeRoutingCIDR="10.0.0.0/8" \
  --set enableIPv4Masquerade=true \
  --set ipam.mode=cluster-pool \
  --set loadBalancer.mode=hybrid \
  --set hubble.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.relay.enabled=true \
  --set envoy.prometheus.enabled=true \
  --set hubble.metrics.enableOpenMetrics=true \
  --set hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp,httpV2:exemplars=true;labelsContext=source_ip\,source_namespace\,source_workload\,destination_ip\,destination_namespace\,destination_workload\,traffic_direction}" \
  --set cluster.name=cilium-with-kubeproxy \
  --set debug.enabled=true
cilium status --wait

# --- [VM內部] 產生使用者自訂的端口轉發腳本 ---
echo "--- [VM內部] 產生直接端口轉發腳本 (start-port-forward.sh) ---"
cat << 'EOPF' > start-port-forward.sh
#!/bin/bash

echo "🚀 啟動直接端口轉發..."

# 清理現有進程
pkill -f "kubectl port-forward" 2>/dev/null
sleep 2

# 獲取VM外部IP
VM_IP=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H "Metadata-Flavor: Google")

# 直接轉發到VM的外部可訪問端口
kubectl port-forward -n kube-system svc/hubble-ui 30012:80 --address=0.0.0.0 &
kubectl port-forward -n cilium-monitoring svc/prometheus 30090:9090 --address=0.0.0.0 &
kubectl port-forward -n cilium-monitoring svc/grafana 30030:3000 --address=0.0.0.0 &

sleep 3

echo ""
echo "✅ 端口轉發已啟動！"
echo ""
echo "🌐 直接訪問地址："
echo "    Hubble UI:     http://$VM_IP:30012"
echo "    Prometheus:    http://$VM_IP:30090"
echo "    Grafana:       http://$VM_IP:30030 (admin/cilium123)"
echo "    AlertManager:  http://$VM_IP:30093"
echo ""
echo "按 Ctrl+C 停止所有服務"

# 設置陷阱清理進程
trap "echo '🛑 停止端口轉發...'; pkill -f 'kubectl port-forward'; echo '✅ 已停止'; exit" INT TERM

# 保持腳本運行
wait
EOPF
chmod +x start-port-forward.sh
# --- 端口轉發腳本產生完畢 ---

echo "--- [VM內部] 安裝完成！ ---"
echo "所有元件已安裝完畢。"
echo "請登入此 VM 後執行 './start-port-forward.sh' 來啟動服務端口轉發。"

EOF
# --- 內部安裝腳本產生完畢 ---

# --- 步驟 3: 循環建立、複製並執行安裝腳本 ---
for vm_name in "${VM_NAMES[@]}"; do
    print_header "步驟 3: 處理 VM: $vm_name"
    
    if gcloud compute instances describe "$vm_name" --zone="$ZONE" &>/dev/null; then
        echo "VM '$vm_name' 已存在，跳過建立。"
    else
        echo "正在建立 VM: $vm_name..."
        gcloud compute instances create "$vm_name" \
            --project=$PROJECT_ID \
            --zone=$ZONE \
            --machine-type=$MACHINE_TYPE \
            --network-interface="subnet=default,network-tier=PREMIUM" \
            --scopes=https://www.googleapis.com/auth/cloud-platform \
            --tags=$TAGS \
            --image-project=$IMAGE_PROJECT \
            --image-family=$IMAGE_FAMILY \
            --boot-disk-size=$DISK_SIZE \
            --boot-disk-type=$DISK_TYPE
    fi
    
    echo "正在等待 VM ($vm_name) 的 SSH 服務啟動..."
    for i in $(seq 1 40); do
        if gcloud compute ssh "$vm_name" --zone="$ZONE" --command="echo 'SSH is ready'" &>/dev/null; then
            echo "✅ SSH 服務已在 $vm_name 上就緒。"
            break
        fi
        if [ $i -eq 40 ]; then
            echo "錯誤：等待 SSH 服務啟動超時 ($vm_name)。" >&2
            exit 1
        fi
        echo "SSH 尚未就緒，10 秒後重試... (嘗試次數: $i/40)"
        sleep 10
    done
    
    echo "將安裝腳本複製到 $vm_name..."
    gcloud compute scp install_on_vm_kp.sh "$vm_name":~/ --zone=$ZONE

    echo "在 $vm_name 上遠端執行安裝腳本 (這可能需要 15-20 分鐘)..."
    gcloud compute ssh "$vm_name" --zone="$ZONE" --command="bash install_on_vm_kp.sh"
    
    echo "✅ VM $vm_name 部署完成"
done

# --- 步驟 4: 顯示最終連線資訊 ---
print_header "🚀🎉 全部署完成！ 🎉🚀"
for vm_name in "${VM_NAMES[@]}"; do
    PUBLIC_IP=$(gcloud compute instances describe "$vm_name" --zone="$ZONE" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
    echo "----------------------------------------------------------------------"
    echo "VM 名稱: $vm_name"
    echo "公有 IP: $PUBLIC_IP"
    echo "SSH 連線: gcloud compute ssh $vm_name --zone=$ZONE"
    echo ""
    echo "下一步："
    echo "1. 使用上面的 SSH 指令登入 VM。"
    echo "2. 在 VM 內部執行 './start-port-forward.sh' 來啟動服務。"
    echo "3. 腳本會顯示您可以從本地瀏覽器訪問的 URL。"
done
echo "----------------------------------------------------------------------"

# --- 步驟 5: 產生清理腳本 ---
print_header "產生清理腳本"
cat << 'CLEANUP_EOF' > cleanup-cilium-vms.sh
#!/bin/bash
set -e

# 設定變數
ZONE="asia-east1-a"
LAB_TAG="cilium-lab"
PROJECT_ID=$(gcloud config get-value project)

echo "======================================================================"
echo " Cilium Lab 資源清理腳本"
echo "======================================================================"
echo ""
echo "專案 ID: $PROJECT_ID"
echo "區域: $ZONE"
echo "標籤: $LAB_TAG"
echo ""

# 方法 1: 使用 filter 查找 VM（修正版本）
echo "正在搜尋帶有 '${LAB_TAG}' 標籤的 VM..."
VM_LIST=$(gcloud compute instances list \
    --filter="tags.items=${LAB_TAG} AND zone:${ZONE}" \
    --format="value(name)" \
    2>/dev/null)

# 如果方法 1 沒找到，嘗試方法 2（使用前綴名稱）
if [ -z "$VM_LIST" ]; then
    echo "使用標籤搜尋未找到 VM，嘗試使用名稱前綴搜尋..."
    VM_LIST=$(gcloud compute instances list \
        --filter="name:cilium-lab-* AND zone:${ZONE}" \
        --format="value(name)" \
        2>/dev/null)
fi

# 檢查是否找到任何 VM
if [ -z "$VM_LIST" ]; then
    echo "❌ 沒有找到任何 Cilium Lab 相關的 VM。"
    echo ""
    echo "提示：您可以使用以下命令手動檢查："
    echo "  gcloud compute instances list --zones=$ZONE"
    exit 0
fi

# 顯示找到的 VM
echo ""
echo "✅ 找到以下 VM："
echo "----------------------------------------------------------------------"
echo "$VM_LIST" | while read vm; do
    echo "  • $vm"
done
echo "----------------------------------------------------------------------"
echo ""

# 計算 VM 數量
VM_COUNT=$(echo "$VM_LIST" | wc -l)
echo "共計 $VM_COUNT 個 VM 將被刪除。"
echo ""

# 確認刪除
read -p "⚠️  確認要刪除上述所有 VM 嗎？(y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ 取消刪除操作。"
    exit 0
fi

echo ""
echo "開始刪除 VM..."
echo ""

# 逐個刪除 VM（更可靠的方式）
SUCCESS_COUNT=0
FAIL_COUNT=0

echo "$VM_LIST" | while read vm; do
    if [ ! -z "$vm" ]; then
        echo -n "正在刪除 $vm ... "
        if gcloud compute instances delete "$vm" \
            --zone="$ZONE" \
            --quiet \
            2>/dev/null; then
            echo "✅ 成功"
            ((SUCCESS_COUNT++))
        else
            echo "❌ 失敗"
            ((FAIL_COUNT++))
        fi
    fi
done

echo ""
echo "======================================================================"
echo " 清理完成"
echo "======================================================================"
echo ""

# 提醒防火牆規則
echo "💡 提醒：以下防火牆規則尚未刪除（如需要請手動刪除）："
echo "  • allow-ssh-for-cilium-lab"
echo "  • allow-cilium-lab-access-ports"
echo ""
echo "如要刪除防火牆規則，請執行："
echo "  gcloud compute firewall-rules delete allow-ssh-for-cilium-lab --quiet"
echo "  gcloud compute firewall-rules delete allow-cilium-lab-access-ports --quiet"
echo ""
CLEANUP_EOF

chmod +x cleanup-cilium-vms.sh
echo "✅ 已產生清理腳本: cleanup-cilium-vms.sh"
echo ""
echo "📌 使用方式："
echo "   ./cleanup-cilium-vms.sh    # 刪除所有已建立的 VM"
echo ""

# --- 步驟 6: 產生防火牆規則清理腳本 ---
cat << 'FW_CLEANUP_EOF' > cleanup-firewall-rules.sh
#!/bin/bash
set -e

echo "======================================================================"
echo " 防火牆規則清理腳本"  
echo "======================================================================"
echo ""

# 防火牆規則名稱
FW_RULES=(
    "allow-ssh-for-cilium-lab"
    "allow-cilium-lab-access-ports"
)

echo "將刪除以下防火牆規則："
for rule in "${FW_RULES[@]}"; do
    echo "  • $rule"
done
echo ""

read -p "確認要刪除這些防火牆規則嗎？(y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "取消刪除。"
    exit 0
fi

echo ""
for rule in "${FW_RULES[@]}"; do
    echo -n "刪除 $rule ... "
    if gcloud compute firewall-rules delete "$rule" --quiet 2>/dev/null; then
        echo "✅ 成功"
    else
        echo "❌ 失敗或不存在"
    fi
done

echo ""
echo "✅ 防火牆規則清理完成。"
FW_CLEANUP_EOF

chmod +x cleanup-firewall-rules.sh
echo "✅ 已產生防火牆清理腳本: cleanup-firewall-rules.sh"
echo ""

echo "======================================================================"
echo " 🎉 所有腳本執行完畢！"
echo "======================================================================"

# 清理暫存檔案
rm -f install_on_vm_kp.sh
