#!/bin/bash
# ============================================================
#  Raspberry Pi 5 + Hailo AI HAT+ + NVMe SSD
#  YOLO11 통합 설치 스크립트 (한 번 실행으로 전체 설치)
#
#  실행: sudo bash install.sh
#
#  설치 단계:
#   1단계: PCIe / NVMe SSD / 카메라 커널 설정  →  재부팅
#   2단계: 드라이버·패키지·모델 설치           →  완료
#
#  재부팅 후 자동으로 2단계를 이어서 실행합니다.
# ============================================================

set -e

# ── 경로 설정 ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="/tmp/yolo11_install_stage"
LOG_FILE="/tmp/yolo11_install.log"

MOUNT_USER="${SUDO_USER:-kimyongsoo}"
MOUNT_PATH="/media/$MOUNT_USER/PI5_SSD"
CONFIG_FILE="/boot/firmware/config.txt"
VENV_DIR="/home/$MOUNT_USER/hailo_env"

# ── 색상 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}  ✔ $1${NC}" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}  ⚠ $1${NC}" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}  ✘ $1${NC}" | tee -a "$LOG_FILE"; }
section() { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}" | tee -a "$LOG_FILE"; }
log()     { echo "$1" | tee -a "$LOG_FILE"; }

# ── root 확인 ─────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    error "root 권한 필요: sudo bash install.sh"
    exit 1
fi

# ── 현재 설치 단계 확인 ───────────────────────────────────────────────────────
STAGE=1
if [ -f "$STATE_FILE" ]; then
    STAGE=$(cat "$STATE_FILE")
fi

echo "" | tee -a "$LOG_FILE"
echo -e "${BOLD}============================================================${NC}" | tee -a "$LOG_FILE"
echo -e "${BOLD}  YOLO11 통합 설치 (Raspberry Pi 5 + Hailo + NVMe SSD)${NC}" | tee -a "$LOG_FILE"
echo -e "${BOLD}  실행 단계: $STAGE/2   로그: $LOG_FILE${NC}" | tee -a "$LOG_FILE"
echo -e "${BOLD}============================================================${NC}" | tee -a "$LOG_FILE"
date | tee -a "$LOG_FILE"

