# Mandiri Bare Metal Workload Cluster

本项目继续完成已经启动的 `olvm-workloadcluster` 裸金属业务集群部署。

## 当前状态

已完成：

- 现有 Global 集群可用；
- Bare Metal Provider/Elemental 已用于生成 SeedImage；
- ACP 4.3.2 配套 Bare Metal OS 镜像已导入；
- 三台 Master 物理机已从 SeedImage 启动并注册为 `MachineInventory`：

```text
olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137
olvm-workloadcluster-d6bbbcff-a3c9-4aee-8e2b-e78eca996b12
olvm-workloadcluster-f785380f-a4d3-4bb6-a6b1-be5c253d7a62
```

磁盘规划：

```text
每台 Master：
300G → Alauda OS 系统安装盘 + COS_STATE
100G → XFS 数据盘，挂载 /var/cpaas
```

> 重要：提交到 `manifests/` 的是可审查模板。现场真实 Registry、External LB、SSH 公钥、provider-id 和每台 100G 稳定设备 ID 必须按本文命令获取后写入现场副本；未完成第 13 节检查前禁止 apply。

## 1. 执行位置和责任矩阵

本文所有命令都明确标注执行位置：

| 标记 | 在哪里执行 | 用途 |
|---|---|---|
| **[Global Master 01]** | `global-master01`，当前 `kubectl` 已连接 Global | 查询/修改 Kubernetes 资源、生成 storage patch、apply 集群 YAML |
| **[三台 Master 都执行]** | 三台已注册的裸金属 Master 本机/BMC Console | 核对 300G 系统盘、100G 数据盘、observer、最终 `/var/cpaas` 挂载 |
| **[LB/DNS 管理端]** | 客户负载均衡器和 DNS 管理界面 | 配置 External LB VIP/FQDN、TCP 6443 listener 和 DNS |
| **[Workload kubeconfig]** | Global Master 01，但显式使用生成的 `workload-kubeconfig` | 检查业务集群 Node/Pod |

### 1.1 在 Global Master 01 执行

```bash
hostname
kubectl config current-context
kubectl cluster-info
kubectl get nodes -o wide

export BM_NS=cpaas-system
export CLUSTER_NAME=olvm-workloadcluster
export KUBERNETES_VERSION=v1.34.5
export OS_IMAGE_TAG=v4.3.2-1-1.34.5-3
```

`hostname` 必须确认当前是 `global-master01`；`kubectl cluster-info` 必须指向现有 Global。本文不需要额外 kubeconfig 路径。

自动读取 Global Registry：

```bash
export GLOBAL_REGISTRY="$(kubectl -n cpaas-system get cluster global \
  -o jsonpath='{.metadata.annotations.cpaas\.io/registry-address}')"
export BASE_IMAGE=${GLOBAL_REGISTRY}/tkestack/baremetal-base-image:${OS_IMAGE_TAG}
export BASE_IMAGE_ISO=${GLOBAL_REGISTRY}/tkestack/baremetal-base-image-iso:${OS_IMAGE_TAG}
printf 'GLOBAL_REGISTRY=%s\n' "${GLOBAL_REGISTRY}"
```

如果输出为空，停止执行，先确认 Global 的实际 Registry 配置。

### 1.2 在 LB/DNS 管理端完成

本方案选择 **External LB**。在继续创建 BaremetalCluster 前，必须准备一个 Workload API VIP/FQDN，并规划：

```text
Protocol: TCP passthrough
Frontend: 实际 Workload API VIP/FQDN 的 TCP 6443
Backends: 三台裸金属 Master 的节点 IP:6443
DNS: Workload API FQDN → VIP
```

把实际入口记录在 Global Master 01：

```bash
export WORKLOAD_API_ENDPOINT='填写实际Workload-API-VIP或FQDN'
```

这里必须替换成现场真实值，不是原样复制命令。

