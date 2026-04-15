# JMX Prometheus Exporter javaagent가 포함된 Trino 이미지
# 공식 Trino 이미지에 jmx_prometheus_javaagent jar만 추가.
#
# Apple Silicon Mac에서 linux/amd64 빌드 시 Trino 480의 x86-64-v3 glibc와
# QEMU 호환성 문제로 RUN이 실패함. → COPY 방식으로 회피.
#
# 빌드 전 준비 (jar를 로컬에 다운로드):
#   cd docker/trino-with-jmx
#   curl -fsSL -o jmx_prometheus_javaagent.jar \
#     https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar
#
# 빌드 & 푸시 (Apple Silicon에서도 amd64 이미지 생성):
#   docker buildx build --platform linux/amd64 \
#     -t harbor.quantumcns.ai/akashiq/trino:480-jmx --push .
#
# 사용:
#   helm/values.yaml의 image.repository / tag 를 위 값으로 교체

ARG TRINO_VERSION=480
FROM trinodb/trino:${TRINO_VERSION}

# 로컬에 미리 내려받은 jar를 이미지로 복사 (RUN/curl 사용하지 않음)
COPY --chown=trino:trino jmx_prometheus_javaagent.jar /opt/jmx-exporter/jmx_prometheus_javaagent.jar
