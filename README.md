# Mandiri Bare Metal Workload Cluster

本项目继续完成已经启动的 `olvm-workloadcluster` 裸金属业务集群部署。

## 当前状态

版本以官方 OS 支持矩阵为准（ACP `v4.3.2`）：

```text
ACP:            v4.3.2
Kubernetes:     v1.34.5-3
etcd:           v3.5.28-260625
containerd:     2.2.1-5
coredns:        1.14.2-v4.3.11
pause:          3.10
kube-ovn chart: v4.3.11
OS image tag:   v4.3.2-1-1.34.5-3
```

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

磁盘规划（研发确认口径）：

```text
部署阶段只规划系统盘。
多盘主机用 /dev/elemental-install-target 固定系统盘 WWN。
额外数据盘不在 MachineInventory.spec.storage 里提前声明。
集群 Ready 后，再登录节点手工挂载数据盘。
后续 OS/集群升级不依赖这块数据盘规划。
```

> 重要：所有部署操作均按本文逐步手工执行，不依赖任何辅助脚本。现场真实 Registry 和 SSH 公钥必须先按本文命令取得，再直接编辑对应 YAML。External LB VIP 已确定为 `10.243.166.12`。未完成第 13 节检查前禁止 apply。

## 1. 执行位置和责任矩阵

本文所有命令都明确标注执行位置：

| 标记 | 在哪里执行 | 用途 |
|---|---|---|
| **[Global Master 01]** | `global-master01`，当前 `kubectl` 已连接 Global | 查询/修改 Kubernetes 资源、检查 MachineInventory、apply 集群 YAML |
| **[三台 Master 都执行]** | 三台已注册的裸金属 Master 本机/BMC Console | 核对 ISO 已弹出、从系统盘启动、系统盘挂载正常；集群 Ready 后再手工挂数据盘 |
| **[LB 管理端]** | 客户负载均衡器管理界面 | 核对 External LB VIP `10.243.166.12`、TCP 6443 listener 和三台 Master 后端 |
| **[Workload kubeconfig]** | Global Master 01，但显式使用生成的 `workload-kubeconfig` | 检查业务集群 Node/Pod |

### 1.1 在 Global Master 01 执行

```bash
hostname
kubectl config current-context
kubectl cluster-info
kubectl get nodes -o wide

export BM_NS=cpaas-system
export CLUSTER_NAME=olvm-workloadcluster
export ACP_VERSION=v4.3.2
export KUBERNETES_VERSION=v1.34.5-3
export ETCD_VERSION=v3.5.28-260625
export OS_IMAGE_TAG=v4.3.2-1-1.34.5-3
```

`hostname` 必须确认当前是 `global-master01`；`kubectl cluster-info` 必须指向现有 Global。本文不需要额外 kubeconfig 路径。

读取 Global Registry：

```bash
export GLOBAL_REGISTRY="$(kubectl -n cpaas-system get cluster global \
  -o jsonpath='{.metadata.annotations.cpaas\.io/registry-address}')"
export BASE_IMAGE=${GLOBAL_REGISTRY}/tkestack/baremetal-base-image:${OS_IMAGE_TAG}
export BASE_IMAGE_ISO=${GLOBAL_REGISTRY}/tkestack/baremetal-base-image-iso:${OS_IMAGE_TAG}
printf 'GLOBAL_REGISTRY=%s\n' "${GLOBAL_REGISTRY}"
```

如果输出为空，停止执行，先确认 Global 的实际 Registry 配置。

### 1.2 在 LB 管理端完成

本方案选择 **External LB**。现场已经配置 Workload API VIP `10.243.166.12` 和 TCP 6443 转发：

```text
Protocol: TCP passthrough
Frontend: 10.243.166.12:6443
Backends: 三台裸金属 Master 的节点 IP:6443
```

如果后续需要使用 FQDN，可另行创建 FQDN 到 `10.243.166.12` 的 DNS 解析；本次部署直接使用 VIP，不依赖 DNS。部署时在 Global Master 01 记录该入口：

```bash
export WORKLOAD_API_ENDPOINT='10.243.166.12'
```

后续 `BaremetalCluster` 和连通性检查均使用该 VIP。

### 1.3 Global Master 01 上的 SSH 公钥

使用已有公钥：

