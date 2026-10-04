# QQ Bridge 的 QQ 容器 = 官方 NapCat Shell 镜像 + 隔离 PulseAudio + supervisord + AV Host 分流。
# 构建上下文是仓库根目录（见 deploy/docker-compose.yml），构建前先执行 pnpm -r build 生成插件 dist。
ARG NAPCAT_IMAGE=mlikiowa/napcat-docker:v4.18.28
FROM ${NAPCAT_IMAGE}

# 官方镜像用 dpkg --force-depends 安装 QQ，留下了未满足的依赖（xdg-utils）；先 --fix-broken 补齐（不会卸载 QQ），
# 否则 apt 会拒绝安装任何包。
RUN apt-get update \
 && apt-get install -y --no-install-recommends --fix-broken \
 && dpkg -s linuxqq >/dev/null \
 && apt-get install -y --no-install-recommends pulseaudio pulseaudio-utils libasound2-plugins supervisor \
      libpulse-mainloop-glib0 libegl1 libopengl0 libxft2 \
 && rm -rf /var/lib/apt/lists/*
# 上面最后一行是通话引擎 libAVSDKPlugin.so / broadcast-core.so 的运行库（ldd 查出官方镜像里缺这几个）。

# ALSA 默认设备也转到 PulseAudio，避免通话引擎绕过 Pulse 直接找声卡。
COPY deploy/qq/asound.conf /etc/asound.conf
COPY deploy/qq/pulse.pa /etc/qqbridge/pulse.pa
COPY deploy/qq/supervisord.conf /etc/qqbridge/supervisord.conf
COPY deploy/qq/qqbridge-start.sh deploy/qq/run-napcat.sh deploy/qq/run-avhost.sh deploy/qq/run-pulseaudio.sh deploy/qq/run-pulse-anchor.sh /app/qqbridge/
COPY packages/av-host/host.cjs packages/av-host/host.html /app/av-host/
COPY packages/napcat-plugin-qqbridge/dist/ /app/qqbridge/plugin/napcat-plugin-qqbridge/
COPY deploy/qq/loadNapCat.js /app/qqbridge/loadNapCat.js

# 1) 入口分流：默认与官方镜像一致（加载 NapCat），只有 QQBRIDGE_AV_HOST=1 时改为启动 AV Host。
#    先确认官方入口内容没变，防止上游镜像改了入口后被我们盲目覆盖；原文件保留为 loadNapCat.official.js。
RUN grep -q "file:///app/napcat/napcat.mjs" /opt/QQ/resources/app/loadNapCat.js \
 && cp /opt/QQ/resources/app/loadNapCat.js /opt/QQ/resources/app/loadNapCat.official.js \
 && cp /app/qqbridge/loadNapCat.js /opt/QQ/resources/app/loadNapCat.js \
 && if [ -f /opt/QQ/resources/app/avsdk/libAVSDKPlugin.so ]; then \
      echo "[qqbridge] AVSDK present: $(ls -la /opt/QQ/resources/app/avsdk/libAVSDKPlugin.so)"; \
    else \
      echo "[qqbridge] WARNING: libAVSDKPlugin.so missing in this QQ build, call bridge will stay disabled"; \
    fi

# 2) 复用官方 entrypoint 的反容器检测与用户准备，只把最后"启动 Xvfb + QQ"换成 supervisord。
RUN grep -q '^gosu napcat Xvfb :1' /app/entrypoint.sh \
 && sed -i '/^gosu napcat Xvfb :1/,$d' /app/entrypoint.sh \
 && printf '\nexec bash /app/qqbridge/qqbridge-start.sh\n' >> /app/entrypoint.sh \
 && chmod +x /app/qqbridge/*.sh