### 1.3 Global Master 01 上的 SSH 公钥

使用已有公钥：

```bash
export SSH_PUBLIC_KEY_FILE="$(find /root/.ssh -maxdepth 1 -type f -name '*.pub' -print -quit)"
test -n "${SSH_PUBLIC_KEY_FILE}" || { echo '没有找到 /root/.ssh/*.pub'; exit 1; }
export SSH_PUBLIC_KEY="$(tr -d '\n' < "${SSH_PUBLIC_KEY_FILE}")"
printf 'SSH_PUBLIC_KEY_FILE=%s\n' "${SSH_PUBLIC_KEY_FILE}"
```

### 1.4 storagectl 当前尚未找到

在 **Global Master 01** 查找：

```bash
find /root /opt /usr/local/bin /var/cpaas -type f -name storagectl 2>/dev/null
```

找到后验证来源和版本必须与当前 ACP 4.3.2 Bare Metal Provider revision 匹配，再设置：

```bash
export BM_STORAGECTL=/实际/绝对路径/storagectl
"${BM_STORAGECTL}" --help
```

在找到匹配的 `storagectl` 前，**停止 100G `/var/cpaas` 初始化流程，不把三台 Inventory 加入 Pool**。

### 1.5 可选：生成不含通用占位符的现场副本

`provider-id` 必须来自 ACP 4.3.2 官方 Bare Metal Kubeadm 示例，不能猜测。确认后，在 Global Master 01 执行：

```bash
export PROVIDER_ID_VALUE='实际官方支持值'
export WORKLOAD_API_ENDPOINT='实际VIP或FQDN'
./scripts/prepare-on-global.sh
```

脚本会自动读取 Global Registry 和 `/root/.ssh/*.pub`，输出到忽略提交的 `rendered/`。Inventory 名和每台 100G 稳定设备 ID 仍必须按后续现场检查填写。

## 2. 先确认 Image Catalog

```bash
kubectl \
  -n cpaas-system get configmap elemental-image-catalog -o yaml
```

应有：

```yaml
data:
  v1.34.5: ${GLOBAL_REGISTRY}/tkestack/baremetal-base-image:v4.3.2-1-1.34.5-3
```

如果没有，使用 merge patch，保留已有版本：

```bash
kubectl \
  -n cpaas-system patch configmap elemental-image-catalog \
  --type merge \
  -p "{\"data\":{\"${KUBERNETES_VERSION}\":\"${BASE_IMAGE}\"}}"
```

`elemental-image-catalog` 使用 `base-image`；SeedImage 使用 `base-image-iso`。

## 3. 确认三台 Inventory 未被分配

```bash
for inventory in \
  olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137 \
  olvm-workloadcluster-d6bbbcff-a3c9-4aee-8e2b-e78eca996b12 \
  olvm-workloadcluster-f785380f-a4d3-4bb6-a6b1-be5c253d7a62
do
  kubectl -n "${BM_NS}" \
    get machineinventory.elemental.cattle.io "${inventory}" \
    -o jsonpath='name={.metadata.name}{"\n"}uid={.metadata.uid}{"\n"}allocation={.metadata.annotations.baremetal\.alauda\.io/allocation-state}{"\n"}baremetalMachine={.metadata.annotations.baremetal\.alauda\.io/owner-baremetalmachine}{"\n"}machine={.metadata.annotations.baremetal\.alauda\.io/owner-machine}{"\n"}cluster={.metadata.annotations.baremetal\.alauda\.io/owner-cluster}{"\n"}plan={.status.plan.secretRef.name}{"\n\n"}'
done
```

要求：allocation 为空或 `Available`；owner 字段为空；plan Secret 存在。不要手动删除 owner annotation 或 finalizer。

## 4. 识别每台主机的 300G/100G 磁盘

300G 系统盘应在 SeedImage 安装前通过稳定别名 `/dev/elemental-install-target` 指定。该路径不会自动选择最大盘，必须在每台服务器上确认其实际指向 300G 系统盘。

