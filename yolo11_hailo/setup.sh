#!/bin/bash
# ============================================================
#  Raspberry Pi 5 + Hailo AI HAT+ – YOLO11 환경 설치 스크립트
#  실행: bash setup.sh
# ============================================================

set -e

SSD="/media/kimyongsoo/PI5_SSD"
MODEL_DIR="$SSD/models"
DETECT_DIR="$SSD/detections"
VENV_DIR="$HOME/hailo_env"

echo "=== [1/6] SSD 디렉토리 생성 ==="
mkdir -p "$MODEL_DIR" "$DETECT_DIR" "$SSD/videos" "$SSD/images"

echo "=== [2/6] 시스템 패키지 설치 ==="
sudo apt-get update -qq
sudo apt-get install -y \
    python3-pip python3-venv python3-dev \
    libopencv-dev python3-opencv \
    libatlas-base-dev libhdf5-dev \
    ffmpeg v4l-utils

echo "=== [3/6] Python 가상환경 생성 ==="
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR" --system-site-packages
fi
source "$VENV_DIR/bin/activate"

echo "=== [4/6] Python 패키지 설치 ==="
pip install --upgrade pip -q
pip install -q \
    opencv-python-headless \
    numpy \
    picamera2

# hailo_platform은 Hailo 공식 DEB 패키지에 포함됨
# sudo dpkg -i hailort_*.deb  ← Hailo 드라이버 설치 시 자동 설치
if python3 -c "import hailo_platform" 2>/dev/null; then
    echo "  ✔ hailo_platform 이미 설치됨"
else
    echo "  ⚠ hailo_platform 미설치 – Hailo Suite를 설치하세요:"
    echo "    https://hailo.ai/developer-zone/sw-downloads/"
fi

echo "=== [5/6] YOLO11 HEF 모델 다운로드 ==="
# Hailo Model Zoo 사전 컴파일 YOLO11 모델
# (최신 링크는 https://github.com/hailo-ai/hailo_model_zoo 참고)

MODEL_FILE="$MODEL_DIR/yolo11n.hef"
MODEL_URL="https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v2.14.0/hailo8l/yolov11n.hef"

if [ ! -f "$MODEL_FILE" ]; then
    echo "  다운로드 중: $MODEL_URL"
    wget -q --show-progress -O "$MODEL_FILE" "$MODEL_URL" || {
        echo "  ⚠ 자동 다운로드 실패. 수동으로 HEF를 $MODEL_DIR 에 배치하세요."
        echo "  Hailo Model Zoo: https://github.com/hailo-ai/hailo_model_zoo"
    }
else
    echo "  ✔ 모델 이미 존재: $MODEL_FILE"
fi

echo "=== [6/6] Hailo 드라이버 확인 ==="
if hailortcli fw-control identify 2>/dev/null; then
    echo "  ✔ Hailo AI HAT+ 감지 성공"
else
    echo "  ⚠ Hailo 장치를 찾을 수 없습니다."
    echo "    - HAT+가 정상 장착되었는지 확인하세요."
    echo "    - 드라이버 설치: https://github.com/hailo-ai/hailort"
    echo "    - PCIe 활성화: sudo raspi-config → Advanced → PCIe Speed"
fi

echo ""
echo "=================================================="
echo "  설치 완료!"
echo ""
echo "  실행 방법:"
echo "  source $VENV_DIR/bin/activate"
echo "  cd $(dirname "$0")"
echo ""
echo "  # Pi Camera 실시간 감지"
echo "  python yolo11_detect.py --source picam"
echo ""
echo "  # SSD 동영상 파일 감지 (저장 포함)"
echo "  python yolo11_detect.py --source $SSD/videos/input.mp4 --save-video"
echo "=================================================="
