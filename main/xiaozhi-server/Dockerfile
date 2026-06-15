# 以上游镜像为基础，直接替换应用层代码（跳过重装 torch/funasr 等重型依赖）
FROM ghcr.nju.edu.cn/xinnan-tech/xiaozhi-esp32-server:server_latest

WORKDIR /opt/xiaozhi-esp32-server

# 仅复制会被修改的应用层代码
# data/ models/ 始终在运行时通过 volume 挂载，不打包进镜像
COPY app.py         app.py
COPY config/        config/
COPY core/          core/
COPY plugins_func/  plugins_func/