# ════════════════════════════════════════════════════════════════════════════
# ■ 1단계: 커널/하드웨어 설정 (재부팅 필요)
# ════════════════════════════════════════════════════════════════════════════
if [ "$STAGE" -eq 1 ]; then

    section "[1/2단계] 하드웨어 설정 (PCIe · NVMe · 카메라)"

    # ── PCIe Gen3 활성화 ───────────────────────────────────────────────────
    section "  PCIe Gen3 활성화 (NVMe 최대 속도)"
    if grep -q "^dtparam=pciex1_gen=3" "$CONFIG_FILE"; then
        info "PCIe Gen3 이미 설정됨"
    else
        echo "dtparam=pciex1_gen=3" >> "$CONFIG_FILE"
        info "PCIe Gen3 추가됨"
    fi

    # ── NVMe SSD 설정 ──────────────────────────────────────────────────────
    section "  NVMe SSD 파티션 및 마운트"
    modprobe nvme 2>/dev/null || true
    NVME_DEV=""
    for dev in /dev/nvme0n1 /dev/nvme1n1; do
        [ -b "$dev" ] && NVME_DEV="$dev" && break
    done

    if [ -z "$NVME_DEV" ]; then
        warn "NVMe 장치 미감지 – 재부팅 후 자동 재시도됩니다."
        warn "(SSD 삽입 확인 후 재부팅: sudo reboot)"
    else
        info "NVMe 장치 감지: $NVME_DEV"
        NVME_PART="${NVME_DEV}p1"
        if ! [ -b "$NVME_PART" ]; then
            log "  파티션 생성 중..."
            parted -s "$NVME_DEV" mklabel gpt
            parted -s "$NVME_DEV" mkpart primary ext4 0% 100%
            sleep 1; partprobe "$NVME_DEV"; sleep 1
            mkfs.ext4 -L "PI5_SSD" -F "$NVME_PART"
            info "ext4 포맷 완료"
        else
            info "기존 파티션 사용: $NVME_PART"
        fi

        mkdir -p "$MOUNT_PATH"
        mountpoint -q "$MOUNT_PATH" && umount "$MOUNT_PATH" || true
        mount "$NVME_PART" "$MOUNT_PATH"
        chown -R "$MOUNT_USER:$MOUNT_USER" "$MOUNT_PATH"
        info "마운트 완료: $MOUNT_PATH"

        UUID=$(blkid -o value -s UUID "$NVME_PART")
        FSTAB_ENTRY="UUID=$UUID  $MOUNT_PATH  ext4  defaults,noatime,nofail  0  2"
        if ! grep -q "$UUID" /etc/fstab; then
            { echo ""; echo "# NVMe SSD – PI5_SSD"; echo "$FSTAB_ENTRY"; } >> /etc/fstab
            info "fstab 자동 마운트 등록"
        fi
    fi

    # ── IMX500 (RPi AI Camera) 드라이버 ───────────────────────────────────
    section "  Raspberry Pi AI Camera (IMX500) 드라이버"
    apt-get update -qq
    apt-get install -y libcamera-dev libcamera-tools python3-libcamera \
        python3-picamera2 python3-kms++ python3-prctl -qq
    if dpkg -l imx500-all &>/dev/null; then
        info "imx500-all 이미 설치됨"
    else
        apt-get install -y imx500-all -qq && info "IMX500 드라이버 설치 완료" || \
            warn "IMX500 설치 실패 – RPi AI Camera 미사용 시 무시"
    fi

    # ── IMX519 (Arducam UC-261) 드라이버 ──────────────────────────────────
    section "  Arducam UC-261 (IMX519) 드라이버"
    if grep -q "dtoverlay=imx519" "$CONFIG_FILE"; then
        info "dtoverlay=imx519 이미 설정됨"
    else
        echo "dtoverlay=imx519" >> "$CONFIG_FILE"
        info "dtoverlay=imx519 추가됨"
    fi

    apt-get install -y curl -qq
    curl -fsSL https://github.com/ArduCAM/Arducam-Pivariety-V4L2-Driver/releases/download/install_script/install_pivariety_pkgs.sh \
        | bash -s -- -p imx519_standalone_driver 2>/dev/null && \
        info "Arducam IMX519 드라이버 설치 완료" || \
        warn "Arducam 자동 설치 실패 – 표준 드라이버 사용"

    # ── 2단계 자동 실행 등록 (재부팅 후) ─────────────────────────────────
    section "  재부팅 후 자동 실행 등록"
    AUTORUN_SERVICE="/etc/systemd/system/yolo11-install.service"
    cat > "$AUTORUN_SERVICE" << EOF
[Unit]
Description=YOLO11 Install Stage 2
After=network-online.target
Wants=network-online.target
ConditionPathExists=$STATE_FILE

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_DIR/install.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable yolo11-install.service
    echo "2" > "$STATE_FILE"
    info "2단계 자동 실행 서비스 등록 완료"

    echo ""
    echo -e "${YELLOW}${BOLD}  ★ 1단계 완료 – 재부팅이 필요합니다 ★${NC}"
    echo -e "${YELLOW}  재부팅 후 2단계(패키지·모델 설치)가 자동으로 실행됩니다.${NC}"
    echo ""
    read -r -p "  지금 재부팅하시겠습니까? [Y/n]: " REBOOT_NOW
    REBOOT_NOW="${REBOOT_NOW:-Y}"
    if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
        log "재부팅 중..."
        reboot
    else
        echo "  나중에 직접 재부팅하세요: sudo reboot"
    fi
    exit 0
fi