```bash
export SSH_PUBLIC_KEY_FILE="$(find /root/.ssh -maxdepth 1 -type f -name '*.pub' -print -quit)"
test -n "${SSH_PUBLIC_KEY_FILE}" || { echo '没有找到 /root/.ssh/*.pub'; exit 1; }
export SSH_PUBLIC_KEY="$(tr -d '\n' < "${SSH_PUBLIC_KEY_FILE}")"
printf 'SSH_PUBLIC_KEY_FILE=%s\n' "${SSH_PUBLIC_KEY_FILE}"
```

### 1.4 手工填写 YAML 的规则

本项目不使用渲染或部署脚本。所有修改都在 **Global Master 01** 上手工完成，并在 apply 前逐个检查。

先记录后续要写入 YAML 的现场值：

```bash
printf 'Global Registry: %s\n' "${GLOBAL_REGISTRY}"
printf 'SSH public key file: %s\n' "${SSH_PUBLIC_KEY_FILE}"
printf 'Workload API VIP: 10.243.166.12\n'
```

需要手工修改的文件和字段：

| 文件 | 要修改或确认的字段 | 值的来源 |
|---|---|---|
| `manifests/01-workload-registration-seedimage.yaml` | `SeedImage.spec.baseImage` | `${GLOBAL_REGISTRY}/tkestack/baremetal-base-image-iso:v4.3.2-1-1.34.5-3` |
| `manifests/03-workload-baremetal-cluster.yaml` | `spec.controlPlaneLoadBalancer.host` | 已填写 `10.243.166.12` |
| `manifests/05-workload-cluster.yaml` | `metadata.annotations.cpaas.io/registry-address` | `${GLOBAL_REGISTRY}` 的实际输出 |
| `manifests/06-workload-control-plane.yaml` | `sshAuthorizedKeys` | `${SSH_PUBLIC_KEY}` 的实际完整输出 |
| 多盘主机系统盘 | Live ISO 上的 `/dev/elemental-install-target` | 该主机系统盘的 `/dev/disk/by-id/wwn-*` |

在 Global Master 01 上使用 `vi` 或 `vim` 逐个编辑，例如：

```bash
vi manifests/05-workload-cluster.yaml
vi manifests/06-workload-control-plane.yaml
```

编辑时把实际文本写进 YAML，不要把 `${GLOBAL_REGISTRY}`、`${SSH_PUBLIC_KEY}` 这些 shell 变量名写进 YAML。保存后逐个检查：

```bash
kubectl apply --dry-run=server -f manifests/05-workload-cluster.yaml
kubectl apply --dry-run=server -f manifests/06-workload-control-plane.yaml
```

`01` 是已经完成注册时使用的定义；只有在现场需要重建 Registration/SeedImage 时才 apply。当前三台 Master 已注册，正常续接部署不重复 apply `01`。

## 2. 先确认 Image Catalog

```bash
kubectl \
  -n cpaas-system get configmap elemental-image-catalog -o yaml
```

应有：

```yaml
data:
  v1.34.5-3: ${GLOBAL_REGISTRY}/tkestack/baremetal-base-image:v4.3.2-1-1.34.5-3
```

如果没有，使用 merge patch，保留已有版本：

```bash
kubectl \
  -n cpaas-system patch configmap elemental-image-catalog \
  --type merge \
  -p "{\"data\":{\"${KUBERNETES_VERSION}\":\"${BASE_IMAGE}\"}}"
```

`elemental-image-catalog` 使用 `base-image`；SeedImage 使用 `base-image-iso`。

## 3. SeedImage 安装后必须检查 OS 是否正常

三台 Master 已经从 SeedImage 安装并注册。加入 Pool 前，先确认每台机器已经离开 Live ISO，并从系统盘正常启动。

现场常见坑：ISO 没弹出、启动项仍指向虚拟光驱、或 Inventory 上看不到正常磁盘布局。这类主机不要加入 Pool。

### 3.1 [BMC] 安装触发重启后立即处理启动项

每台物理机安装完成后会 reboot。在 BMC/iDRAC/iLO 上逐台执行：

1. 弹出/卸载 SeedImage 虚拟介质（虚拟 CD/ISO）。
2. 把启动顺序改回 disk-first，不要继续从虚拟光驱启动。
3. 确认下一次启动进入已安装的 Alauda OS，而不是再次进入 Live ISO。

不要在仍挂着 ISO 的情况下检查 MachineInventory 是否 Ready。

### 3.2 [三台 Master 都执行] 确认已经不是 Live ISO

登录已安装系统，不要登录 Live ISO 控制台：

```bash
hostname
findmnt -n -o SOURCE,FSTYPE,TARGET /
findmnt /run/initramfs/live || echo NO_LIVE_ISO_ROOT
lsblk -e7 -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,WWN,FSTYPE,LABEL,MOUNTPOINTS
```

