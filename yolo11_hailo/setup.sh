#!/bin/bash
# ============================================================
#  Raspberry Pi 5 + Hailo AI HAT+ – YOLO11 환경 설치 스크립트
#  지원 카메라:
#    - Arducam UC-261 (IMX519, 16MP, 자동초점)
#    - Raspberry Pi AI Camera (IMX500, 12MP)
#  실행: bash setup.sh
# ============================================================

set -e

SSD="/media/kimyongsoo/PI5_SSD"
MODEL_DIR="$SSD/models"
DETECT_DIR="$SSD/detections"
VENV_DIR="$HOME/hailo_env"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== [1/8] SSD 디렉토리 생성 ==="
mkdir -p "$MODEL_DIR" "$DETECT_DIR" "$SSD/videos" "$SSD/images"
echo "  ✔ $SSD 하위 디렉토리 생성 완료"

echo ""
echo "=== [2/8] 시스템 패키지 설치 ==="
sudo apt-get update -qq
sudo apt-get install -y \
    python3-pip python3-venv python3-dev \
    libopencv-dev python3-opencv \
    libatlas-base-dev libhdf5-dev \
    libcamera-dev libcamera-tools \
    python3-libcamera python3-picamera2 \
    python3-kms++ python3-prctl \
    ffmpeg v4l-utils curl wget

echo ""
echo "=== [3/8] Raspberry Pi AI Camera (IMX500) 드라이버 설치 ==="
# IMX500 펌웨어 및 패키지 (RPi AI Camera 사용 시 필수)
if dpkg -l imx500-all &>/dev/null; then
    echo "  ✔ imx500-all 이미 설치됨"
else
    echo "  imx500-all 설치 중 (펌웨어 포함, 약 80MB)..."
    sudo apt-get install -y imx500-all && \
        echo "  ✔ IMX500 드라이버 설치 완료" || \
        echo "  ⚠ IMX500 설치 실패 – RPi AI Camera 미사용 시 무시하세요."
fi

echo ""
echo "=== [4/8] Arducam UC-261 (IMX519) 드라이버 설치 ==="
# IMX519는 RPi OS Bookworm에 기본 포함 여부 확인
if libcamera-hello --list-cameras 2>/dev/null | grep -qi "imx519"; then
    echo "  ✔ IMX519 이미 감지됨 (기본 드라이버 사용 가능)"
else
    echo "  IMX519 기본 감지 안 됨 – Arducam 드라이버 설치 시도..."
    # /boot/firmware/config.txt 에 dtoverlay 추가
    CONFIG="/boot/firmware/config.txt"
    if ! grep -q "dtoverlay=imx519" "$CONFIG"; then
        echo "dtoverlay=imx519" | sudo tee -a "$CONFIG" > /dev/null
        echo "  ✔ dtoverlay=imx519 추가됨 → 재부팅 후 적용"
    else
        echo "  ✔ dtoverlay=imx519 이미 설정됨"
    fi

    # Arducam 공식 설치 스크립트 (자동초점 라이브러리 포함)
    echo "  Arducam 패키지 설치 중..."
    curl -fsSL https://github.com/ArduCAM/Arducam-Pivariety-V4L2-Driver/releases/download/install_script/install_pivariety_pkgs.sh \
        | bash -s -- -p imx519_standalone_driver 2>/dev/null && \
        echo "  ✔ Arducam IMX519 드라이버 설치 완료" || \
        echo "  ⚠ Arducam 자동 설치 실패 – 수동 설치: https://github.com/ArduCAM/Arducam-Pivariety-V4L2-Driver"
fi

echo ""
echo "=== [5/8] Python 가상환경 생성 ==="
if [ ! -d "$VENV_DIR" ]; then
    # --system-site-packages: 시스템에 설치된 picamera2, libcamera 공유
    python3 -m venv "$VENV_DIR" --system-site-packages
    echo "  ✔ 가상환경 생성: $VENV_DIR"
else
    echo "  ✔ 가상환경 이미 존재: $VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

echo ""
echo "=== [6/8] Python 패키지 설치 ==="
pip install --upgrade pip -q
pip install -q \
    opencv-python-headless \
    numpy