在主机上：

```bash
readlink -f /dev/elemental-install-target
lsblk -o NAME,SIZE,MODEL,SERIAL,WWN,FSTYPE,MOUNTPOINTS
```

100G 数据盘从 Inventory observer 报告中识别，不使用 `/dev/sdb`：

```bash
export BM_INVENTORY=olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137

kubectl -n "${BM_NS}" \
  get machineinventory.elemental.cattle.io "${BM_INVENTORY}" -o json \
  | jq -r '.status.observedStorage.devices[] |
      [.id,.kind,.systemRole,(.sizeBytes|tostring),(.filesystem.type//"-"),
       (.filesystem.uuid//"-"),([.mounts[].path]|join(","))] | @tsv'
```

只选择：

- `systemRole=Data`；
- 容量约 100G；
- 稳定 ID：`wwn:`、`nvme-eui:`、`nvme-nguid:`、observer 批准的 `serial:`、`partuuid:` 或 `wwid:`；
- 不是 system/Unknown、只读盘、multipath 成员、LVM/RAID/LUKS/swap 或意外挂载盘。

在主机确认 observer：

```bash
sudo systemctl is-enabled elemental-storage-observer.service
sudo systemctl is-active elemental-storage-observer.service
```

## 5. 为 100G `/var/cpaas` 准备 Storage v2

模板：`manifests/storage/storage.template.yaml`。

关键片段：

```yaml
storage:
  retryNonce: 0
  volumes:
    - name: cpaas-data
      source:
        deviceID: 填写当前Inventory观测到的100G稳定设备ID
        minimumSize: 90Gi
      filesystem:
        policy: InitializeIfBlank
        type: xfs
      mount:
        path: /var/cpaas
        required: true
        options: [noatime]
```

这里使用 `InitializeIfBlank`，前提是 100G 盘确实为空且允许格式化。如果已有文件系统或数据，必须改用 `Adopt` 并提供正确 `expectedUUID`。`/var/cpaas` 必须是 required volume。

每台 Inventory 分别执行。先准备变量：

```bash
export BM_INVENTORY=olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137
export BM_STORAGECTL=/实际/绝对路径/storagectl
export BM_STORAGE_FILE=/tmp/${BM_INVENTORY}-storage.yaml
export BM_INVENTORY_FILE=/tmp/${BM_INVENTORY}.json
export BM_PATCH_FILE=/tmp/${BM_INVENTORY}-storage.patch.json

cp manifests/storage/storage.template.yaml "${BM_STORAGE_FILE}"
# 编辑 BM_STORAGE_FILE，替换为这台主机的真实 100G stable deviceID
```

检查初始化权限：

```bash
kubectl auth can-i update \
  machineinventories.elemental.cattle.io \
  --subresource=storageinitialize -n "${BM_NS}"
```

必须返回 `yes`。

获取 live Inventory：

```bash
kubectl -n "${BM_NS}" \
  get machineinventory.elemental.cattle.io "${BM_INVENTORY}" -o json \
  > "${BM_INVENTORY_FILE}"
```

读取计数器：

```bash
jq '.status.storage.lastConsumedInitializationApprovalCounter // 0' \
  "${BM_INVENTORY_FILE}"
```

读取当前值后计算下一个计数器，用相同 Provider revision 的 `storagectl` 生成 patch：

```bash
export NEXT_COUNTER="$(jq -r '(.status.storage.lastConsumedInitializationApprovalCounter // 0) + 1' "${BM_INVENTORY_FILE}")"
printf 'NEXT_COUNTER=%s\n' "${NEXT_COUNTER}"
```

```bash
"${BM_STORAGECTL}" hash --storage "${BM_STORAGE_FILE}"

"${BM_STORAGECTL}" render-patch \
  --inventory "${BM_INVENTORY_FILE}" \
  --storage "${BM_STORAGE_FILE}" \
  --counter "${NEXT_COUNTER}" \
  > "${BM_PATCH_FILE}"
```

