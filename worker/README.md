# Worker

官方：[Worker Node Deployment](https://docs.alauda.cn/immutable-infra/1.0/manage-nodes/bare-metal.html#worker-node-deployment)

每个集群默认 1 台 Worker。必须用本目录自己的 Registration/ISO，不要挂控制面那张。不要改 `BaremetalCluster.spec.networkDevice`（Master 继续 `eth0`）。

先确认控制面已经起来：

```bash
kubectl --kubeconfig workload-kubeconfig get nodes -o wide
kubectl -n cpaas-system get kubeadmcontrolplane olvm-workloadcluster-control-plane
kubectl -n cpaas-system get configmap elemental-image-catalog -o yaml
```

三台 Master Ready；catalog 有 `v1.34.5-3`。

---

## 1. Worker Registration / SeedImage

文件：`worker/manifests/01-registration-seedimage.yaml`

一般不用改。确认这两处即可：

```yaml
# MachineRegistration
spec:
  config:
    elemental:
      install:
        device: /dev/elemental-install-target   # 通用参数，写进 ISO；真实盘符到 Live ISO 上软链接
```

```yaml
# SeedImage
spec:
  baseImage: 10.243.166.5:11443/tkestack/baremetal-base-image-iso:v4.3.2-1-1.34.5-3
```

不要改 `${System Information/UUID}` 这类 Elemental 表达式。

```bash
grep -nE '<[^>]+>|填写实际' worker/manifests/01-registration-seedimage.yaml
kubectl apply --dry-run=server -f worker/manifests/01-registration-seedimage.yaml
kubectl apply -f worker/manifests/01-registration-seedimage.yaml
kubectl -n cpaas-system describe seedimage olvm-workloadcluster-worker-registration-iso
```

`SeedImageReady=True` 后再下载 ISO、挂到这台 Worker 的虚拟光驱。

---

## 2. [Worker BMC + Live ISO] 系统盘软链接 + VLAN 329

1. BMC 挂 Worker ISO，从虚拟光驱进 Live ISO。
2. 认盘并软链接（`/dev/sda` 换成 `lsblk` 确认的系统盘）：

```bash
lsblk -d -e7 -o NAME,PATH,SIZE,MODEL,SERIAL,WWN,HCTL
ln -s /dev/sda /dev/elemental-install-target
readlink -f /dev/elemental-install-target
```

有旧系统分区时，先对系统盘 `wipefs -a` / `sgdisk -Z`，不要动 `sr*` / `loop*`。

3. **先配 VLAN，再让主机注册。** IP 配在 `eth0.329`，不要配在 `eth0`。不要用 VIP `10.243.166.12`。

```bash
sudo nmcli con add type vlan ifname eth0.329 con-name vlan329 \
  dev eth0 id 329
sudo nmcli con mod vlan329 \
  ipv4.method manual \
  ipv4.addresses 10.243.166.6/26 \     # 占用则换同网段空闲地址
  ipv4.gateway 10.243.166.1 \
  ipv4.dns 10.243.132.38 \
  ipv6.method ignore
sudo nmcli con up vlan329
ping -c 3 10.243.166.1
ip -br addr show eth0.329
```

现场跑通的另一组参考（那台机器当时用的地址/DNS）：

```text
10.243.166.31/26    gateway 10.243.166.1    dns 8.8.8.8
```

`networkDevice` 填接口名 `eth0.329`，不要填 connection 名 `vlan329`。

单口不通、交换机已把 eth0/eth1 绑成一组时，改 bond + `bond0.329`（active-backup），并把第 4 步那一台改成 `networkDevice: bond0.329`。

4. 等安装自动重启 → BMC 弹出 ISO → 启动项 disk-first。

5. 登录已安装系统确认不是 Live ISO，能看到 `COS_STATE` 等分区。

---

## 3. 检查 Worker Inventory

```bash
kubectl -n cpaas-system get machineinventories.elemental.cattle.io -o wide
```

名字由 Elemental 生成，形如 `olvm-workloadcluster-worker-<UUID>`。必须 `Ready=True`、已从系统盘启动、allocation 为空或 `Available`。

把真实名字记下来，替换下面的 `<actual-worker-inventory-1>`。

---

## 4. Worker Pool

文件：`worker/manifests/02-worker-pool.yaml`

只改这一台的真实 Inventory 名；VLAN 接口名以 `observedNetwork` 为准：

```yaml
spec:
  clusterName: olvm-workloadcluster
  machineInventories:
    - name: <actual-worker-inventory-1>     # 换成第 3 步查到的真实名字
      hostname: olvm-workloadcluster-worker01
      networkDevice: eth0.329               # observedNetwork 不是这个名字时只改这一台
```

```bash
grep -nE '<[^>]+>|填写实际' worker/manifests/02-worker-pool.yaml
kubectl apply --dry-run=server -f worker/manifests/02-worker-pool.yaml
kubectl apply -f worker/manifests/02-worker-pool.yaml
kubectl -n cpaas-system get machineinventorypool olvm-workloadcluster-worker-pool
```

要求 `status.available ≥ 1`。名字还是占位就不要 apply。

---

## 5. Worker MachineTemplate

文件：`worker/manifests/03-worker-machine-template.yaml`

已指向 `olvm-workloadcluster-worker-pool`，不用改。

```bash
kubectl apply --dry-run=server -f worker/manifests/03-worker-machine-template.yaml
kubectl apply -f worker/manifests/03-worker-machine-template.yaml
```

这个模板创建后，pool 引用视为不可变。要换 Pool 必须新建模板名字。

---

## 6. Worker Bootstrap

文件：`worker/manifests/04-worker-kubeadm-config-template.yaml`

只改这一处：

```yaml
sshAuthorizedKeys:
  - "<ssh-authorized-keys>"       # 换成真实公钥（与控制面 KCP 同一把）
```

不要预填 hostname、`provider-id`、`criSocket`。`node-labels: kube-ovn/role=worker` 保留。

```bash
grep -nE '<[^>]+>|填写实际|provider-id' worker/manifests/04-worker-kubeadm-config-template.yaml
kubectl apply --dry-run=server -f worker/manifests/04-worker-kubeadm-config-template.yaml
kubectl apply -f worker/manifests/04-worker-kubeadm-config-template.yaml
```

还有 `<...>` 就停止。

---

## 7. MachineDeployment

文件：`worker/manifests/05-worker-machine-deployment.yaml`

已按官方填好，一般不用改：

```yaml
spec:
  clusterName: olvm-workloadcluster
  replicas: 1                       # 加第二台时再提高，且 ≤ pool available+allocated
  version: v1.34.5-3
  strategy:
    rollingUpdate:
      maxSurge: 0                   # 裸金属不能超配
      maxUnavailable: 1
```

```bash
grep -nE '<[^>]+>|填写实际' worker/manifests/05-worker-machine-deployment.yaml
kubectl apply --dry-run=server -f worker/manifests/05-worker-machine-deployment.yaml
kubectl apply -f worker/manifests/05-worker-machine-deployment.yaml
kubectl -n cpaas-system get machinedeployments.cluster.x-k8s.io
kubectl --kubeconfig workload-kubeconfig get nodes -o wide
```

期待：1 台 Worker Node Ready，带 `kube-ovn/role=worker`。

---

## 8. 额外目录需要单独挂载时

本项目不包含存储 YAML。如果业务还要把一块独立磁盘挂到额外目录（例如 `/data`，或根下其它路径），按官方文档在对应 `MachineInventory` 上配置：

<https://docs.alauda.cn/immutable-infra/1.0/how-to/manage-bare-metal-storage.html>

---

## 9. 常见问题

### 9.1 默认网卡 / 默认 IP 配不上，网卡要带 VLAN

**现象：** 客户给的不是裸 `eth0` 和普通静态 IP。Live ISO 上若把 IP 配在 `eth0`，或没建 VLAN 接口，注册后 `observedNetwork` 对不上，Pool 的 `networkDevice: eth0.329` 也无法作为 CNI 网卡。

**适用：** **[Worker BMC Console]**，Live ISO 起来后、Elemental 安装开始前。Master 已经按 `eth0` 跑了，不要改 `BaremetalCluster.spec.networkDevice`。VLAN 写在主机 NetworkManager 上，不写进 Registration YAML。

**可以做：** 只在物理口 `eth0` 上建 VLAN 329，接口名 `eth0.329`，静态 IPv4 配在这个 VLAN 口上。下面是现场跑通的参考；地址、DNS 按这台机器改，不要原样抄到另一台。

**不要做：**

- 不要把 IP 配在 `eth0` 上。
- 不要把 connection 名 `vlan329` 填进 Pool 的 `networkDevice`；填接口名 `eth0.329`。
- 不要用 VIP `10.243.166.12`。
- 交换机没有把 eth0/eth1 绑成一组时，不要走 `bond0.329`。
- 不要对 `sr*`、`loop*` 动手。

```bash
# 如果上次误建了 bond，先拆掉，再配单网卡 VLAN
sudo nmcli con down vlan329 2>/dev/null || true
sudo nmcli con down bond0 2>/dev/null || true
sudo nmcli con delete vlan329 bond0 bond0-port1 bond0-port2 2>/dev/null || true

# 只在 eth0 上做 VLAN 329；IP 必须在 eth0.329，不是 eth0
sudo nmcli con add type vlan ifname eth0.329 con-name vlan329 \
  dev eth0 id 329

sudo nmcli con mod vlan329 \
  ipv4.method manual \
  ipv4.addresses 10.243.166.31/26 \
  ipv4.gateway 10.243.166.1 \
  ipv4.dns 8.8.8.8 \
  ipv6.method ignore

sudo nmcli con up vlan329
ping -c 3 10.243.166.1
ip -br addr show eth0.329
ls /etc/NetworkManager/system-connections/
nmcli -f NAME,UUID,TYPE,DEVICE,FILENAME connection show
```

成功标准：`eth0.329` 有这台机器的地址；能 ping 通网关 `10.243.166.1`；`FILENAME` 指向磁盘上的 `*.nmconnection`，不能只在 `/run/NetworkManager/system-connections/`。然后再让主机注册。安装触发重启后弹出 ISO，启动顺序改回 disk-first。

Pool 写入时 `networkDevice` 填 `eth0.329`。先看 Inventory 的 `observedNetwork.interfaces` / `connections`，接口名不是 `eth0.329` 时只改那一台。

第 2 步默认地址是节点表上的 `10.243.166.6/26`、DNS `10.243.132.38`。上面这组 `10.243.166.31/26`、DNS `8.8.8.8` 是现场另一台跑通时的值，只作参考。

单口 `eth0` 交换机不放行、两口已被绑成一组时，改用 bond + VLAN（现场常见 **active-backup，不是 LACP**）。IP 仍配在 VLAN 上，不要配在 `eth0` / `bond0`：

```bash
sudo nmcli con add type bond ifname bond0 con-name bond0 \
  mode active-backup miimon 100
sudo nmcli con add type ethernet ifname eth0 con-name bond0-port1 master bond0
sudo nmcli con add type ethernet ifname eth1 con-name bond0-port2 master bond0
sudo nmcli con add type vlan ifname bond0.329 con-name vlan329 \
  dev bond0 id 329
sudo nmcli con mod vlan329 \
  ipv4.method manual \
  ipv4.addresses 10.243.166.6/26 \
  ipv4.gateway 10.243.166.1 \
  ipv4.dns 10.243.132.38 \
  ipv6.method ignore
sudo nmcli con up bond0
sudo nmcli con up vlan329
ping -c 3 10.243.166.1
```

这时 `02` 里这一台改成 `networkDevice: bond0.329`。不要写 `eth0`、`eth1` 或 `bond0`：前两个是 slave，会报 `NetworkDeviceIsSlave`；`bond0` 没有节点地址。Master 的 `BaremetalCluster` / 控制面 Pool 仍然是 `eth0`。

### 9.2 物理机硬盘上已有旧操作系统

**现象：** 硬盘上已经有旧系统（分区、`EFI` / `ROOT` / `COS_*` 标签还在）。Live ISO 里 Elemental 选盘失败、装到错误设备，或旧分区标签干扰重装。

**适用：** Live ISO 控制台，还没有开始 Elemental 安装。本例真实盘是 `sda`。

**不要做：** 不要对 `sr*`、`loop*` 做 wipe/format。`MachineRegistration` 里的 `install.device` 永远是 `/dev/elemental-install-target`，不要改成 `/dev/sda`。这里的 `/dev/sda` 只是这台 Live ISO 上 `lsblk` 确认后的真实盘名。

```bash
lsblk
mount | grep sda || true
umount /dev/sda3 /dev/sda2 /dev/sda1 2>/dev/null || true
wipefs -a /dev/sda
sgdisk -Z /dev/sda
partprobe /dev/sda
lsblk
blkid
```

清完后 `sda` 应该没有分区，`blkid` 里也不该再看到 `EFI` / `ROOT` / `COS_*`。然后再按第 2 步做软链接。