# ════════════════════════════════════════════════════════════════════════════
# ■ 2단계: 패키지·환경·모델 설치 (재부팅 후 자동 실행)
# ════════════════════════════════════════════════════════════════════════════
if [ "$STAGE" -eq 2 ]; then

    section "[2/2단계] 패키지 · 환경 · 모델 설치"

    # ── SSD 마운트 확인 ────────────────────────────────────────────────────
    section "  SSD 마운트 확인"
    if mountpoint -q "$MOUNT_PATH"; then
        info "SSD 마운트 확인: $MOUNT_PATH"
    else
        # fstab 으로 재마운트 시도
        mount -a 2>/dev/null && info "SSD 마운트 완료" || warn "SSD 마운트 실패 – 확인 필요"
    fi

    # ── 시스템 패키지 ──────────────────────────────────────────────────────
    section "  시스템 패키지 설치"
    apt-get update -qq
    apt-get install -y \
        python3-pip python3-venv python3-dev \
        libopencv-dev python3-opencv \
        libatlas-base-dev libhdf5-dev \
        ffmpeg v4l-utils wget -qq
    info "시스템 패키지 설치 완료"

    # ── Python 가상환경 ────────────────────────────────────────────────────
    section "  Python 가상환경 생성"
    if [ ! -d "$VENV_DIR" ]; then
        sudo -u "$MOUNT_USER" python3 -m venv "$VENV_DIR" --system-site-packages
        info "가상환경 생성: $VENV_DIR"
    else
        info "가상환경 이미 존재: $VENV_DIR"
    fi

    # ── Python 패키지 ──────────────────────────────────────────────────────
    section "  Python 패키지 설치"
    sudo -u "$MOUNT_USER" "$VENV_DIR/bin/pip" install --upgrade pip -q
    sudo -u "$MOUNT_USER" "$VENV_DIR/bin/pip" install -q \
        opencv-python-headless numpy
    info "Python 패키지 설치 완료"

    # hailo_platform 확인
    if sudo -u "$MOUNT_USER" "$VENV_DIR/bin/python3" -c "import hailo_platform" 2>/dev/null; then
        info "hailo_platform 사용 가능"
    else
        warn "hailo_platform 미설치 – Hailo Suite 별도 설치 필요"
        warn "  https://hailo.ai/developer-zone/sw-downloads/"
    fi

    # picamera2 확인
    if sudo -u "$MOUNT_USER" "$VENV_DIR/bin/python3" -c "import picamera2" 2>/dev/null; then
        info "picamera2 사용 가능"
    else
        warn "picamera2 미설치 – sudo apt install python3-picamera2"
    fi

    # ── HEF 모델 다운로드 ──────────────────────────────────────────────────
    section "  YOLO11 HEF 모델 다운로드"
    MODEL_DIR="$MOUNT_PATH/models"
    mkdir -p "$MODEL_DIR"
    BASE_URL="https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v2.14.0/hailo8l"
    for MODEL in yolov11n yolov11s; do
        HEF_FILE="$MODEL_DIR/${MODEL/yolov/yolo}.hef"
        if [ ! -f "$HEF_FILE" ]; then
            log "  다운로드: $MODEL ..."
            wget -q --show-progress -O "$HEF_FILE" "$BASE_URL/${MODEL}.hef" && \
                info "$MODEL 다운로드 완료" || { warn "$MODEL 다운로드 실패"; rm -f "$HEF_FILE"; }
        else
            info "$MODEL 이미 존재"
        fi
    done

    # ── SSD 디렉토리 구조 생성 ─────────────────────────────────────────────
    section "  SSD 데이터 디렉토리 구조 생성"
    if mountpoint -q "$MOUNT_PATH"; then
        for split in train val test; do
            mkdir -p "$MOUNT_PATH/dataset/images/$split"
            mkdir -p "$MOUNT_PATH/dataset/labels/$split"
        done
        mkdir -p "$MOUNT_PATH/detections" "$MOUNT_PATH/videos" \
                 "$MOUNT_PATH/images" "$MOUNT_PATH/logs"

        CLASSES=(
            "00_person" "01_bicycle" "02_car" "03_motorcycle" "04_airplane"
            "05_bus" "06_train" "07_truck" "08_boat" "09_traffic_light"
            "10_fire_hydrant" "11_stop_sign" "12_parking_meter" "13_bench"
            "14_bird" "15_cat" "16_dog" "17_horse" "18_sheep" "19_cow"
            "20_elephant" "21_bear" "22_zebra" "23_giraffe" "24_backpack"
            "25_umbrella" "26_handbag" "27_tie" "28_suitcase" "29_frisbee"
            "30_skis" "31_snowboard" "32_sports_ball" "33_kite"
            "34_baseball_bat" "35_baseball_glove" "36_skateboard"
            "37_surfboard" "38_tennis_racket" "39_bottle" "40_wine_glass"
            "41_cup" "42_fork" "43_knife" "44_spoon" "45_bowl"
            "46_banana" "47_apple" "48_sandwich" "49_orange" "50_broccoli"
            "51_carrot" "52_hot_dog" "53_pizza" "54_donut" "55_cake"
            "56_chair" "57_couch" "58_potted_plant" "59_bed"
            "60_dining_table" "61_toilet" "62_tv" "63_laptop" "64_mouse"
            "65_remote" "66_keyboard" "67_cell_phone" "68_microwave"
            "69_oven" "70_toaster" "71_sink" "72_refrigerator" "73_book"
            "74_clock" "75_vase" "76_scissors" "77_teddy_bear"
            "78_hair_drier" "79_toothbrush"
        )
        for cls in "${CLASSES[@]}"; do
            mkdir -p "$MOUNT_PATH/guide_photos/$cls"
        done

        chown -R "$MOUNT_USER:$MOUNT_USER" "$MOUNT_PATH"
        info "SSD 디렉토리 구조 생성 완료 (80개 클래스)"
    else
        warn "SSD 마운트 안 됨 – 디렉토리 생성 건너뜀"
    fi

    # ── 장치 최종 확인 ─────────────────────────────────────────────────────
    section "  장치 연결 최종 확인"

    # Hailo
    if hailortcli fw-control identify 2>/dev/null; then
        info "Hailo AI HAT+ 정상 감지"
    else
        warn "Hailo AI HAT+ 미감지 – PCIe 및 드라이버 확인 필요"
    fi

    # NVMe 속도 간이 테스트
    if mountpoint -q "$MOUNT_PATH"; then
        SPEED=$(dd if=/dev/zero of="$MOUNT_PATH/.speedtest" bs=1M count=128 \
            conv=fsync 2>&1 | grep -oP '[\d.]+ [MG]B/s' | tail -1 || echo "측정 불가")
        rm -f "$MOUNT_PATH/.speedtest"
        info "NVMe 쓰기 속도: $SPEED"
        df -h "$MOUNT_PATH"
    fi

    # 카메라
    if command -v libcamera-hello &>/dev/null; then
        CAM_LIST=$(libcamera-hello --list-cameras 2>&1 || true)
        echo "$CAM_LIST" | grep -qi "imx519" && info "Arducam UC-261 (IMX519) 감지됨"
        echo "$CAM_LIST" | grep -qi "imx500" && info "RPi AI Camera (IMX500) 감지됨"
        echo "$CAM_LIST" | grep -qiE "imx519|imx500" || warn "CSI 카메라 미감지 – 케이블 확인"
    fi

    # ── 서비스 정리 ────────────────────────────────────────────────────────
    systemctl disable yolo11-install.service 2>/dev/null || true
    rm -f /etc/systemd/system/yolo11-install.service
    systemctl daemon-reload
    rm -f "$STATE_FILE"

    # ── 설치 완료 ──────────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}${BOLD}============================================================${NC}"
    echo -e "${GREEN}${BOLD}  ★ 전체 설치 완료! ★${NC}"
    echo -e "${GREEN}${BOLD}============================================================${NC}"
    echo ""
    echo "  가상환경 활성화:"
    echo -e "  ${CYAN}source $VENV_DIR/bin/activate${NC}"
    echo -e "  ${CYAN}cd $SCRIPT_DIR${NC}"
    echo ""
    echo "  카메라 목록 확인:"
    echo -e "  ${CYAN}python yolo11_detect.py --list-cameras${NC}"
    echo ""
    echo "  감지 실행:"
    echo -e "  ${CYAN}python yolo11_detect.py --source picam --camera-type imx519${NC}"
    echo -e "  ${CYAN}python yolo11_detect.py --source picam --camera-type imx500${NC}"
    echo ""
    echo "  SSD 데이터 관리:"
    echo -e "  ${CYAN}python data_manager.py status${NC}"
    echo ""
    echo "  설치 로그: $LOG_FILE"
    echo ""
fi