# hailo_platform은 Hailo 공식 DEB 패키지에 포함됨
if python3 -c "import hailo_platform" 2>/dev/null; then
    echo "  ✔ hailo_platform 설치됨"
else
    echo "  ⚠ hailo_platform 미설치 – Hailo Suite를 먼저 설치하세요:"
    echo "    https://hailo.ai/developer-zone/sw-downloads/"
fi

# picamera2 시스템 패키지 접근 확인
if python3 -c "import picamera2" 2>/dev/null; then
    echo "  ✔ picamera2 사용 가능"
else
    echo "  ⚠ picamera2 접근 불가 – 시스템 패키지 설치 확인:"
    echo "    sudo apt install python3-picamera2"
fi

echo ""
echo "=== [7/8] YOLO11 HEF 모델 다운로드 ==="
# Hailo Model Zoo 사전 컴파일 YOLO11 모델 (Hailo-8L 전용)
download_model() {
    local name="$1"
    local url="$2"
    local file="$MODEL_DIR/${name}.hef"
    if [ ! -f "$file" ]; then
        echo "  다운로드 중: $name ..."
        wget -q --show-progress -O "$file" "$url" && \
            echo "  ✔ $name 다운로드 완료" || \
            { echo "  ⚠ $name 다운로드 실패"; rm -f "$file"; }
    else
        echo "  ✔ $name 이미 존재"
    fi
}

BASE_URL="https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v2.14.0/hailo8l"
download_model "yolo11n" "$BASE_URL/yolov11n.hef"
download_model "yolo11s" "$BASE_URL/yolov11s.hef"

echo ""
echo "=== [8/8] 장치 연결 확인 ==="

# Hailo AI HAT+ 확인
echo "  [Hailo AI HAT+]"
if hailortcli fw-control identify 2>/dev/null; then
    echo "  ✔ Hailo AI HAT+ 감지 성공"
else
    echo "  ⚠ Hailo 장치 없음 – PCIe 활성화 및 드라이버 확인:"
    echo "    echo 'dtparam=pciex1_gen=3' | sudo tee -a /boot/firmware/config.txt"
    echo "    sudo apt install hailort && sudo reboot"
fi

# CSI 카메라 확인
echo ""
echo "  [CSI 카메라]"
if command -v libcamera-hello &>/dev/null; then
    CAM_LIST=$(libcamera-hello --list-cameras 2>&1)
    echo "$CAM_LIST" | grep -E "^\s+[0-9]+" | while read -r line; do
        echo "  ✔ $line"
    done
    if echo "$CAM_LIST" | grep -qi "imx519"; then
        echo "  ✔ Arducam UC-261 (IMX519) 감지됨"
    fi
    if echo "$CAM_LIST" | grep -qi "imx500"; then
        echo "  ✔ Raspberry Pi AI Camera (IMX500) 감지됨"
    fi
    if ! echo "$CAM_LIST" | grep -qE "imx519|imx500"; then
        echo "  ⚠ IMX519/IMX500 미감지 – 케이블 연결 및 재부팅 확인"
    fi
else
    echo "  ⚠ libcamera-hello 없음 – apt install libcamera-tools"
fi

# 재부팅 필요 여부 안내
if grep -q "dtoverlay=imx519" /boot/firmware/config.txt 2>/dev/null && \
   ! libcamera-hello --list-cameras 2>/dev/null | grep -qi "imx519"; then
    echo ""
    echo "  ★ config.txt 변경됨 → 재부팅 필요: sudo reboot"
fi

echo ""
echo "=================================================="
echo "  설치 완료!"
echo ""
echo "  가상환경 활성화:"
echo "    source $VENV_DIR/bin/activate"
echo "    cd $SCRIPT_DIR"
echo ""
echo "  카메라 목록 확인:"
echo "    python yolo11_detect.py --list-cameras"
echo ""
echo "  실행 예시:"
echo "    # Arducam UC-261 (IMX519, 자동초점)"
echo "    python yolo11_detect.py --source picam --camera-type imx519"
echo ""
echo "    # Raspberry Pi AI Camera (IMX500)"
echo "    python yolo11_detect.py --source picam --camera-type imx500"
echo ""
echo "    # SSD 동영상 감지 + 저장"
echo "    python yolo11_detect.py --source $SSD/videos/input.mp4 --save-video"
echo "=================================================="