先 server-side dry-run：

```bash
kubectl -n "${BM_NS}" \
  patch machineinventory.elemental.cattle.io "${BM_INVENTORY}" \
  --type=merge --patch-file="${BM_PATCH_FILE}" \
  --dry-run=server -o yaml
```

确认 device ID、`/var/cpaas`、XFS、InitializeIfBlank 和 approval 正确后 apply：

```bash
kubectl -n "${BM_NS}" \
  patch machineinventory.elemental.cattle.io "${BM_INVENTORY}" \
  --type=merge --patch-file="${BM_PATCH_FILE}"
```

出现 resourceVersion 冲突时，重新 get live Inventory、重新 render patch、重新 dry-run；不要删 resourceVersion。

## 6. 等待三台 Storage Prepare 完成

```bash
kubectl -n "${BM_NS}" \
  get machineinventory "${BM_INVENTORY}" -o json \
  | jq '.status.storage | {
      phase,appliedSpecHash,pendingSpecHash,
      lastConsumedInitializationApprovalCounter,
      conditions,appliedVolumes,operation}'
```

加入 Pool 前每台都要满足 ACP 4.3.2 对应状态，通常为：

```text
phase=Prepared
StoragePrepared=True / AllRequiredVolumesPrepared
StorageActive=False / Inactive
operation=null
```

此时 100G 盘已准备但 `/var/cpaas` 尚未激活；分配给 BaremetalMachine 后才 Activate。

## 7. 创建 Control Plane Pool

文件：`manifests/02-workload-control-plane-pool.yaml`。已经填入截图中的三个真实 Inventory：

```yaml
inventoryRefs:
  - name: olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137
  - name: olvm-workloadcluster-d6bbbcff-a3c9-4aee-8e2b-e78eca996b12
  - name: olvm-workloadcluster-f785380f-a4d3-4bb6-a6b1-be5c253d7a62
```

确认三台 StoragePrepared 后执行：

```bash
kubectl apply \
  -f manifests/02-workload-control-plane-pool.yaml
kubectl -n cpaas-system \
  get machineinventorypool olvm-workloadcluster-control-plane-pool -o yaml
```

要求 Pool Ready/MembersValid，available 至少为 3。

## 8. 修改集群参数

### 8.1 API Endpoint

编辑 `manifests/03-workload-baremetal-cluster.yaml`：

```yaml
spec:
  controlPlaneLoadBalancer:
    type: External
    host: ${WORKLOAD_API_ENDPOINT}
    port: 6443
```

External LB 必须已创建 TCP 6443 listener，后端会是三台 Master。若使用 Internal VIP，必须按照 ACP 4.3.2 CRD 修改字段并确认 L2、VRID、VRRP、IPVS；不要直接 apply External 示例。

### 8.2 Registry 和 CIDR

编辑 `manifests/05-workload-cluster.yaml`：

```yaml
metadata:
  annotations:
    cpaas.io/registry-address: ${GLOBAL_REGISTRY}
    cpaas.io/kube-ovn-join-cidr: 100.15.0.0/16
spec:
  clusterNetwork:
    pods:
      cidrBlocks: [100.13.0.0/16]
    services:
      cidrBlocks: [100.14.0.0/16]
```

三个 CIDR 不得与 Global、物理网络、管理网、存储网或其他 Workload 冲突。

### 8.3 KCP

编辑 `manifests/06-workload-control-plane.yaml`：

```yaml
spec:
  replicas: 3
  version: v1.34.5
  rolloutStrategy:
    rollingUpdate:
      maxSurge: 0
```

必须替换：