必须同时满足：

- `/` 不是 `LiveOS_rootfs`。
- 没有 `/run/initramfs/live` 这类 Live ISO root。
- 虚拟光驱（常见 `/dev/sr0`）上不应再挂着 `COS_LIVE` 作为当前运行系统。
- 系统盘上能看到 Elemental 分区布局，例如 `COS_STATE` / `COS_OEM` / `COS_RECOVERY` / `COS_PERSISTENT`。
- 额外数据盘可以存在，但这一步不要格式化，也不要挂到业务路径。

如果 `/` 仍是 Live ISO，停止。回到 BMC 弹出 ISO，改启动项，再重启。

### 3.3 [Global Master 01] 检查 MachineInventory

```bash
kubectl -n cpaas-system get machineinventories.elemental.cattle.io -o wide

for inventory in \
  olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137 \
  olvm-workloadcluster-d6bbbcff-a3c9-4aee-8e2b-e78eca996b12 \
  olvm-workloadcluster-f785380f-a4d3-4bb6-a6b1-be5c253d7a62
do
  echo "===== ${inventory} ====="
  kubectl -n cpaas-system describe machineinventory.elemental.cattle.io "${inventory}"
done
```

每台都要满足：

- `Ready=True`
- 报告了预期网络/IP
- 只有一套当前 Elemental 磁盘布局
- allocation 为空或 `Available`
- owner 字段为空
- plan Secret 存在

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

不要手动删除 owner annotation 或 finalizer。某些 Inventory 在 ISO 未卸载、仍从虚拟光驱启动时，会看不到正常磁盘挂载/布局。这类 Inventory 不要加入 Pool。

## 4. 多盘主机只固定系统盘

官方文档：<https://docs.alauda.cn/immutable-infra/1.0/how-to/configure-fixed-install-disk-bare-metal.html>

研发确认：部署阶段不单独规划额外数据盘。有多块磁盘、大小不同时，只需要用 WWN 把门禁指到系统盘。数据盘等集群起来后，再登录节点手工挂载；后续升级不受影响。

不要把 `MachineRegistration.spec.config.elemental.install.device` 留空，也不要用 `/dev/sda`。空 device 会让 Elemental 自动选盘；`/dev/sda` 在 Live ISO 和已安装系统之间可能互换。

共享 ISO 使用同一个不存在的路径：

```yaml
spec:
  config:
    elemental:
      install:
        device: /dev/elemental-install-target
        eject-cd: true
        reboot: true
```

Live ISO 启动后，该路径故意不存在，安装服务不会自动选盘。每台主机在 Live ISO 控制台里，把这个路径链到该主机系统盘的 WWN。

### 4.1 [三台 Master 都执行] 在 Live ISO 上创建安装目标

清理并确认目标整盘后：

```bash
ls -l /dev/disk/by-id/wwn-*
lsblk -d -e7 -o NAME,PATH,SIZE,MODEL,SERIAL,WWN,HCTL

test ! -e /dev/elemental-install-target
test ! -L /dev/elemental-install-target

ln -s \
  /dev/disk/by-id/wwn-把这里换成该主机系统盘的实际WWN \
  /dev/elemental-install-target

readlink -f /dev/elemental-install-target
test -b /dev/elemental-install-target && echo TARGET_IS_BLOCK
lsblk -d -o NAME,PATH,SIZE,MODEL,SERIAL,WWN,HCTL \
  "$(readlink -f /dev/elemental-install-target)"
```

确认输出的是系统盘，不是数据盘。这个符号链接只存在于当前 Live ISO 会话，重启后会消失；已安装系统正常启动不需要它。

当前三台 Master 如果已经完成安装并离开 Live ISO，不要再回 Live ISO 重建这个链接。本节只用于复查或重装。

## 5. 数据盘放到集群 Ready 之后

本方案部署阶段不使用 Storage v2 / `storagectl` 提前声明数据盘，也不把 `/var/cpaas` 作为加入 Pool 的前置条件。

原因：

- 系统盘由 `/dev/elemental-install-target` 固定即可。
- 额外数据盘可以等节点加入集群后再在节点上挂载。
- 研发确认这种后挂方式不影响后续升级。

`manifests/storage/` 仅保留作可选参考，不是当前部署必做步骤。

## 6. 加入 Pool 前的 Inventory 结论

三台都 `Ready=True`，且已确认从系统盘启动后，才能创建 Pool。不要等待 StoragePrepared。

