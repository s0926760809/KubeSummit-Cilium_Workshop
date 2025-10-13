# KubeSummit-Cilium_Workshop(2025/10/23 KubeSummit)

# 一開始請先切換至對應GCP Project
```bash
# 切換到專案底下
gcloud config set project [PROJECT_ID]

# 給予腳本對應權限
chmod +x Lab1_Cilium-KubeProxyReplacement.sh
chmod +x Lab1_Cilium-Kubeproxy.sh

# 分別開啟兩個Console執行安裝腳本(建立初始化環境)
./Lab1_Cilium-KubeProxyReplacement.sh
./Lab1_Cilium-Kubeproxy.sh
```