- `manifests/06-workload-control-plane.yaml` 中的 SSH 公钥替换为 `${SSH_PUBLIC_KEY}` 的实际输出；
- `provider-id` 替换为 ACP 4.3.2 官方 Bare Metal Kubeadm 示例中的实际支持值；
- 按 ACP 4.3.2 正式 Kubeadm Provider 示例补齐/核对 `kubeadmConfigSpec`。

不能把这些占位符直接 apply。

## 9. 创建 Workload Control Plane

顺序执行：

```bash
kubectl apply \
  -f manifests/03-workload-baremetal-cluster.yaml
kubectl apply \
  -f manifests/04-workload-control-plane-machine-template.yaml
kubectl apply \
  -f manifests/05-workload-cluster.yaml
kubectl apply \
  -f manifests/06-workload-control-plane.yaml
```

检查：

```bash
kubectl -n cpaas-system get \
  baremetalcluster,cluster,kubeadmcontrolplane,machine,baremetalmachine
kubectl -n cpaas-system \
  get events --sort-by=.lastTimestamp
```

期待：

- BaremetalCluster Ready/EndpointReady；
- 三台 Inventory 被分配；
- reprovision plans Applied；
- storage 从 Prepared 进入 Active；
- `/var/cpaas` 在 kubelet 前挂载；
- KCP replicas=3；
- kubeconfig Secret 生成；
- 三台 Master Nodes Ready。

获取 Workload kubeconfig：

```bash
kubectl -n cpaas-system \
  get secret olvm-workloadcluster-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > workload-kubeconfig
kubectl --kubeconfig workload-kubeconfig get nodes -o wide
```

## 10. 验证 `/var/cpaas`

三台 Master Ready 后，在每台主机验证：

```bash
findmnt /var/cpaas
lsblk -f
mount | grep /var/cpaas
df -h /var/cpaas
```

在 Global 验证 Inventory：

```bash
kubectl -n cpaas-system \
  get machineinventory "${BM_INVENTORY}" -o json \
  | jq '.status.storage | {phase,conditions,appliedVolumes,operation}'
```

期待：storage phase `Active`、StorageActive=True，并且 BaremetalMachine storage Ready（实际字段以 ACP 4.3.2 CRD 为准）。

## 11. 添加 Worker（物理机就绪后）

依次使用：

```text
manifests/07-worker-registration-seedimage.yaml
manifests/08-worker-pool.yaml
manifests/09-worker-machine-template.yaml
manifests/10-worker-kubeadm-config-template.yaml
manifests/11-worker-machine-deployment.yaml
```

流程与 Master 一致：SeedImageReady → ISO 启动 → MachineInventory → 可选 Storage Prepare → Worker Pool → Template/ConfigTemplate/MachineDeployment。

Worker 创建前必须替换 Worker Inventory、SSH key 和 provider-id 占位符。

## 12. 停止条件

出现以下任一情况停止，不继续 apply 后续资源：

- `/dev/elemental-install-target` 未明确指向 300G 系统盘；
- 无法识别三个 100G `systemRole=Data` 的稳定设备 ID；
- `storagectl` 与 Provider revision 不匹配；
- storageinitialize 权限不是 `yes`；
- server dry-run 失败；
- 任一 Inventory 未达到 Prepared；
- Pool available 小于 3；
- Registry、Image Catalog、LB、CIDR 或 provider-id 未确认；
- `grep -RInE '<[^>]+>|填写实际|PROVIDER_ID' manifests rendered` 有任何输出。

## 13. Apply 前逐机与网络检查清单

### 13.1 [Global Master 01] 执行

```bash
hostname
kubectl cluster-info
kubectl -n cpaas-system get configmap elemental-image-catalog -o yaml
kubectl -n cpaas-system get machineinventories.elemental.cattle.io -o wide
kubectl -n cpaas-system get machineinventorypool -o wide
```

确认：当前是 Global Master 01；Image Catalog 有 v1.34.5；三台 Master Inventory 名字与 Pool YAML 完全一致；Inventory 未分配且 storage Prepared。