## 7. 创建 Control Plane Pool

文件：`manifests/02-workload-control-plane-pool.yaml`。已经填入三个真实 Inventory：

```yaml
inventoryRefs:
  - name: olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137
  - name: olvm-workloadcluster-d6bbbcff-a3c9-4aee-8e2b-e78eca996b12
  - name: olvm-workloadcluster-f785380f-a4d3-4bb6-a6b1-be5c253d7a62
```

确认三台 Inventory Ready、ISO 已弹出、并从系统盘启动后执行：

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
    host: 10.243.166.12
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

把 `${GLOBAL_REGISTRY}` 换成第 1.1 节实际输出。三个 CIDR 不得与 Global、物理网络、管理网、存储网或其他 Workload 冲突。

### 8.3 KCP

文件：`manifests/06-workload-control-plane.yaml`。

这是官方 ACP 4.3.2 Bare Metal 全量 `KubeadmControlPlane`。已填入本项目固定值：

- `version: v1.34.5-3`
- `dns.imageTag: 1.14.2-v4.3.11`
- `etcd.local.imageTag: v3.5.28-260625`
- `machineTemplate.infrastructureRef.name: olvm-workloadcluster-control-plane-machine-template`

apply 前只替换 SSH 公钥：

```yaml
sshAuthorizedKeys:
  - "<ssh-authorized-keys>"
```

把 Global Master 01 上 `/root/.ssh/*.pub` 的完整一行公钥写进去。官方这份 YAML 使用 `node-labels: kube-ovn/role=master`，不再使用自定义 `provider-id` 占位符。

不能把 `<ssh-authorized-keys>` 直接 apply。

官方“步骤 3：创建控制平面集群资源”对应本项目 4 个文件，必须按下面顺序创建：

| 官方资源 | 本项目文件 | 作用 |
|---|---|---|
| `BaremetalCluster` | `manifests/03-workload-baremetal-cluster.yaml` | 声明 Workload API 入口。本方案用 `External`，VIP 为 `10.243.166.12:6443` |
| `BaremetalMachineTemplate` | `manifests/04-workload-control-plane-machine-template.yaml` | 指向控制平面 Pool，决定从哪 3 台已注册 Inventory 分配 Master |
| `Cluster` | `manifests/05-workload-cluster.yaml` | CAPI 总对象，把 BaremetalCluster 和 KubeadmControlPlane 绑在一起 |
| `KubeadmControlPlane` | `manifests/06-workload-control-plane.yaml` | 声明 3 个 Master 副本、Kubernetes 版本和 kubeadm 配置 |

本方案选择 `External`，不是 `Internal`：

- `External`：provider 不部署 Alive，不接管 VIP。客户 LB 维护 `10.243.166.12:6443` 以及三台 Master 后端。
- `Internal`：provider 部署 Alive，并自己协调 VIP 和后端。本次不使用。

前置条件：`manifests/02-workload-control-plane-pool.yaml` 必须已经 apply，并且 Pool Ready。`02` 不是官方第 3 步里的 4 个资源之一，但没有它，`BaremetalMachineTemplate` 无法从 Pool 分配机器。

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

## 10. 集群 Ready 后按需挂载数据盘

