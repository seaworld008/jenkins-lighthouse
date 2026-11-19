# 各形态回滚

切换前先核对备份在位；回滚后同样跑稳定探测确认差异 0。

## 1. compose 容器

```bash
cp -p /root/nginx-upgrade-backup/<时间戳>/docker-compose.yml <原路径>/
docker compose -f <原路径>/docker-compose.yml up -d        # 或 up -d --no-deps <svc>
```
- 旧镜像仍在本地，无需拉取；`.env` 有镜像变量时连同备份一起恢复。

## 2. docker run 容器

```bash
docker rm -f <name>                       # 新容器
docker rename <name>-old-<旧版本> <name>
docker update --restart=always <name>     # 恢复原 restart 策略
docker start <name>
```
- 回滚前核对旧容器 `docker ps -a` 在位且 restart=no；挂载/网络沿用 rename 后的原定义。

## 3. rpm 二进制

```bash
dnf downgrade nginx-<旧版本>
systemctl status nginx    # master PID 与监听核对
```
- 旧版本存在已知 CVE，仅在紧急回滚时临时使用，回滚后尽快重新升级。

## 4. 源码编译

```bash
cp -p /usr/local/nginx/sbin/nginx-<旧版本>.bak /usr/local/nginx/sbin/nginx
# 按原方式平滑替换：给 master 发 USR2 → 确认新 master → WINCH → QUIT
kill -USR2 <master_pid>; sleep 3
kill -WINCH <新master_pid>; kill -QUIT <旧master_pid>
```
- systemd forking 模式 MainPID 自动跟随。
- 若回滚目标二进制静态链接的 OpenSSL 不支持 TLSv1.3（如 1.18 + OpenSSL 1.0.2），**配置也要一并恢复**（ssl_protocols 备份），否则 `-t` 失败。

## 5. Harbor proxy（私仓入口）

```bash
# 备份目录含 docker-compose.yml、nginx.conf、systemd unit
cp -p <备份目录>/docker-compose.yml /data/harbor/docker-compose.yml
cp -p <备份目录>/nginx.conf /data/harbor/common/config/nginx/nginx.conf
docker compose -f /data/harbor/docker-compose.yml up -d --no-deps proxy
# systemd unit 如被重写：恢复 <备份目录>/harbor.service.old 后 daemon-reload + restart
```
- 注意属主：恢复的 nginx.conf 属主要与运行用户（photon 场景 uid 10000）匹配。
- 重跑过 `./prepare`/`install.sh` 的话，回滚后同样要按变更脚本重放或确认不再需要（见 pitfalls P4）。

## 6. TLS 修改（独立回滚）

```bash
cp -p <备份目录>/*.conf <conf 目录>/    # 仅恢复 ssl_protocols 所在文件
nginx -t && nginx -s reload
```
- TLS 回滚不涉及进程替换，只 reload；同样过门禁探测。

## 7. K8s 前端镜像

```bash
kubectl -n <ns> set image deployment/<app> <container>=<旧镜像tag>
kubectl -n <ns> rollout status deployment/<app> --timeout=300s
```
- 旧 tag 未删时可秒级回退；逐个应用操作，不同时全量。

## 8. Jenkins 任务 FROM 替换

- 用替换前的备份 tar 解包覆盖 `jobs/*/config.xml`，重启 Jenkins 控制器加载。