检查 YAML 中仍未替换的值：

```bash
grep -RInE '<[^>]+>|填写实际|PROVIDER_ID' manifests rendered 2>/dev/null
```

有任何输出都停止 apply。逐个阅读将要 apply 的 YAML：

```bash
for file in \
  manifests/02-workload-control-plane-pool.yaml \
  manifests/03-workload-baremetal-cluster.yaml \
  manifests/04-workload-control-plane-machine-template.yaml \
  manifests/05-workload-cluster.yaml \
  manifests/06-workload-control-plane.yaml
do
  echo "===== ${file} ====="
  kubectl apply --dry-run=server -f "${file}"
done
```

### 13.2 [三台 Master 都执行]

分别登录每一台裸金属 Master，三台都执行：

```bash
hostname
readlink -f /dev/elemental-install-target
lsblk -o NAME,SIZE,MODEL,SERIAL,WWN,FSTYPE,MOUNTPOINTS
sudo systemctl is-enabled elemental-storage-observer.service
sudo systemctl is-active elemental-storage-observer.service
timedatectl
chronyc tracking
```

逐台确认：

- `/dev/elemental-install-target` 最终指向 300G 系统盘；
- 100G 数据盘不是系统盘，且其真实 WWN/serial 与 Global 中 observedStorage 一致；
- observer enabled/active；
- 时区一致，三台时间误差不超过 10 秒；
- 100G 盘确实为空并批准 InitializeIfBlank，或者切换为 Adopt；
- 没有把任何已有业务数据盘误选为安装盘或初始化盘。

### 13.3 [LB/DNS 管理端] 执行

在负载均衡器上创建并检查：

```text
Frontend: 实际 Workload API VIP/FQDN:6443
Protocol: TCP passthrough
Backends: 三台 Master 节点 IP:6443
Health check: 根据客户 LB 能力和 Kubernetes API TCP 检查策略
```

在 DNS 管理端创建 FQDN → VIP 解析。在 Global Master 01 验证：

```bash
getent hosts "${WORKLOAD_API_ENDPOINT}"
nc -vz "${WORKLOAD_API_ENDPOINT}" 6443
```

在 KCP 启动前，TCP 6443 可能因为后端尚未监听而失败，但 DNS 必须解析到正确 VIP；KCP 启动后必须成功。

### 13.4 [Global Master 01] 创建 CP 后执行

```bash
kubectl -n cpaas-system get baremetalcluster,cluster,kubeadmcontrolplane,machine,baremetalmachine -o wide
kubectl -n cpaas-system get events --sort-by=.lastTimestamp
kubectl -n cpaas-system get secret olvm-workloadcluster-kubeconfig
```

检查三台 Inventory 的 storage/plan：

```bash
for inventory in \
  olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137 \
  olvm-workloadcluster-d6bbbcff-a3c9-4aee-8e2b-e78eca996b12 \
  olvm-workloadcluster-f785380f-a4d3-4bb6-a6b1-be5c253d7a62
do
  echo "===== ${inventory} ====="
  kubectl -n cpaas-system get machineinventory "${inventory}" -o json \
    | jq '{plan:.status.plan,storage:.status.storage,conditions:.status.conditions}'
done
```

### 13.5 [三台 Master 都执行] CP Ready 后验证

```bash
hostname
findmnt /var/cpaas
lsblk -f
df -h /var/cpaas
systemctl is-active kubelet
systemctl is-active containerd
```

三台都必须看到 100G XFS 数据盘挂载到 `/var/cpaas`，kubelet/containerd active。

### 13.6 [Global Master 01，使用 Workload kubeconfig] 最终验证

```bash
kubectl -n cpaas-system get secret olvm-workloadcluster-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > workload-kubeconfig
kubectl --kubeconfig workload-kubeconfig get nodes -o wide
kubectl --kubeconfig workload-kubeconfig get pods -A
```