三台 Master Node Ready 后，如果业务需要使用额外磁盘，再登录节点手工挂载。这一步不是创建 Cluster/KCP 的前置条件，也不影响后续 OS 升级。

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,WWN,FSTYPE,LABEL,MOUNTPOINTS
findmnt /
```

确认系统盘已经挂着 Elemental 分区。数据盘保持独立，按现场需求挂到业务路径。不要把数据盘重新做成系统盘。

## 11. 添加 Worker（物理机就绪后）

依次使用：

```text
manifests/07-worker-registration-seedimage.yaml
manifests/08-worker-pool.yaml
manifests/09-worker-machine-template.yaml
manifests/10-worker-kubeadm-config-template.yaml
manifests/11-worker-machine-deployment.yaml
```

流程与 Master 一致：SeedImageReady → ISO 启动 → 弹出 ISO/改启动项 → 确认已安装 OS → 检查 MachineInventory Ready → Worker Pool → Template/ConfigTemplate/MachineDeployment。数据盘等节点 Ready 后再手工挂载。

Worker 创建前必须替换 Worker Inventory 和 SSH 公钥。

## 12. 停止条件

出现以下任一情况停止，不继续 apply 后续资源：

- 主机仍从 SeedImage/ISO 启动，BMC 未弹出虚拟介质；
- `/` 仍是 Live ISO，或看不到 `COS_STATE` 等已安装系统布局；
- 任一 MachineInventory 不是 `Ready=True`，或看不到正常磁盘布局；
- 多盘重装时 `/dev/elemental-install-target` 未明确指向系统盘；
- server dry-run 失败；
- Pool available 小于 3；
- Registry、Image Catalog、LB、CIDR 或 SSH 公钥未确认；
- 要 apply 的 YAML 中仍存在 `<...>`、`填写实际` 或 `PROVIDER_ID` 占位内容。

## 13. Apply 前逐机与网络检查清单

### 13.1 [Global Master 01] 执行

```bash
hostname
kubectl cluster-info
kubectl -n cpaas-system get configmap elemental-image-catalog -o yaml
kubectl -n cpaas-system get machineinventories.elemental.cattle.io -o wide
kubectl -n cpaas-system get machineinventorypool -o wide
```

确认：当前是 Global Master 01；Image Catalog 有 `v1.34.5-3`；三台 Master Inventory 名字与 Pool YAML 完全一致；Inventory Ready、未分配，并且已经从系统盘启动。

检查 YAML 中仍未替换的值：

```bash
grep -nE '<[^>]+>|填写实际|PROVIDER_ID' \
  manifests/02-workload-control-plane-pool.yaml \
  manifests/03-workload-baremetal-cluster.yaml \
  manifests/04-workload-control-plane-machine-template.yaml \
  manifests/05-workload-cluster.yaml \
  manifests/06-workload-control-plane.yaml
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
findmnt -n -o SOURCE,FSTYPE,TARGET /
findmnt /run/initramfs/live || echo NO_LIVE_ISO_ROOT
lsblk -e7 -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,WWN,FSTYPE,LABEL,MOUNTPOINTS
timedatectl
chronyc tracking
```

逐台确认：

- 当前不是 Live ISO，已经从系统盘启动；
- 能看到 Elemental 系统分区布局；
- ISO/虚拟光驱已卸载，启动项不是虚拟 CD；
- 时区一致，三台时间误差不超过 10 秒；
- 没有把数据盘误当成系统盘。

### 13.3 [LB 管理端] 执行

现场已完成转发配置，部署前重新核对：

```text
Frontend: 10.243.166.12:6443
Protocol: TCP passthrough
Backends: 三台 Master 节点 IP:6443
Health check: 根据客户 LB 能力使用 Kubernetes API TCP 检查策略
```

在 Global Master 01 验证 VIP：

```bash
nc -vz 10.243.166.12 6443
```

在 KCP 启动前，因为后端尚未监听，TCP 6443 检查可能失败；KCP 启动后必须成功。若配置了 FQDN，再额外用 `getent hosts <实际FQDN>` 确认其解析为 `10.243.166.12`。

### 13.4 [Global Master 01] 创建 CP 后执行

```bash
kubectl -n cpaas-system get baremetalcluster,cluster,kubeadmcontrolplane,machine,baremetalmachine -o wide
kubectl -n cpaas-system get events --sort-by=.lastTimestamp
kubectl -n cpaas-system get secret olvm-workloadcluster-kubeconfig
```

检查三台 Inventory 的 Ready/plan：

```bash
for inventory in \
  olvm-workloadcluster-2859b4f7-a97f-4f3b-a5c3-aad410030137 \
  olvm-workloadcluster-d6bbbcff-a3c9-4aee-8e2b-e78eca996b12 \
  olvm-workloadcluster-f785380f-a4d3-4bb6-a6b1-be5c253d7a62
do
  echo "===== ${inventory} ====="
  kubectl -n cpaas-system get machineinventory.elemental.cattle.io "${inventory}" -o json \
    | jq '{conditions:.status.conditions,plan:.status.plan}'
done
```

### 13.5 [三台 Master 都执行] CP Ready 后验证

```bash
hostname
findmnt -n -o SOURCE,FSTYPE,TARGET /
lsblk -f
systemctl is-active kubelet
systemctl is-active containerd
```

三台都必须从系统盘启动，kubelet/containerd active。数据盘不是这一步的成功标准。

### 13.6 [Global Master 01，使用 Workload kubeconfig] 最终验证

```bash
kubectl -n cpaas-system get secret olvm-workloadcluster-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > workload-kubeconfig
kubectl --kubeconfig workload-kubeconfig get nodes -o wide
kubectl --kubeconfig workload-kubeconfig get pods -A
```
