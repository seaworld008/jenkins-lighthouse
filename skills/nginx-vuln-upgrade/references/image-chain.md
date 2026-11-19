# 内嵌 nginx 业务镜像升级链路（与 Jenkins 配合）

业务镜像的 nginx 在镜像内部，不能单换进程，必须重建镜像。完整链路七步，来自一次 9 个前端应用 × K8s 滚动 + 23 个 Jenkins 任务 FROM 替换的实践。

## ① 扫描：找容器内 nginx 版本

```bash
# K8s 侧
kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace + " " + .metadata.name + " " + .spec.containers[].image'
# 按镜像逐类 exec 确认内嵌 nginx 版本
kubectl -n <ns> exec <pod> -- nginx -v 2>&1
# 宿主机 docker 侧
docker ps --format '{{.Names}} {{.Image}}' | ...
docker exec <c> nginx -v 2>&1
```
- 记录：镜像 → 内嵌 nginx 版本 → 是否运行时镜像（区别于仅构建容器）。
- 第三方产品内置 nginx（GitLab/JumpServer/Harbor portal 等）不走本链路，按产品自身升级流程处理。

## ② 构建新底镜像

```dockerfile
FROM nginx@sha256:<digest>   # 官方镜像按 digest 拉取
ENV TZ=Asia/Shanghai
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
```
- 按需做变体（如 +node 20 + yarn，供需要 node 运行时的前端）。
- 推私仓（`registry.example.com/library/nginx-...:1.30.7`），HEAD manifest 200 核对。
- 服务器拉不了 Docker Hub 时按 digest 经加速源拉取再推私仓，见 playbook 阶段 3。

## ③ 换底重建

```dockerfile
FROM registry.example.com/library/nginx-shanghai:1.30.7     # 新底
COPY --from=registry.example.com/prod/frontend-3:old-tag \
     /usr/share/nginx/html /usr/share/nginx/html           # 保持 conf/html 不变
```
- `FROM 新底 + COPY --from=旧镜像`，业务层原样搬移，tag 命名 `<原tag>-n1307`。
- 构建后 `docker run --rm <新镜像> nginx -t` 必过。

## ④ 新旧镜像本地逐路径对比

- 同参数各起一个容器，对真实静态文件路径、404、缓存头、压缩逐项对比：状态码 / 关键响应头 / 正文 md5。
- 预期差异：nginx 默认 404 页的版本字符串（`nginx/1.25.2` vs `nginx/1.30.7`）。
- 0 差异（除上述版本字符串）才推送。

## ⑤ 推业务镜像仓库

- 推 Harbor（构建底镜像与中间件）与云厂商镜像仓库（生产业务镜像）。
- HEAD manifest 核对推上去了。

## ⑥ K8s 滚动更新

```bash
kubectl -n prod set image deployment/frontend-3 web=registry.example.com/prod/frontend-3:<tag>-n1307
kubectl -n prod rollout status deployment/frontend-3 --timeout=300s
```
- 逐个应用 `set image` + `rollout status`，**不要一把全量**。
- ingress 状态码前后对比；无 ingress 的经 nodePort 在 pod 所在节点实测。
- **确认版本时注意**：exec 进入要校验 pod 的 `image` 字段；处于 Terminating 的旧 pod 仍显示 Running phase，直接 exec 可能打到旧容器。
- 滚动后全命名空间 deployment 状态核对。

## ⑦ Jenkins 任务 FROM 批量替换

```bash
tar -czf /data/jenkins/jobs-config-bak-<时间戳>.tar.gz -C /data/jenkins/controller/jobs .   # 先备份
# sed 替换运行时阶段的 FROM：
#   nginx-shanghai:1.25.2/1.28.0/1.28.3/1.30.2 → nginx-shanghai:1.30.7
#   library/nginx:1.25.2、nginx:1.31.4-trixie → nginx-shanghai:1.30.7
#   运行时需要 node 的：nginx-node-20-bullseye:v1.0 → nginx-node-20-trixie:1.30.7
docker restart jenkins-controller   # 重启加载，约 15s 恢复 healthy
```
- 只动**运行时**镜像的 FROM；builder 阶段、php-fpm 任务、仅作构建容器用（产物为静态 dist、运行时在远端主机）的任务**不动**。
- 验证：控制器 `/login` 200、任务数完好、磁盘无残留旧运行时 FROM（grep 复核）。
